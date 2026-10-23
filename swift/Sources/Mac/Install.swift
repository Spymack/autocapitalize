//
//  Install.swift
//  AutoCap — the LaunchAgent, its installation and its removal.
//
//  The agent points at the BUNDLE's binary, so the identity the system grants
//  Accessibility to is a signed application, not an interpreter inside a virtual
//  environment that is rebuilt on every update. That is the whole reason the
//  permission used to need re-granting.
//

import Cocoa

enum Installer {
    static let label = "com.aurel.autocap"
    static let legacyLabel = "com.local.autocap"

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    static var bundlePath: String {
        Bundle.main.bundlePath
    }

    // MARK: launchctl

    @discardableResult
    static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    // MARK: Install

    static func install() -> Int32 {
        guard bundlePath.hasSuffix(".app") else {
            print("REFUSED: \(executablePath) is not inside an .app bundle.")
            print("         The Accessibilité grant must target a stable application identity.")
            print("         Run install.sh, which builds ~/Applications/AutoCap.app first.")
            return 5
        }

        // One engine only: two daemons would both capitalize.
        let legacyStatus = launchctl(["bootout", "gui/\(getuid())/\(legacyLabel)"])
        if legacyStatus == 0 {
            print("legacy agent \(legacyLabel) stopped (it would fight this one)")
        }
        stopLegacyPythonProcesses()

        let payload: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath, "--run"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "ProcessType": "Interactive",
            "StandardOutPath": Log.fileURL.path,
            "StandardErrorPath": Log.fileURL.path,
        ]

        do {
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: payload,
                                                          format: .xml, options: 0)
            try data.write(to: launchAgentURL)
        } catch {
            print("FAILED to write \(launchAgentURL.path): \(error)")
            return 6
        }

        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        let status = launchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        if status != 0 {
            // Older systems: fall back to the legacy loading path.
            _ = launchctl(["load", "-w", launchAgentURL.path])
        }
        launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])

        print("Installed  : \(launchAgentURL.path)")
        print("Executable : \(executablePath)")
        print("Journal    : \(Log.fileURL.path)")
        print("")
        print("If this is the first run, macOS needs the permission granted by hand:")
        print("  System Settings > Privacy & Security > Accessibility")
        print("  add: \(bundlePath)")
        print("then:  launchctl kickstart -k gui/\(getuid())/\(label)")
        print("")
        print("Verify with:  \(executablePath) --doctor")
        return 0
    }

    /// Kill leftover Python daemons from the previous engine.
    ///
    /// Only the exact script name is matched: this must never touch anything
    /// else the user runs.
    static func stopLegacyPythonProcesses() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "autocapitalize.py"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            print("leftover autocapitalize.py process(es) stopped")
        }
    }

    // MARK: Uninstall

    static func uninstall(removePermissions: Bool) -> Int32 {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: launchAgentURL)

        if removePermissions {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            process.arguments = ["reset", "Accessibility", label]
            try? process.run()
            process.waitUntilExit()
            print("Accessibility entry for \(label) reset.")
        }
        print("Uninstalled agent \(label). The application bundle was left in place.")
        return 0
    }

    // MARK: Status

    static func status() -> Int32 {
        print("Agent     : \(label)")
        print("Plist     : \(launchAgentURL.path) "
              + "(\(FileManager.default.fileExists(atPath: launchAgentURL.path) ? "present" : "MISSING"))")
        print("Executable: \(executablePath)")
        print("")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "gui/\(getuid())/\(label)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(),
                              as: UTF8.self)
            if process.terminationStatus == 0 {
                for line in text.split(separator: "\n").prefix(14) {
                    print("  \(line)")
                }
            } else {
                print("  not loaded (run --install)")
            }
        } catch {
            print("  launchctl unreadable: \(error)")
        }

        print("")
        print("Last journal lines:")
        if let content = try? String(contentsOf: Log.fileURL, encoding: .utf8) {
            for line in content.split(separator: "\n").suffix(12) {
                print("  \(line)")
            }
        } else {
            print("  no journal yet at \(Log.fileURL.path)")
        }
        return 0
    }
}
