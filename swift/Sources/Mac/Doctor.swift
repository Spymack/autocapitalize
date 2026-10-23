//
//  Doctor.swift
//  AutoCap — self-diagnosis, and the Accessibility probe.
//
//  `--doctor` answers one question with a verdict and an exit code: can this
//  build work on THIS machine right now? Every check prints PASS, WARN or FAIL
//  with the value it read, because a diagnosis without values is a guess.
//
//  `--probe` answers the other question: what does the focused field of each
//  application actually expose? It watches the frontmost application for twelve
//  seconds and reports what it sees, so a field that cannot be read is named
//  instead of being guessed at.
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

        // 1. Identity.
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let bytes = try? Data(contentsOf: URL(fileURLWithPath: path))
        let fingerprint = bytes.map { Log.fingerprint(of: $0) } ?? "unreadable"
        checks.append(Check(name: "build", result: .pass,
                            detail: "version \(Daemon.version), binary \(path), fingerprint \(fingerprint)"))

        // 2. Platform.
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        checks.append(Check(name: "platform", result: .pass, detail: "\(os), \(architecture())"))

        // 3. Accessibility permission — the only hard requirement.
        let trusted = AX.isTrusted
        checks.append(Check(name: "accessibility",
                            result: trusted ? .pass : .fail,
                            detail: trusted
                                ? "granted to this binary"
                                : "NOT granted — System Settings > Privacy & Security > "
                                  + "Accessibility, add \(path)"))

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

        // 6. Journal.
        let logPath = Log.fileURL.path
        let writable = FileManager.default.isWritableFile(atPath: logPath)
            || FileManager.default.isWritableFile(atPath: Log.directory.path)
        checks.append(Check(name: "journal", result: writable ? .pass : .fail,
                            detail: "\(logPath) \(writable ? "is writable" : "is NOT writable")"))

        // 7. Legacy Python daemon: two engines would fight over the same keys.
        let legacy = isLegacyLoaded()
        checks.append(Check(name: "legacy daemon", result: legacy ? .warn : .pass,
                            detail: legacy
                                ? "com.local.autocap is still loaded — unload it (two engines = double capitals)"
                                : "no com.local.autocap agent"))

        // 8. What the frontmost field exposes, right now.
        let field = AX.readField()
        if let snapshot = field.snapshot {
            checks.append(Check(name: "focused field", result: .pass,
                                detail: "\(snapshot.summary) app=\(AX.frontmostBundle() ?? "-")"))
        } else {
            checks.append(Check(name: "focused field", result: .warn,
                                detail: "nothing readable right now (\(field.failure?.rawValue ?? "unknown")) "
                                      + "— normal if the frontmost app has no text field"))
        }

        return checks
    }

    static func run() -> Int32 {
        let checks = collect()
        print("AutoCap doctor — \(Date())")
        print(String(repeating: "-", count: 72))
        for check in checks {
            print("[\(check.result.rawValue)] \(check.name.padding(toLength: 16, withPad: " ", startingAt: 0))"
                  + " \(check.detail)")
        }
        print(String(repeating: "-", count: 72))
        let failures = checks.filter { $0.result == .fail }.count
        let warnings = checks.filter { $0.result == .warn }.count
        if failures > 0 {
            print("VERDICT: NOT READY — \(failures) failure(s), \(warnings) warning(s).")
            return 1
        }
        print("VERDICT: READY — 0 failure(s), \(warnings) warning(s).")
        return 0
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(Installer.label)"]
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

    static func isLegacyLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(Installer.legacyLabel)"]
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

// MARK: - Probe

enum Probe {
    /// Watch the frontmost application for twelve seconds and describe every
    /// distinct one it sees: role, subrole, text and caret readability, and
    /// whether the daemon would accept the element.
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
                if let element = AX.focusedElement() {
                    let role = AX.stringAttribute(element, "AXRole") ?? "-"
                    let subrole = AX.stringAttribute(element, "AXSubrole") ?? "-"
                    let text = AX.stringAttribute(element, "AXValue")
                    let caret = AX.caretOffset(element)
                    print("   role=\(role) subrole=\(subrole)")
                    print("   text : \(text.map { "\($0.count) char" } ?? "unreadable")")
                    print("   caret: \(caret.map(String.init) ?? "unreadable")")
                    print("   accepted by AutoCap: \(isEditableTarget(role: role, subrole: subrole))")
                } else {
                    print("   focused element: none (\(AX.readField().failure?.rawValue ?? "unknown"))")
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if seen.isEmpty { print("No frontmost application detected.") }
        return 0
    }
}
