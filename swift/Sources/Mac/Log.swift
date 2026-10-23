//
//  Log.swift
//  AutoCap — the journal.
//
//  Rules this file enforces, because a silent daemon is undebuggable:
//
//   * every line is timestamped, prefixed and flushed immediately;
//   * --debug traces every event and every decision (stdout AND file);
//   * a condition is written ONCE per change, never once per keystroke: a log
//     nobody can read is a log that hides the bug;
//   * the persistent journal exists whether or not --debug is on, with rotation;
//   * the version and a fingerprint of the running binary are written at start,
//     so a journal can always be tied to the code that produced it.
//

import Foundation

enum LogLevel: Int {
    case error = 0
    case notice = 1
    case debug = 2
}

final class Log {
    static let shared = Log()

    /// Set by --debug (or --run --debug). Everything also goes to the terminal.
    ///
    /// ALSO switched on by the presence of `~/Library/Logs/autocap.debug`, because
    /// the agent is started by launchd with `--run`: without this, getting a full
    /// trace meant editing the plist and re-installing. Creating one empty file is
    /// the whole gesture, deleting it stops the trace.
    var isDebug = FileManager.default.fileExists(
        atPath: Log.directory.appendingPathComponent("autocap.debug").path)

    /// Mirror to stderr only when stderr is a terminal, or under --debug.
    ///
    /// Under launchd, stderr is a file: mirroring there would write every line
    /// twice, once by this class and once by launchd's redirection.
    private let mirrorToTerminal = isatty(STDERR_FILENO) == 1

    private let queue = DispatchQueue(label: "com.aurel.autocap.log")
    private var handle: FileHandle?
    private var previousCondition: [String: String] = [:]
    private let iso = ISO8601DateFormatter()

    private init() {
        iso.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
    }

    // MARK: Location

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("autocap.log") }
    static var statsURL: URL { directory.appendingPathComponent("autocap-stats.log") }

    /// Where launchd sends the process's own output (Swift runtime messages, a
    /// fatalError). Kept apart from the journal so the journal holds one copy of
    /// each line, and only the daemon's lines.
    static var stderrURL: URL { directory.appendingPathComponent("autocap-stderr.log") }

    /// Open the journal, rotating the previous one when it grew too big.
    ///
    /// Rotation is a rename, never a truncation: the file a bug report quotes
    /// from must survive the next start.
    func open(rotateAboveBytes: Int = 2_000_000) {
        let manager = FileManager.default
        try? manager.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        let attributes = (try? manager.attributesOfItem(atPath: Log.fileURL.path)) ?? [:]
        if let size = attributes[.size] as? Int, size > rotateAboveBytes {
            let backup = Log.directory.appendingPathComponent("autocap.log.1")
            try? manager.removeItem(at: backup)
            try? manager.moveItem(at: Log.fileURL, to: backup)
        }
        if !manager.fileExists(atPath: Log.fileURL.path) {
            manager.createFile(atPath: Log.fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: Log.fileURL)
        _ = try? handle?.seekToEnd()
    }

    func close() {
        try? handle?.close()
        handle = nil
    }

    // MARK: Writing

    func write(_ level: LogLevel, _ message: String) {
        guard level != .debug || isDebug else { return }
        let stamp = iso.string(from: Date())
        let marker = level == .debug ? "· debug ·" : (level == .error ? "! error !" : "")
        let line = "[\(stamp)] AutoCap \(marker) \(message)"
        queue.sync {
            if let data = (line + "\n").data(using: .utf8) { handle?.write(data) }
        }
        if isDebug || mirrorToTerminal {
            FileHandle.standardError.write((line + "\n").data(using: .utf8) ?? Data())
        }
    }

    func error(_ message: String) { write(.error, message) }
    func notice(_ message: String) { write(.notice, message) }
    func debug(_ message: String) { write(.debug, message) }

    /// A condition written once, and written again only when it changes.
    ///
    /// This is what keeps the journal readable while still answering "why did it
    /// not capitalize here?": a persistent condition (a field whose caret is
    /// unreadable) must not print one line per keystroke, but a NEW condition
    /// must always print.
    func condition(_ name: String, _ value: String, _ message: String) {
        guard previousCondition[name] != value else { return }
        previousCondition[name] = value
        notice(message)
    }

    func clearCondition(_ name: String) {
        previousCondition[name] = nil
    }

    // MARK: Identity

    /// FNV-1a 64-bit of a byte sequence. Not a security hash: a fingerprint, so a
    /// journal always says WHICH build produced it.
    static func fingerprint(of bytes: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// Version, binary fingerprint, platform: one line, at every start.
    func writeIdentity(version: String) {
        let path = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "?"
        let bytes = (try? Data(contentsOf: URL(fileURLWithPath: path)))
        let print = bytes.map { Log.fingerprint(of: $0) } ?? "unreadable"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        notice("start: version=\(version) binary=\(path) fingerprint=\(print) os=\(os) "
               + "args=\(CommandLine.arguments.dropFirst().joined(separator: " "))")
    }

    // MARK: Statistics

    /// One line per minute: resident size, reads, taps, edits. Bounded file.
    func appendStats(_ line: String, keepLines: Int = 500, maxBytes: Int = 200_000) {
        try? FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Log.statsURL.path) {
            FileManager.default.createFile(atPath: Log.statsURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: Log.statsURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
        let size = handle.offsetInFile
        guard Int(size) > maxBytes else { return }
        if let content = try? String(contentsOf: Log.statsURL, encoding: .utf8) {
            let tail = content.split(separator: "\n").suffix(keepLines).joined(separator: "\n")
            try? Data((tail + "\n").utf8).write(to: Log.statsURL)
        }
    }
}
