//
//  Daemon.swift
//  AutoCap — the running process: event tap, decision, measurement, journal.
//
//  THE MODEL, in one paragraph. A keystroke arrives; the tap decides whether the
//  incoming letter must be uppercased, from the text that precedes the caret;
//  the decision is journalled with its reason and its SOURCE (measured in the
//  application's text, or modelled in the local buffer); the event is rewritten
//  in place when a capital is owed. Twelve milliseconds later a background read
//  asks the application what its field now contains, and Align.swift turns that
//  answer into a MEASURED caret. The next decision is then made from the
//  application's own text — the same information a human would use — instead of
//  from a buffer whose drift had to be guessed at.
//
//  FAST TYPING. A read answers in milliseconds, a fast typist writes a letter
//  every 60 ms. The model therefore advances SYNCHRONOUSLY on every keystroke
//  (insert here, delete there), so the decision never waits for the application.
//  The read is a correction, not a dependency: it re-anchors the model on the
//  real text and proves the caret. That is the whole difference with the old
//  engine, which had to decide whether a late read was trustworthy.
//
//  WHY A SHADOW BUFFER AT ALL. Three situations have no ground truth: the first
//  keystroke in a field just clicked in Chromium (the platform never publishes
//  that caret), a field whose text is unreadable, and the first moments of a
//  session. The buffer covers exactly those, with an explicit trust level —
//  never silently.
//

import Cocoa
import CoreGraphics

/// How much the local buffer can be believed.
enum Trust: String {
    /// A click, a TAB or an application switch happened: the caret may be anywhere.
    case unknown
    /// Only keystrokes since the last anchor: the buffer follows the caret.
    case keyboardOnly
    /// A read confirmed the field and its caret.
    case confirmed
}

/// What the tap expected the application to do, used to interpret the next read.
enum Expectation {
    case insertion(Int)
    case deletion(Int)

    var label: String {
        switch self {
        case .insertion(let count): return "insertion of \(count)"
        case .deletion(let count): return "deletion of \(count)"
        }
    }
}

/// What the tap decided, with everything the journal needs to explain it.
struct Decision {
    let capitalize: Bool
    let reason: Reason?
    let source: String
    let beforeCaret: String
    let note: String
}

final class Daemon {
    static let version = "1.0.8"

    private var tap: EventTap?
    private var timer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var workspaceObserver: NSObjectProtocol?

    // --- field model, main thread only ---
    private var bundleID: String?
    private var appName: String = "?"
    private var reportedApps = Set<String>()

    /// The application's own text, as last measured (and advanced by the tap
    /// between reads so fast typing stays exact).
    private var fieldText: [Character]?

    /// The text before the last edit, kept until the application publishes it:
    /// this is what the alignment compares against.
    private var pendingOldText: [Character]?

    private var measuredCaret: Int?
    private var caretProven = false

    // --- local fallback model ---
    private var shadow = ""
    private var trust: Trust = .unknown
    private var anchored = false
    private var lineBefore = ""
    private var sawReturn = false

    private var typedGlued = false
    private var expectation: Expectation?
    private var readRetries = 0
    private var readGeneration = 0
    private var lastKnownEditable = false

    // --- counters, for --stats ---
    private var keysSeen = 0
    private var capitals = 0
    private var reads = 0
    private var alignments = 0
    private var refusals = 0
    private var tickCount = 0
    private var lastStatsDate = Date()
    private var lastReadDate = Date.distantPast


    private let readQueue = DispatchQueue(label: "com.aurel.autocap.ax", qos: .userInteractive)

    /// macOS's own "add period with double-space", read once from the system.
    private lazy var periodSubstitutionEnabled = SystemTextPreferences.periodSubstitutionEnabled

    // MARK: - Lifecycle

    func run() -> Never {
        Log.shared.open()
        Log.shared.writeIdentity(version: Daemon.version)

        // A refused launch must never become a crash loop: launchd would restart
        // the process every five seconds and the journal would fill with the same
        // line. Wait for the permission instead — the grant applies to a running
        // process, so the daemon then simply starts working.
        waitForAccessibility()

        installSignalHandlers()
        observeApplicationSwitches()

        tap = EventTap { [unowned self] type, event in
            self.handle(type: type, event: event)
        }
        var attempts = 0
        while tap?.start() != true {
            attempts += 1
            Log.shared.error("event tap could not be created (attempt \(attempts)/30): "
                             + "Input Monitoring permission is the usual cause. "
                             + "System Settings > Privacy & Security > Input Monitoring.")
            if attempts >= 30 {
                Log.shared.error("giving up after 30 attempts — grant Input Monitoring to "
                                 + Bundle.main.bundlePath + " and run: launchctl kickstart -k "
                                 + "gui/\(getuid())/\(Installer.label)")
                exit(4)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        Log.shared.notice("event tap started: enabled=\(tap?.isRunning == true ? 1 : 0)")

        installTimer()
        scheduleRead(after: 0.30, expectation: nil)   // seed the field we are in
        CFRunLoopRun()
        exit(0)
    }

    /// Wait for Accessibility, asking the system to show its dialog once.
    private func waitForAccessibility() {
        guard !AX.isTrusted else { return }
        Log.shared.notice("Accessibility is not granted yet -> waiting (a system dialog may appear once). "
                          + "Target: \(Bundle.main.bundlePath)")
        _ = AX.promptForTrust()
        var lastNotice = Date()
        while !AX.isTrusted {
            if Date().timeIntervalSince(lastNotice) > 30 {
                Log.shared.notice("still waiting for Accessibility — System Settings > "
                                  + "Privacy & Security > Accessibility, add \(Bundle.main.bundlePath)")
                lastNotice = Date()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        Log.shared.notice("Accessibility granted -> starting the tap")
    }

    private func installTimer() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func installSignalHandlers() {
        for number in [SIGTERM, SIGINT, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                Log.shared.notice("signal \(number) -> stopping")
                self?.tap?.stop()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func observeApplicationSwitches() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            self?.applicationChanged(to: application)
        }
    }

    private func applicationChanged(to application: NSRunningApplication?) {
        let newBundle = application?.bundleIdentifier
        guard newBundle != bundleID else { return }
        bundleID = newBundle
        appName = application?.localizedName ?? newBundle ?? "unknown"
        Log.shared.debug("application switch -> \(appName) (\(newBundle ?? "no bundle"))")
        resetFieldContext(reason: "application switch")
        scheduleRead(after: 0.05, expectation: nil)
    }

    // MARK: - Timer

    private func tick() {
        tickCount += 1

        if tickCount % 4 == 0 {
            _ = tap?.checkHealth()
        }

        // Safety net: the per-keystroke read keeps typing instant; this catches
        // changes nothing in the tap could see (speech input, another app
        // writing into the field, a menu action).
        let interval = lastKnownEditable ? 0.25 : 1.0
        if Date().timeIntervalSince(lastReadDate) >= interval {
            scheduleRead(after: 0, expectation: nil)
        }

        if Date().timeIntervalSince(lastStatsDate) >= 60 {
            reportStats()
            lastStatsDate = Date()
        }
    }

    private func reportStats() {
        let megabytes = residentMegabytes()
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) rss=\(String(format: "%.1f", megabytes))MB keys=\(keysSeen) "
            + "capitals=\(capitals) reads=\(reads) alignments=\(alignments) refusals=\(refusals) "
            + "tapReenables=\(tap?.reenableCount ?? 0) tapRebuilds=\(tap?.rebuildCount ?? 0) "
            + "trust=\(trust.rawValue) caret=\(measuredCaret.map(String.init) ?? "-") "
            + "app=\(bundleID ?? "-")"
        Log.shared.appendStats(line)
        if megabytes > 220 {
            Log.shared.error("resident size \(String(format: "%.0f", megabytes)) MB is above the ceiling: "
                             + "report this line with the stats file")
        }
    }

    private func residentMegabytes() -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", "\(getpid())"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (Double(text) ?? 0) / 1024.0
        } catch {
            return 0
        }
    }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) -> CGEvent? {
        switch type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .scrollWheel:
            pointerActivity()
            return nil
        case .keyDown:
            return handleKeyDown(event)
        default:
            return nil
        }
    }

    private func pointerActivity() {
        // A click moves the caret somewhere we cannot see. The TEXT stays valid;
        // only the caret is lost, and the next edit's alignment recovers it.
        measuredCaret = nil
        caretProven = false
        anchored = false
        trust = .unknown
        typedGlued = false
        expectation = nil
        Log.shared.debug("pointer event -> caret unknown, buffer trust unknown")
        scheduleRead(after: 0.06, expectation: nil)
    }

    private func handleKeyDown(_ event: CGEvent) -> CGEvent? {
        keysSeen += 1
        refreshFrontmost()

        if let bundleID, !reportedApps.contains(bundleID) {
            reportedApps.insert(bundleID)
            Log.shared.notice("keydown observed: app=\(bundleID) trusted=\(AX.isTrusted ? 1 : 0) "
                              + "tap=\(tap?.isRunning == true ? 1 : 0)")
        }
        if isBlacklisted(bundleID) { return nil }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let command = flags.contains(.maskCommand)
        let option = flags.contains(.maskAlternate)

        // Shortcuts that rewrite the field wholesale: trust nothing afterwards.
        // Everything else with Command is passed through untouched — including
        // its character payload, which must never reach the model (Command-C
        // carries a "c", and modelling it would corrupt the text).
        if command {
            switch keycode {
            case keyCodeA, keyCodeX, keyCodeV, keyCodeZ, keyCodeY:
                let name = shortcutName(keycode)
                Log.shared.debug("\(name) -> caret unknown, buffer trust unknown")
                if keycode == keyCodeX { expectation = .deletion(1) }
                resetFieldContext(reason: name)
                scheduleRead(after: 0.12, expectation: expectation)
                return nil
            case keyCodeDelete:
                // Command-Delete removes everything to the start of the line:
                // not modelled, the read measures it.
                shadow = deleteLineBackward(shadow)
                advanceModel(deletingBackward: 0)
                anchored = false
                typedGlued = false
                Log.shared.debug("Command-Delete -> line start removed, model dropped")
                scheduleRead(after: 0.012, expectation: .deletion(1))
                return nil
            default:
                return nil
            }
        }

        switch keycode {
        case keyCodeReturn, keyCodeKeypadEnter:
            let currentLine = lineHead(Array(shadow))
            lineBefore = currentLine
            shadow.append("\n")
            sawReturn = true
            anchored = true
            typedGlued = false
            advanceModel(inserting: "\n")
            Log.shared.debug("Return observed: line opened, next letter armed "
                             + "(line above=\(currentLine.count) char)")
            scheduleRead(after: 0.012, expectation: .insertion(1))
            return nil

        case keyCodeTab:
            invalidate(reason: "TAB")
            return nil

        case keyCodeDelete, keyCodeForwardDelete:
            guard keycode == keyCodeDelete else {
                // A forward delete removes what a buffer holding only the text
                // BEFORE the caret cannot describe: drop the model, keep the text.
                invalidate(reason: "forward delete")
                scheduleRead(after: 0.012, expectation: .deletion(1))
                return nil
            }
            if option {
                shadow = deleteWordBackward(shadow)
                advanceModel(deletingBackward: 0)
            } else {
                shadow = deleteBackward(shadow)
                advanceModel(deletingBackward: 1)
            }
            anchored = false
            typedGlued = false
            Log.shared.debug("Delete observed: buffer now \(shadow.count) char, "
                             + "waiting for the application to publish the real length")
            scheduleRead(after: 0.012, expectation: .deletion(1))
            return nil

        case keyCodeUpArrow:
            shadow = stepLineBack(shadow)
            let survives = anchorSurvivesVertical(lineBefore)
            if !survives {
                Log.shared.debug("Up from an opened line: the line above carries "
                                 + "\(lineBefore.count) char -> anchor dropped, "
                                 + "capital only if that line ends a sentence")
            }
            anchored = survives
            measuredCaret = nil
            caretProven = false
            typedGlued = false
            scheduleRead(after: 0.05, expectation: nil)
            return nil

        case keyCodeDownArrow, keyCodeLeftArrow, keyCodeRightArrow, keyCodeHome, keyCodeEnd,
             keyCodePageUp, keyCodePageDown, keyCodeEscape:
            invalidate(reason: "navigation key \(keycode)")
            scheduleRead(after: 0.05, expectation: nil)
            return nil

        default:
            break
        }

        let typed = characters(of: event)
        guard !typed.isEmpty else {
            Log.shared.condition("noCharacters", "\(keycode)",
                                 "key \(keycode) produced no characters (composition, dead key or shortcut)")
            return nil
        }

        guard typed.count == 1, let character = typed.first, character.isLetter else {
            // Punctuation, digits, emoji, multi-character composition: never
            // rewritten, only modelled.
            appendToModels(typed)
            if typed == " " { applyPeriodSubstitutionIfNeeded() }
            expectation = .insertion(typed.count)
            scheduleRead(after: 0.012, expectation: .insertion(typed.count))
            return nil
        }

        let decision = decide()
        if decision.capitalize, let upper = uppercaseSingle(character) {
            setUnicodeString(event, String(upper))
            capitals += 1
            appendToModels(String(upper))
            Log.shared.notice("capital inserted before '\(upper)' "
                              + "(reason=\(decision.reason?.rawValue ?? "-") source=\(decision.source) "
                              + "note=\(decision.note) before=\(quoted(decision.beforeCaret)) app=\(bundleID ?? "-"))")
            if decision.source == "buffer" {
                Log.shared.condition("capitalFromBuffer", bundleID ?? "-",
                                     "capital decided from the local buffer in \(bundleID ?? "unknown app") "
                                     + "— the field text is unreadable here")
            }
        } else {
            appendToModels(typed)
            // A rule that fired and was REFUSED is the interesting case: it is the
            // journal's answer to "why no capital here?". Written always, because
            // requiring a --debug session for it cost four steps and hid three
            // bugs in the previous engine.
            if decision.reason != nil {
                Log.shared.notice("no capital before '\(character)' — a rule fired but was refused "
                                  + "(reason=\(decision.reason?.rawValue ?? "-") source=\(decision.source) "
                                  + "note=\(decision.note) before=\(quoted(decision.beforeCaret)) "
                                  + "app=\(bundleID ?? "-"))")
            } else {
                Log.shared.debug("no capital before '\(character)' (no rule matches; "
                                 + "source=\(decision.source) before=\(quoted(decision.beforeCaret)))")
            }
        }
        expectation = .insertion(1)
        scheduleRead(after: 0.012, expectation: .insertion(1))
        return nil
    }

    // MARK: - The decision

    private func decide() -> Decision {
        // 1. Measured caret: the application's own text, at an offset proved (or
        //    estimated) by alignment. No trust question remains — this is a read.
        if let text = fieldText, let caret = measuredCaret {
            let before = textBeforeCaret(text, caret: caret)
            let reason = capitalizeReason(before, typedGlued: typedGlued)
            guard let reason else {
                return Decision(capitalize: false, reason: nil, source: "measured",
                                beforeCaret: before, note: "no rule matches the measured text")
            }
            return Decision(capitalize: true, reason: reason, source: "measured",
                            beforeCaret: before,
                            note: caretProven ? "proved caret" : "estimated caret")
        }

        // 2. Local buffer, with an explicit trust level.
        let reason = capitalizeReason(shadow, typedGlued: typedGlued)
        guard let reason else {
            return Decision(capitalize: false, reason: nil, source: "buffer",
                            beforeCaret: shadow, note: "no rule matches the buffer")
        }
        let known = trust == .confirmed
        let reliable = trust != .unknown

        // .start rests on the LEFT EDGE of the buffer, so it waits for a
        // confirmed buffer, an observed Return, or a known column-zero caret.
        // Every other verdict is read INSIDE the buffer the tap itself produced:
        // it is valid as soon as the session is keyboard-only. Requiring AX for
        // those is what made this daemon do nothing at all on a machine whose
        // Accessibility reads fail.
        if reason == .start {
            let trusted = canTrustLineStart(axTrusted: known, sawLineBreak: sawReturn,
                                            synthetic: trust == .unknown, anchored: anchored)
            if !trusted {
                return Decision(capitalize: false, reason: reason, source: "buffer",
                                beforeCaret: shadow,
                                note: "start of text not provable here (trust=\(trust.rawValue), "
                                      + "anchored=\(anchored))")
            }
        } else if !(known || reliable) {
            return Decision(capitalize: false, reason: reason, source: "buffer",
                            beforeCaret: shadow,
                            note: "buffer trust is \(trust.rawValue): type once to restore it")
        }
        return Decision(capitalize: true, reason: reason, source: "buffer",
                        beforeCaret: shadow, note: "buffer verdict, trust=\(trust.rawValue)")
    }

    // MARK: - Advancing the model between reads

    /// Keep the measured model exact while the application has not answered yet.
    ///
    /// Without this, a second keystroke arriving before the first read would be
    /// decided from text that is one character behind — the exact failure the old
    /// engine papered over with "lagging read" heuristics.
    private func advanceModel(inserting text: String) {
        guard let current = fieldText, let caret = measuredCaret, caret <= current.count else { return }
        pendingOldText = current
        var updated = current
        updated.insert(contentsOf: Array(text), at: caret)
        fieldText = updated
        measuredCaret = caret + text.count
        caretProven = false          // advanced by hand: still to be confirmed
    }

    /// Same, for a backward deletion. `count` 0 means "not modelled" (word or
    /// line deletion): the model is dropped and the next read re-anchors it.
    private func advanceModel(deletingBackward count: Int) {
        guard count > 0, let current = fieldText, let caret = measuredCaret,
              caret > 0, caret <= current.count else {
            measuredCaret = nil
            caretProven = false
            return
        }
        pendingOldText = current
        var updated = current
        updated.remove(at: caret - 1)
        fieldText = updated
        measuredCaret = caret - 1
        caretProven = false
    }

    private func appendToModels(_ text: String) {
        shadow.append(text)
        if shadow.count > 512 { shadow = String(shadow.suffix(512)) }
        anchored = false
        typedGlued = true
        // Typing restores a usable buffer: the characters the tap itself produced
        // are real even when the field cannot be read through Accessibility. Only
        // .start keeps needing a confirmed left edge (see decide()).
        if trust == .unknown { trust = .keyboardOnly }
        advanceModel(inserting: text)
    }

    /// Reproduce macOS's "add period with double-space" inside the model.
    ///
    /// Typing "mot" then two spaces leaves the APPLICATION holding "mot. ", while
    /// a tap that only counts keystrokes holds "mot  ". The next letter then sees
    /// no sentence end and gets no capital — measured, and the reason the user
    /// reported "double space, then a space, no capital". The substitution is a
    /// readable system preference, so it is modelled only when it is on.
    private func applyPeriodSubstitutionIfNeeded() {
        guard periodSubstitutionEnabled else { return }

        if let text = fieldText, let caret = measuredCaret, caret > 0, caret <= text.count {
            let before = String(text[0..<caret])
            let prefix = doubleSpaceAsPeriod(before)
            if prefix != before {
                fieldText = Array(prefix) + Array(text[caret...])
            }
        }

        let tail = doubleSpaceAsPeriod(shadow)
        if tail != shadow {
            shadow = tail
            Log.shared.debug("double space modelled as a period -> buffer now \(quoted(shadow))")
        }
    }

    // MARK: - Reading the application

    /// Does a read's text length match what the pending edit should have produced?
    ///
    /// No pending edit means nothing to check. An insertion has an exact expected
    /// length; a deletion only has to be shorter, because one Delete key can
    /// remove a whole selection and the application's own length is the authority.
    private func isConsistentWithExpectation(old: [Character]?, newCount: Int) -> Bool {
        guard let old, let expectation else { return true }
        switch expectation {
        case .insertion(let count):
            return newCount == old.count + count
        case .deletion:
            return newCount < old.count
        }
    }

    /// Coarse identity of an alignment refusal, for the once-per-condition rule.
    ///
    /// The numbers in a refusal change with every keystroke; keying the journal on
    /// them printed one line per character, which is how the previous engine's log
    /// became unreadable.
    private func alignmentKind(_ reason: String) -> String {
        if reason.hasPrefix("length mismatch") { return "length mismatch" }
        if reason.hasPrefix("no offset reproduces") { return "no offset reproduces the text" }
        if reason.hasPrefix("the text is not") { return "not a single edit" }
        if reason.hasPrefix("the text did not shrink") { return "no shrink" }
        if reason.hasPrefix("an insertion of zero") { return "empty insertion" }
        return "other"
    }

    private func scheduleRead(after delay: TimeInterval, expectation newExpectation: Expectation?) {
        if let newExpectation { expectation = newExpectation }
        readGeneration += 1
        let generation = readGeneration
        lastReadDate = Date()
        readQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            let result = AX.readField()
            DispatchQueue.main.async {
                self?.applyRead(result, generation: generation)
            }
        }
    }

    private func applyRead(_ result: AXReadResult, generation: Int) {
        guard generation == readGeneration else {
            Log.shared.debug("stale read discarded (generation \(generation) != \(readGeneration))")
            return
        }
        reads += 1

        // Nothing usable: say why — with the AXError codes — once per condition,
        // and fall back to the buffer.
        if result.snapshot == nil {
            let failure = result.failure ?? "unknown failure"
            lastKnownEditable = false
            fieldText = nil
            pendingOldText = nil
            measuredCaret = nil
            caretProven = false
            expectation = nil
            Log.shared.condition("target", "\(bundleID ?? "-")|\(failure)",
                                 "target unreadable: \(failure) (app=\(bundleID ?? "-")): "
                                 + "decisions fall back to the local buffer")
            return
        }
        Log.shared.clearCondition("target")

        guard let snapshot = result.snapshot else { return }
        lastKnownEditable = true


        guard let text = snapshot.text else {
            fieldText = nil
            pendingOldText = nil
            measuredCaret = nil
            Log.shared.condition("noText", bundleID ?? "-",
                                 "target has no text value: role=\(snapshot.role) "
                                 + "app=\(bundleID ?? "-") — decisions fall back to the local buffer")
            return
        }

        let newText = Array(text)
        let old = pendingOldText ?? fieldText
        let consistent = isConsistentWithExpectation(old: old, newCount: newText.count)

        // A read that contradicts the edit we expect has not seen the edit yet:
        // ask again instead of adopting a snapshot that describes the past.
        if !consistent, expectation != nil, readRetries < 3 {
            readRetries += 1
            Log.shared.debug("read arrived before the edit was published "
                             + "(\(old?.count ?? -1) char + \(expectation?.label ?? "-"), "
                             + "read \(newText.count) char) -> retry \(readRetries)/3")
            scheduleRead(after: 0.03 * Double(readRetries), expectation: expectation)
            return
        }

        switch preferredCaretSource(hasPendingEdit: expectation != nil,
                                    platformCaretAvailable: snapshot.caret != nil,
                                    textUnchanged: (old != nil && old == newText),
                                    modelCaretKnown: measuredCaret != nil) {
        case .platform:
            // Idle read: nothing was typed since the last one, so the platform's
            // caret cannot be describing an edit that has not landed yet.
            if let platformCaret = snapshot.caret, platformCaret <= newText.count {
                fieldText = newText
                pendingOldText = nil
                measuredCaret = platformCaret
                caretProven = true
                trust = .confirmed
                // The BUFFER is never rebuilt from an unproven read. Chromium
                // publishes its text late; copying a one-character-behind text
                // into the buffer made the next decision read a stale dot and
                // refuse a legitimate capital. Only a proved alignment (below)
                // may rewrite the buffer.
                Log.shared.debug("idle read: platform caret \(platformCaret)/\(newText.count) char "
                                 + "role=\(snapshot.role) app=\(bundleID ?? "-")")
                Log.shared.clearCondition("alignment")
            }
            return

        case .keep:
            // Idle read, no caret from the platform: nothing to adopt, and above
            // all nothing to throw away. (Discarding the measured caret here made
            // every idle poll of a Chromium field forget where the caret was.)
            if let before = old, before != newText {
                measuredCaret = nil
                caretProven = false
            }
            fieldText = newText
            trust = .confirmed
            return

        case .alignment:
            break
        }

        // No usable caret from the platform: measure it by aligning the two texts.
        guard let previous = old else {
            // First read of a field. A pending edit means the read may have beaten
            // the application — an empty answer would then be mistaken for "empty
            // field, caret 0", which is exactly how a capital landed on the second
            // letter. Ask again instead of concluding.
            if expectation != nil {
                if readRetries < 3 {
                    readRetries += 1
                    Log.shared.debug("first read of the field arrived with \(newText.count) char "
                                     + "while an edit is pending -> retry \(readRetries)/3")
                    scheduleRead(after: 0.03 * Double(readRetries), expectation: expectation)
                } else {
                    Log.shared.debug("first read never showed the edit -> giving up on it, "
                                     + "the buffer decides until the next read")
                    expectation = nil
                    readRetries = 0
                }
                return
            }
            fieldText = newText
            trust = .confirmed
            if newText.isEmpty {
                measuredCaret = 0
                caretProven = true
                shadow = ""
            } else {
                measuredCaret = nil
                Log.shared.condition("noCaret", "\(bundleID ?? "-")|\(snapshot.role)",
                                     "the field exposes no caret range (role=\(snapshot.role), "
                                     + "\(newText.count) char, app=\(bundleID ?? "-")): "
                                     + "the caret will be measured at the next edit")
            }
            return
        }

        let label = expectation?.label ?? "unexpected edit"
        let alignment: Alignment
        switch expectation {
        case .insertion(let count):
            alignment = alignInsertion(old: previous, new: newText, added: count,
                                       previousCaret: measuredCaret)
        case .deletion(let count):
            alignment = alignDeletion(old: previous, new: newText, removedHint: count,
                                      previousCaret: measuredCaret)
        case nil:
            alignment = alignAnyEdit(old: previous, new: newText, previousCaret: measuredCaret)
        }

        switch alignment {
        case .proved(let caret, let ambiguous):
            alignments += 1
            fieldText = newText
            pendingOldText = nil
            measuredCaret = caret
            caretProven = !ambiguous
            trust = .confirmed
            shadow = textBeforeCaret(newText, caret: caret)
            expectation = nil
            readRetries = 0
            let before = quoted(String(textBeforeCaret(newText, caret: caret).suffix(40)))
            Log.shared.debug("edit measured: \(label) \(previous.count) -> \(newText.count) char, "
                             + "\(alignment.label), before=\(before) app=\(bundleID ?? "-")")
            Log.shared.clearCondition("alignment")

        case .refused(let reason):
            refusals += 1
            // The application may not have published the edit yet: Chromium and
            // Electron answer late, and their first answers repeat the old text.
            // Wait longer before giving up — a browser needs more than 120 ms.
            if expectation != nil, readRetries < 4 {
                readRetries += 1
                let delay = [0.03, 0.06, 0.12, 0.25][min(readRetries - 1, 3)]
                Log.shared.debug("edit not visible yet (\(reason)) -> retry \(readRetries)/4 "
                                 + "in \(Int(delay * 1000)) ms")
                scheduleRead(after: delay, expectation: expectation)
                return
            }
            // The lengths DO match what the edit should have produced, so the
            // caret the MODEL holds is still right: the text changed in a way one
            // insertion cannot explain — a smart quote turning ' into ’, an
            // autocorrect replacing a word. Dropping the caret here would discard
            // a position this process knows, and that is what reset the caret to
            // the start of TickTick's quick-add field.
            if consistent, let modelCaret = measuredCaret {
                fieldText = newText
                pendingOldText = nil
                caretProven = false
                expectation = nil
                readRetries = 0
                Log.shared.debug("edit could not be aligned (\(reason)) -> model caret kept at "
                                 + "\(modelCaret)/\(newText.count) char, app=\(bundleID ?? "-")")
                return
            }
            // Deduplicated on the KIND of refusal, never on the numbers: the
            // lengths change with every keystroke, and keying on them printed one
            // line per character (the v20.7 lesson).
            Log.shared.condition("alignment", "\(bundleID ?? "-")|\(alignmentKind(reason))",
                                 "edit could not be measured: \(reason) "
                                 + "(\(previous.count) -> \(newText.count) char, app=\(bundleID ?? "-")): "
                                 + "the caret stays unproven until the next edit")
            fieldText = newText
            pendingOldText = nil
            measuredCaret = nil
            caretProven = false
            expectation = nil
            readRetries = 0
        }
    }

    // MARK: - Context helpers

    private func refreshFrontmost() {
        guard let bundle = AX.frontmostBundle() else { return }
        if bundle != bundleID {
            bundleID = bundle
            appName = AX.frontmostName()
        }
    }

    private func invalidate(reason: String) {
        trust = .unknown
        anchored = false
        measuredCaret = nil
        caretProven = false
        typedGlued = false
        expectation = nil
        Log.shared.debug("\(reason) -> caret unknown, buffer trust unknown")
    }

    private func resetFieldContext(reason: String) {
        fieldText = nil
        pendingOldText = nil
        measuredCaret = nil
        caretProven = false
        shadow = ""
        trust = .unknown
        anchored = false
        lineBefore = ""
        sawReturn = false
        typedGlued = false
        expectation = nil
        readRetries = 0
        Log.shared.debug("field context reset (\(reason))")
    }

    private func shortcutName(_ keycode: Int64) -> String {
        switch keycode {
        case keyCodeA: return "Command-A"
        case keyCodeX: return "Command-X"
        case keyCodeV: return "Command-V"
        case keyCodeZ: return "Command-Z"
        case keyCodeY: return "Command-Y"
        default: return "shortcut"
        }
    }

    // MARK: - Event payload

    private func characters(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        buffer.withUnsafeMutableBufferPointer { pointer in
            event.keyboardGetUnicodeString(maxStringLength: pointer.count,
                                           actualStringLength: &length,
                                           unicodeString: pointer.baseAddress)
        }
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(length), as: UTF16.self)
    }

    private func setUnicodeString(_ event: CGEvent, _ text: String) {
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { pointer in
            event.keyboardSetUnicodeString(stringLength: units.count,
                                           unicodeString: pointer.baseAddress)
        }
    }

    /// Uppercase exactly one letter, and only when the result is still one letter.
    private func uppercaseSingle(_ character: Character) -> Character? {
        let upper = String(character).uppercased()
        guard upper.count == 1, let result = upper.first else { return nil }
        return result
    }

    private func quoted(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "'\(escaped)'"
    }
}
