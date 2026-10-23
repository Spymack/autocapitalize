//
//  Preferences.swift
//  AutoCap — the macOS text-substitution settings that change what a keystroke
//  actually produces.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  Typing two spaces is not always two spaces: macOS replaces "mot  " with
//  "mot. " when "Add period with double-space" is on. A daemon that keeps its own
//  model of the text must reproduce that substitution, or it will believe a
//  sentence never ended and refuse every capital after it — which is exactly the
//  reported "double space, then no capital".
//
//  The setting is readable, so it is read rather than assumed: modelling a
//  substitution the user disabled would invent a period that is not there.
//

import Foundation

enum SystemTextPreferences {
    /// Read one global preference. `fallback` is used when the key is absent,
    /// which is how macOS reports "never changed from the default".
    static func bool(_ key: String, fallback: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "-g", key]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return fallback
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return fallback }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if text == "1" || text == "true" || text == "yes" { return true }
        if text == "0" || text == "false" || text == "no" { return false }
        return fallback
    }

    /// "Add period with double-space". On by default on macOS.
    static var periodSubstitutionEnabled: Bool {
        bool("NSAutomaticPeriodSubstitutionEnabled", fallback: true)
    }

    /// The system's OWN sentence capitalisation. Worth knowing: when it is on,
    /// most applications already capitalise, and a missing capital here is
    /// masked everywhere except in the apps that do not implement it.
    static var systemCapitalizationEnabled: Bool {
        bool("NSAutomaticCapitalizationEnabled", fallback: false)
    }
}
