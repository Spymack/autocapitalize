//
//  Doctor.swift
//  AutoCap — self-diagnosis, Accessibility probe, one-shot AX diagnosis.
//
//  THREE QUESTIONS, THREE COMMANDS.
//
//    --doctor   can this build work on THIS machine right now? Verdict + exit code.
//    --axdiag   what does Accessibility answer, route by route, with the AXError
//               of each — for the frontmost application, right now.
//    --probe    what does the focused field of each application expose over
//               twelve seconds (role, text, caret, route)?
//
//  WHY --doctor NO LONGER TRUSTS ITSELF ALONE. Run from a terminal, a binary
//  inherits the terminal's Accessibility grant: `AXIsProcessTrusted()` then says
//  true even when the launchd daemon is still waiting for its own grant. The
//  doctor therefore also READS THE DAEMON'S JOURNAL and reports what the daemon
//  itself says. A permission verdict that contradicts the daemon is worthless.
//

import Cocoa
import ApplicationServices

enum CheckResult: String {
    case pass = "PASS"
    case warn = "WARN"
    case fail = "FAIL"
}

struct Check {
    let name: String
    let result: CheckResult
    let detail: String
}

enum Doctor {
    static func collect() -> [Check] {
        var checks: [Check] = []
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]

        // 1. Identity.
        let bytes = try? Data(contentsOf: URL(fileURLWithPath: path))
        let fingerprint = bytes.map { Log.fingerprint(of: $0) } ?? "unreadable"
        checks.append(Check(name: "build", result: .pass,
                            detail: "version \(Daemon.version), binary \(path), fingerprint \(fingerprint)"))

        // 2. Platform.
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        checks.append(Check(name: "platform", result: .pass, detail: "\(os), \(architecture())"))

        // 3. Accessibility, for THIS process — with the terminal caveat.
        let trusted = AX.isTrusted
        let fromTerminal = isatty(STDERR_FILENO) == 1
        var accessibilityDetail = trusted
            ? "granted to this process"
            : "NOT granted — System Settings > Privacy & Security > Accessibility, add \(path)"
        if trusted && fromTerminal {
            accessibilityDetail += " (launched from a terminal: this may be the TERMINAL's grant — "
                + "see the daemon check below)"
        }
        checks.append(Check(name: "accessibility",
                            result: trusted ? .pass : .fail,
                            detail: accessibilityDetail))

        // 4. Input Monitoring: proven by building a tap, not by asking.
        let tapWorks = canCreateTap()
        checks.append(Check(name: "event tap",
                            result: tapWorks ? .pass : .fail,
                            detail: tapWorks
                                ? "a session event tap was created and enabled"
                                : "could not create a session event tap — Input Monitoring is the usual cause"))

        // 5. LaunchAgent.
        let loaded = isAgentLoaded()
        checks.append(Check(name: "launch agent",
                            result: loaded ? .pass : .warn,
                            detail: loaded ? "\(Installer.label) is loaded"
                                           : "\(Installer.label) is not loaded (run --install)"))

        // 6. What the DAEMON says, from its own journal. This is the verdict that
        //    matters: the daemon runs under launchd, without the terminal's grant.
        let daemon = lastDaemonState()
        checks.append(Check(name: "daemon (journal)", result: daemon.result, detail: daemon.detail))

        // 7. Journal writable.
        let logPath = Log.fileURL.path
        let writable = FileManager.default.isWritableFile(atPath: logPath)
            || FileManager.default.isWritableFile(atPath: Log.directory.path)
        checks.append(Check(name: "journal", result: writable ? .pass : .fail,
                            detail: "\(logPath) \(writable ? "is writable" : "is NOT writable")"))

        // 8. Legacy Python daemon: two engines would fight over the same keys.
        let legacy = isLegacyLoaded()
        checks.append(Check(name: "legacy daemon", result: legacy ? .warn : .pass,
                            detail: legacy
                                ? "com.local.autocap is still loaded — unload it (two engines = double capitals)"
                                : "no com.local.autocap agent"))

        // 9. Accessibility read, right now, with the route and the codes.
        let read = AX.readField()
        if let snapshot = read.snapshot {
            checks.append(Check(name: "AX read", result: .pass,
                                detail: "\(snapshot.summary) app=\(AX.frontmostBundle() ?? "-")"))
        } else {
            checks.append(Check(name: "AX read", result: .warn,
                                detail: "\(read.failure ?? "unknown") — normal if the frontmost "
                                      + "application has no text field; otherwise run --axdiag"))
        }

        return checks
    }

    static func run() -> Int32 {
        let checks = collect()
        print("AutoCap doctor — \(Date())")
        print(String(repeating: "-", count: 78))
        for check in checks {
            print("[\(check.result.rawValue)] \(check.name.padding(toLength: 17, withPad: " ", startingAt: 0))"
                  + " \(check.detail)")
        }
        print(String(repeating: "-", count: 78))
        let failures = checks.filter { $0.result == .fail }.count
        let warnings = checks.filter { $0.result == .warn }.count
        if failures > 0 {
            print("VERDICT: NOT READY — \(failures) failure(s), \(warnings) warning(s).")
            return 1
        }
        print("VERDICT: READY — 0 failure(s), \(warnings) warning(s).")
        return 0
    }

    // MARK: Daemon state

    /// What the running daemon last said about its own permission and tap.
    ///
    /// Read from the journal, because the daemon is the only process whose
    /// verdict counts: it is the one launchd started, without any inherited
    /// authorisation.
    static func lastDaemonState() -> (result: CheckResult, detail: String) {
        guard let content = try? String(contentsOf: Log.fileURL, encoding: .utf8) else {
            return (.warn, "no journal at \(Log.fileURL.path) — the daemon has never started")
        }
        let lines = content.split(separator: "\n")
        let markers = ["event tap started", "Accessibility is not granted", "Accessibility granted",
                       "still waiting for Accessibility", "event tap could not be created",
                       "giving up after"]
        guard let last = lines.last(where: { line in markers.contains(where: { line.contains($0) }) })
        else {
            return (.warn, "the journal holds no daemon state line yet")
        }
        let text = String(last)
        if text.contains("event tap started") || text.contains("Accessibility granted") {
            return (.pass, "the daemon says: \(shorten(text))")
        }
        if text.contains("giving up after") {
            return (.fail, "the daemon gave up: \(shorten(text))")
        }
        return (.fail, "the daemon is waiting for permission: \(shorten(text))")
    }

    private static func shorten(_ line: String) -> String {
        let trimmed = line.replacingOccurrences(of: "\n", with: " ")
        return trimmed.count <= 150 ? trimmed : String(trimmed.suffix(150))
    }

    // MARK: Helpers

    static func architecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown architecture"
        #endif
    }

    /// Build a real tap and tear it down: the only honest test of permission.
    static func canCreateTap() -> Bool {
        let probe = EventTap { _, _ in nil }
        defer { probe.stop() }
        return probe.start()
    }

    static func isAgentLoaded() -> Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(Installer.label)"])
    }

    static func isLegacyLoaded() -> Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(Installer.legacyLabel)"])
    }

    private static func runLaunchctl(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

// MARK: - One-shot AX diagnosis

enum AXDiag {
    /// Answer, right now, what Accessibility returns for the frontmost app: every
    /// route, every error code, and what the field exposes.
    static func run() -> Int32 {
        print("AutoCap AX diagnosis — \(Date())")
        print("process trusted : \(AX.isTrusted)")
        print("frontmost app   : \(AX.frontmostBundle() ?? "-") (\(AX.frontmostName()))")
        print("pid             : \(AX.frontmostPID().map(String.init) ?? "-")")
        print("")

        let focused = AX.focusedElement()
        if let element = focused.element {
            print("focused element : FOUND via \(focused.route)")
            let role = AX.string(element, "AXRole")
            let subrole = AX.string(element, "AXSubrole")
            let value = AX.string(element, "AXValue")
            let caret = AX.caretOffset(element)
            print("  AXRole        : \(role.value ?? "-") [\(axErrorName(role.error))]")
            print("  AXSubrole     : \(subrole.value ?? "-") [\(axErrorName(subrole.error))]")
            print("  AXValue       : \(value.value.map { "\($0.count) char" } ?? "-") "
                  + "[\(axErrorName(value.error))]")
            print("  caret         : \(caret.map(String.init) ?? "unreadable")")
            print("  accepted      : \(isEditableTarget(role: role.value, subrole: subrole.value))")
        } else {
            print("focused element : NONE")
            print("  routes       : \(focused.error ?? "no detail")")
        }

        print("")
        let read = AX.readField()
        if let snapshot = read.snapshot {
            print("field read      : OK — \(snapshot.summary)")
        } else {
            print("field read      : FAILED — \(read.failure ?? "unknown")")
        }
        print("")
        print("Interpretation: apiDisabled(-25211) or cannotComplete(-25204) on every route means the")
        print("grant does not reach this binary; noValue(-25212) on AXValue means the field really has")
        print("no text (a web canvas, for instance). Not-an-editable-field is a role refusal, not a")
        print("permission problem.")
        return 0
    }
}

// MARK: - Probe

enum Probe {
    /// Watch the frontmost application for twelve seconds and describe every
    /// distinct one it sees: role, subrole, text and caret readability, the route
    /// that answered, and whether the daemon would accept the element.
    static func run(seconds: Double = 12) -> Int32 {
        print("Accessibility trusted: \(AX.isTrusted)")
        print("Switch to the window you want to inspect — watching for \(Int(seconds)) s.")
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let bundle = AX.frontmostBundle(), !seen.contains(bundle) {
                seen.insert(bundle)
                print("")
                print("== \(bundle)  (\(AX.frontmostName()))")
                let focused = AX.focusedElement()
                if let element = focused.element {
                    let role = AX.string(element, "AXRole")
                    let subrole = AX.string(element, "AXSubrole")
                    let text = AX.string(element, "AXValue")
                    let caret = AX.caretOffset(element)
                    print("   route=\(focused.route) role=\(role.value ?? "-") "
                          + "subrole=\(subrole.value ?? "-")")
                    print("   text : \(text.value.map { "\($0.count) char" } ?? "unreadable") "
                          + "[\(axErrorName(text.error))]")
                    print("   caret: \(caret.map(String.init) ?? "unreadable")")
                    print("   accepted by AutoCap: "
                          + "\(isEditableTarget(role: role.value, subrole: subrole.value))")
                } else {
                    print("   focused element: none — \(focused.error ?? "no detail")")
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if seen.isEmpty { print("No frontmost application detected.") }
        return 0
    }
}
