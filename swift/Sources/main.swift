//
//  main.swift
//  AutoCap — command line.
//
//  One binary, no interpreter, no virtual environment: the thing the system
//  grants Accessibility to is the thing that runs, and it does not change under
//  the grant when the sources change. That is what makes the permission stable.
//

import Foundation

private let options = Set(CommandLine.arguments.dropFirst())

private func flag(_ name: String) -> Bool { options.contains(name) }

private func usage() {
    print("""
    AutoCap \(Daemon.version) — automatic capitalization for macOS

      --run             run the daemon in the foreground (what launchd starts)
      --install         install and start the LaunchAgent
      --uninstall       stop and remove the LaunchAgent
      --status          agent state, plist, last journal lines
      --selftest        run the rule, trust and measurement suite (no Mac needed)
      --doctor          environment diagnosis, verdict + exit code (0 = ready)
      --probe           describe the focused field of each frontmost application
      --stats           last memory and activity samples
      --version         print the version
      --debug           with --run/--probe: trace every event and every decision

    Journal : \(Log.fileURL.path)
    Stats   : \(Log.statsURL.path)
    """)
}

private func statsReport() -> Int32 {
    print("Stats file: \(Log.statsURL.path)")
    guard let content = try? String(contentsOf: Log.statsURL, encoding: .utf8) else {
        print("No samples yet: the daemon writes one line per minute.")
        return 0
    }
    for line in content.split(separator: "\n").suffix(40) {
        print("  \(line)")
    }
    return 0
}

Log.shared.isDebug = flag("--debug")

switch true {
case flag("--selftest"):
    exit(runSelfTest())
case flag("--doctor"):
    exit(Doctor.run())
case flag("--probe"):
    exit(Probe.run())
case flag("--stats"):
    exit(statsReport())
case flag("--install"):
    exit(Installer.install())
case flag("--uninstall"):
    exit(Installer.uninstall(removePermissions: flag("--remove-permissions")))
case flag("--status"):
    exit(Installer.status())
case flag("--version"):
    print("AutoCap \(Daemon.version)")
    exit(0)
case flag("--run"):
    Daemon().run()
default:
    usage()
    exit(2)
}
