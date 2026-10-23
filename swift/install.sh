#!/bin/bash
# ============================================================================
#  AutoCap — installeur AUTONOME (une seule commande, aucun téléchargement).
#
#  Ce fichier contient TOUTES les sources de l'application. Il les écrit dans
#  ~/Scripts/autocap-swift, compile ~/Applications/AutoCap.app, exécute la suite
#  de conformité, refuse d'installer si un cas échoue, désactive l'ancien démon
#  Python, installe l'agent launchd, puis affiche un verdict.
#
#  Aucune requête réseau après le téléchargement de ce fichier : la panne
#  « codeload 404 » ne peut plus se produire.
#
#  Lignes attendues :
#    [install] étape N/9 — …
#    [install] VERDICT : PRÊT — AutoCap tourne.
#    [install] VERDICT : ACTION REQUISE (1 geste, une seule fois)
#    [install] VERDICT : ÉCHEC — rien de cassé, l'installation précédente intacte.
#  Toute erreur affiche sa raison exacte ; aucune sortie n'est tronquée.
#
#  Généré par tools/make_install.py — ne pas éditer à la main.
#  Version embarquée : 1.0.1
# ============================================================================
set -uo pipefail

SCRIPTS_DIR="$HOME/Scripts/autocap-swift"
APP="$HOME/Applications/AutoCap.app"
BIN="$APP/Contents/MacOS/AutoCap"
LEGACY_LABEL="com.local.autocap"
LABEL="com.aurel.autocap"

say()  { echo "[install] $*"; }
fail() { echo "[install] ERREUR : $*" >&2; echo "[install] VERDICT : ÉCHEC — rien de cassé, l'installation précédente (si elle existe) est intacte." >&2; exit 1; }

say "démarrage $(date '+%Y-%m-%d %H:%M:%S') — AutoCap 1.0.1"

# --- 1. Prérequis -----------------------------------------------------------
say "étape 1/9 — prérequis"
command -v sw_vers >/dev/null 2>&1 || fail "ce script doit tourner sur macOS."
[ "$(uname -s)" = "Darwin" ] || fail "système détecté : $(uname -s) — ce script exige macOS."
OS_VERSION="$(sw_vers -productVersion)"
say "        macOS $OS_VERSION ($(uname -m))"

SWIFTC="$(command -v swiftc || true)"
if [ -z "$SWIFTC" ] && command -v xcrun >/dev/null 2>&1; then
    SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
fi
if [ -z "$SWIFTC" ]; then
    fail "le compilateur Swift est absent. Installe les outils de développement :
    xcode-select --install
puis relance cette même commande."
fi
say "        swiftc : $("$SWIFTC" --version 2>&1 | head -1)"

# --- 2. Sources embarquées --------------------------------------------------
say "étape 2/9 — écriture des sources embarquées"
[ -n "${HOME:-}" ] || fail "HOME n'est pas défini."
mkdir -p "$SCRIPTS_DIR" || fail "impossible de créer $SCRIPTS_DIR"
mkdir -p "$SCRIPTS_DIR/Sources" || fail "impossible de créer $SCRIPTS_DIR/Sources"
cat > "$SCRIPTS_DIR/Sources/main.swift" <<'AUTOCAP_EOF_0'
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
    // Hold the daemon in a named constant: the event tap keeps an unowned
    // reference to it, so its lifetime must be explicit, not incidental.
    let daemon = Daemon()
    daemon.run()
default:
    usage()
    exit(2)
}
AUTOCAP_EOF_0
mkdir -p "$SCRIPTS_DIR/Sources/Core" || fail "impossible de créer $SCRIPTS_DIR/Sources/Core"
cat > "$SCRIPTS_DIR/Sources/Core/Rules.swift" <<'AUTOCAP_EOF_1'
//
//  Rules.swift
//  AutoCap — automatic capitalization for macOS.
//
//  The DECISION engine, and nothing else. No AppKit, no Accessibility, no I/O:
//  every function here is a pure function of its arguments, which is why this
//  file compiles and runs on any Swift platform and why the whole rule set is
//  verifiable without a Mac (see SelfTest.swift).
//
//  A capital is inserted before a letter when the text BEFORE the caret says a
//  sentence opens there:
//
//    .enumerator  a line-leading list marker ("1)", "12)", "A)", "a)") was found
//    .start       the backwards scan consumed the whole text before the caret
//    .linebreak   a hard line break was found
//    .ender       a sentence ender (. ! ? … 。！？) was found, with a separator
//                 (space or punctuation) after it
//
//  .start is the ONLY reason that rests on the LEFT EDGE of the text we hold:
//  it is therefore the only one that needs external proof (see canTrustLineStart).
//

// MARK: - Character classes

let sentenceEnders: Set<Character> = [".", "!", "?", "\u{2026}", "\u{3002}", "\u{FF01}", "\u{FF1F}"]

let spaceCharacters: Set<Character> = [
    " ", "\t", "\u{00A0}", "\u{202F}", "\u{2009}", "\u{200A}", "\u{2007}",
    "\u{2002}", "\u{2003}", "\u{3000}",
]

let lineBreakCharacters: Set<Character> = ["\n", "\r", "\u{2028}", "\u{2029}", "\u{000B}", "\u{000C}"]

let openerCharacters: Set<Character> = [
    "\"", "'", "`", "\u{201C}", "\u{2018}", "\u{00AB}", "\u{2039}",
    "(", "[", "{", "<", "*", "_", "-", "\u{2022}", "\u{2013}", "\u{2014}", "\u{00B7}",
]

let closerCharacters: Set<Character> = ["\u{201D}", "\u{2019}", "\u{00BB}", "\u{203A}", ")", "]", "}", ">"]

/// Punctuation the backwards scan skips without deciding anything by itself.
let skippablePunctuation: Set<Character> = openerCharacters.union(closerCharacters)

/// Words whose trailing dot does not close a sentence ("etc. ", "M. ", "e.g. ").
let abbreviations: Set<String> = [
    "m", "mm", "mme", "mlle", "mr", "mrs", "ms", "dr", "pr", "st", "ste",
    "etc", "cf", "ex", "p", "pp", "pj", "nb", "ndlr", "env", "av", "bd", "fig",
    "vol", "no", "n\u{00B0}", "art", "ch", "tel", "t\u{00E9}l", "min", "max", "sec",
    "e.g", "i.e", "vs", "approx", "dept", "inc", "ltd", "jr", "sr", "prof",
    "www", "http", "https", "org", "com", "net", "fr", "co", "gov", "edu",
]

// MARK: - Reason

/// Why a capital is owed, or nil. The raw values are what the journal prints.
enum Reason: String {
    case start
    case linebreak
    case ender
    case enumerator
}

// MARK: - Small text helpers

/// The word attached to the dot at `index` (letters, digits, inner dots/hyphens).
func precedingToken(_ text: [Character], dotIndex: Int) -> String {
    var index = dotIndex - 1
    while index >= 0 {
        let character = text[index]
        let attached = character.isLetter || character.isNumber
            || character == "." || character == "-" || character == "\u{2019}"
        if !attached { break }
        index -= 1
    }
    guard index + 1 <= dotIndex else { return "" }
    return String(text[(index + 1)..<dotIndex])
}

/// A dot that does not close a sentence: abbreviation, initial, numbered item, decimal.
func isFalseSentenceEnd(_ text: [Character], index: Int) -> Bool {
    guard index >= 0, index < text.count, text[index] == "." else { return false }
    var token = precedingToken(text, dotIndex: index)
    token = String(token.drop(while: { $0 == "-" || $0 == "'" || $0 == "\u{2019}" }))
    token = String(token.reversed().drop(while: { $0 == "-" || $0 == "'" || $0 == "\u{2019}" }).reversed())
    token = token.lowercased()
    if token.isEmpty { return false }
    if token.allSatisfy({ $0.isNumber }) { return true }
    if token.count == 1, token.first?.isLetter == true { return true }
    return abbreviations.contains(token)
}

/// Everything on the caret's line: what follows the last line break.
func lineHead(_ text: [Character]) -> String {
    var index = -1
    for position in 0..<text.count where lineBreakCharacters.contains(text[position]) {
        index = position
    }
    guard index + 1 <= text.count else { return "" }
    return String(text[(index + 1)...])
}

/// True for "1)", "12)", "A)", "a)" — leading and trailing spaces allowed.
func isEnumeratorHead(_ head: String) -> Bool {
    let body = String(head.drop(while: { $0 == " " || $0 == "\t" }))
                          .reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed()
    guard body.count >= 2, body.last == ")" else { return false }
    let marker = String(body.dropLast())
    if marker.allSatisfy({ $0.isNumber }) { return marker.count <= 3 }
    return marker.count == 1 && marker.first?.isLetter == true
}

/// "enumerator" when the caret sits right after a line-leading list marker.
///
/// Only the head of the caret's line is examined: a "1)" in the middle of a
/// sentence is punctuation, not an enumeration. Unlike .start this verdict does
/// not rest on the left edge of the buffer — the marker is short and
/// self-delimiting, so a truncated or fabricated edge cannot produce it by
/// accident (the cut would have to fall exactly on the marker).
func enumeratorReason(_ beforeCaret: [Character]) -> Reason? {
    isEnumeratorHead(lineHead(beforeCaret)) ? .enumerator : nil
}

/// The text before the caret once it moved to column 0 of the previous line.
///
/// The buffer ends with the break that opened the line the caret is leaving, so
/// that last break comes off first; what remains is everything up to and
/// including the break before the previous line. No break left means the caret
/// is now on the first line, with nothing before it.
func stepLineBack(_ text: String) -> String {
    var characters = Array(text)
    if characters.last.map({ lineBreakCharacters.contains($0) }) == true {
        characters.removeLast()
    }
    var index = -1
    for position in 0..<characters.count where lineBreakCharacters.contains(characters[position]) {
        index = position
    }
    guard index >= 0, index + 1 <= characters.count else { return "" }
    return String(characters[...index])
}

// MARK: - The decision

/// Why the next letter should be uppercased, or nil.
///
/// `typedGlued` says whether the character immediately before the caret was
/// TYPED in this run. It only changes one verdict: a sentence end glued to the
/// caret (nothing typed or skipped between them). Just typed, that dot opens a
/// token ("Test.com") and must not arm; reached by a deletion or a move, it
/// closes a sentence and must arm.
func capitalizeReason(_ beforeCaret: String, typedGlued: Bool = true) -> Reason? {
    let characters = Array(beforeCaret)

    if let reason = enumeratorReason(characters) { return reason }

    var index = characters.count - 1
    var skippedSpace = false
    var skippedPunctuation = false

    while index >= 0 {
        let character = characters[index]
        if spaceCharacters.contains(character) {
            skippedSpace = true
        } else if skippablePunctuation.contains(character) {
            skippedPunctuation = true
        } else {
            break
        }
        index -= 1
    }

    if index < 0 { return .start }

    let character = characters[index]
    if lineBreakCharacters.contains(character) { return .linebreak }
    if sentenceEnders.contains(character) {
        if !(skippedSpace || skippedPunctuation) && typedGlued {
            // A sentence end GLUED to the caret whose character was just typed:
            // that dot opens a token, it does not close a sentence ("Test.com",
            // "3.14", "v2.1", "192.168.1.1"). The separator requirement exists
            // for exactly that case and must stay.
            return nil
        }
        // The same glued dot must ARM when the caret did not arrive there by
        // typing — text deleted after it, or the caret moved onto it.
        return isFalseSentenceEnd(characters, index: index) ? nil : .ender
    }
    return nil
}

/// True when the next letter typed must be uppercased (rule only, no trust).
func shouldCapitalize(_ beforeCaret: String, typedGlued: Bool = true) -> Bool {
    capitalizeReason(beforeCaret, typedGlued: typedGlued) != nil
}

/// Whether a "start of text/line" verdict may be believed.
///
/// It is the strongest reason to capitalize and therefore the one that must
/// never be assumed. A synthetic buffer — one whose left edge was fabricated
/// (the "x" fallback after a pointer event or a TAB completion) or lost
/// (truncated at the buffer cap) — can never claim it, no matter how many spaces
/// or punctuation marks trail behind the caret.
///
/// `anchored` is a third, independent source: this process knows the caret sits
/// at COLUMN ZERO of its line, because it saw the Return that opened the line or
/// because only vertical navigation happened since.
///
/// `proven` is the fourth and strongest: the caret's OFFSET was measured inside
/// the application's own text by alignment (see Align.swift), so offset 0 is a
/// read fact rather than an assumption about a buffer's edge.
func canTrustLineStart(axTrusted: Bool, sawLineBreak: Bool, synthetic: Bool,
                       anchored: Bool = false, proven: Bool = false) -> Bool {
    if anchored || proven { return true }
    if synthetic { return false }
    return axTrusted || sawLineBreak
}

/// Does the column-zero anchor survive an UP move?
///
/// Only when the line above is KNOWN EMPTY, i.e. a second break with nothing
/// typed in between: both editor families then put the caret on that line's
/// column 0. When the line above carries text, the two families disagree — a
/// column-preserving text view lands on that line's first character, a
/// block-based editor (Notion, Electron/Chromium) sends the caret to the END of
/// the previous block, where a capital would land mid-sentence.
func anchorSurvivesVertical(_ lineAbove: String) -> Bool {
    lineAbove.isEmpty
}

/// May this verdict arm a capital from the LOCAL (shadow) buffer?
///
/// .start is the only verdict that rests on the buffer's left edge, so it waits
/// for a confirmed buffer. A sentence end, a line break or an enumerator is read
/// INSIDE the buffer the tap itself maintains, and discarding those because the
/// Accessibility read has not confirmed the field — it never does in Notion,
/// whose caret range is unreadable — silently drops valid capitals.
func mayArmFromShadow(_ reason: Reason?, known: Bool, reliable: Bool) -> Bool {
    guard let reason else { return false }
    if reason == .start { return known }
    return known || reliable
}

/// Full decision: rule engine plus the trust requirement on .start.
func resolveCapitalization(_ beforeCaret: String, axTrusted: Bool, sawLineBreak: Bool,
                           synthetic: Bool, anchored: Bool = false,
                           typedGlued: Bool = true, provenStart: Bool = false) -> Bool {
    guard let reason = capitalizeReason(beforeCaret, typedGlued: typedGlued) else { return false }
    if reason == .start {
        return canTrustLineStart(axTrusted: axTrusted, sawLineBreak: sawLineBreak,
                                 synthetic: synthetic, anchored: anchored, proven: provenStart)
    }
    return true
}

// MARK: - Buffer edits (pure)

func deleteBackward(_ text: String) -> String {
    var characters = Array(text)
    if !characters.isEmpty { characters.removeLast() }
    return String(characters)
}

func deleteWordBackward(_ text: String) -> String {
    let characters = Array(text)
    var index = characters.count
    while index > 0, spaceCharacters.contains(characters[index - 1]) { index -= 1 }
    while index > 0, !spaceCharacters.contains(characters[index - 1]),
          !lineBreakCharacters.contains(characters[index - 1]) { index -= 1 }
    return String(characters[..<index])
}

func deleteLineBackward(_ text: String) -> String {
    let characters = Array(text)
    var index = characters.count - 1
    while index >= 0 {
        if lineBreakCharacters.contains(characters[index]) {
            return String(characters[...index])
        }
        index -= 1
    }
    return ""
}

/// Reproduce the macOS "add period with double-space" substitution.
func applyDoubleSpacePeriod(_ text: String) -> String {
    let characters = Array(text)
    guard characters.count >= 3 else { return text }
    guard characters[characters.count - 1] == " ", characters[characters.count - 2] == " " else {
        return text
    }
    let anchor = characters[characters.count - 3]
    if sentenceEnders.contains(anchor) || spaceCharacters.contains(anchor)
        || lineBreakCharacters.contains(anchor) { return text }
    if !(anchor.isLetter || anchor.isNumber || closerCharacters.contains(anchor)) { return text }
    return String(characters.dropLast(2)) + ". "
}
AUTOCAP_EOF_1
mkdir -p "$SCRIPTS_DIR/Sources/Core" || fail "impossible de créer $SCRIPTS_DIR/Sources/Core"
cat > "$SCRIPTS_DIR/Sources/Core/Align.swift" <<'AUTOCAP_EOF_2'
//
//  Align.swift
//  AutoCap — measuring the caret inside the application's own text.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  The old daemon kept a shadow buffer of the text before the caret and had to
//  GUESS whether that buffer still described reality: lagging reads, frozen
//  reads, reads that still showed the text from before a deletion, synthetic
//  buffers after a click or a TAB completion. Every revision since v11 was a fix
//  in that guessing layer, and the expensive cases (Notion, Arc, any Chromium
//  field) stayed unfixable: Chromium exposes the field's whole text but NEVER
//  the caret range.
//
//  This file removes the guess. Two texts are readable across an edit — the one
//  before and the one after — and an edit is exactly ONE span of the text that
//  changes. Aligning them gives that span's offset; a deletion leaves the caret
//  at the start of what it removed, an insertion at the end of what it added. So
//  the caret becomes a MEASURED fact inside the application's text, in every
//  field whose text is readable, whether or not the platform publishes an
//  insertion point.
//
//  Proved, never guessed. An offset is accepted only when the candidate set
//  reduces to one, or when several candidates reproduce the same text and the
//  nearest one to the previous caret wins — an estimate the caller can see and
//  the journal can print. Anything else is refused with an explicit reason.
//

/// What the alignment concluded.
enum Alignment {
    /// `caret` is the offset the edit left the caret at, inside the new text.
    /// `ambiguous` is true when several offsets reproduced the same text and the
    /// previous caret picked one: usable, but never claimed as a proof.
    case proved(caret: Int, ambiguous: Bool)
    /// The numbers cannot be trusted; `reason` says exactly why (journal line).
    case refused(reason: String)

    var caret: Int? {
        if case .proved(let caret, _) = self { return caret }
        return nil
    }

    var isAmbiguous: Bool {
        if case .proved(_, let ambiguous) = self { return ambiguous }
        return false
    }

    var label: String {
        switch self {
        case .proved(let caret, let ambiguous):
            return ambiguous ? "caret \(caret) (estimated)" : "caret \(caret) (proved)"
        case .refused(let reason):
            return "no caret (\(reason))"
        }
    }
}

/// Common prefix and suffix of two texts.
///
/// They are computed independently on purpose. Bounding the suffix by the prefix
/// (the tempting shortcut) makes a repeated character invisible: "aaa" with an
/// "a" inserted can only be explained by offsets 0…3, and a bounded suffix
/// claims a single one — silently, and wrongly.
func commonEdges(_ old: [Character], _ new: [Character]) -> (prefix: Int, suffix: Int) {
    let shortest = min(old.count, new.count)
    var prefix = 0
    while prefix < shortest, old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < shortest, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
    return (prefix, suffix)
}

/// Longest candidate scan. A text of twenty thousand identical characters can
/// make every offset a candidate; past this many, refusing is the honest answer.
let alignmentCandidateLimit = 512

/// Pick the offset that reproduces `new` exactly, nearest to the previous caret.
///
/// `rebuild(offset)` must answer with the text the application would hold if the
/// edit had happened at that offset. Candidates that do not reproduce it are
/// dropped — they are not "less likely", they are impossible.
private func settle(candidates: [Int], previousCaret: Int?,
                    rebuild: (Int) -> [Character], new: [Character]) -> Alignment? {
    let valid = candidates.filter { rebuild($0) == new }
    if valid.isEmpty { return nil }
    if valid.count == 1 { return .proved(caret: valid[0], ambiguous: false) }
    guard let previousCaret else {
        return .refused(reason: "\(valid.count) offsets reproduce the same text and no previous caret exists")
    }
    let nearest = valid.min { abs($0 - previousCaret) < abs($1 - previousCaret) }!
    return .proved(caret: nearest, ambiguous: true)
}

/// The caret after the application INSERTED `added` characters somewhere.
///
/// Contract: `new` must be `old` with exactly `added` characters inserted once.
func alignInsertion(old: [Character], new: [Character], added: Int,
                    previousCaret: Int?) -> Alignment {
    guard added > 0 else {
        return .refused(reason: "an insertion of zero characters describes no edit")
    }
    guard new.count == old.count + added else {
        return .refused(reason: "length mismatch: \(old.count) + \(added) != \(new.count)")
    }
    let edges = commonEdges(old, new)
    let lower = max(0, old.count - edges.suffix)
    let upper = min(edges.prefix, old.count)
    guard lower <= upper else {
        return .refused(reason: "the text is not \(old.count) char plus one insertion "
                        + "(prefix \(edges.prefix), suffix \(edges.suffix))")
    }
    guard upper - lower < alignmentCandidateLimit else {
        return .refused(reason: "\(upper - lower) candidate offsets: the text is too repetitive to measure")
    }
    let candidates = Array(lower...upper)
    // What the application would hold if the insertion had happened at `offset`:
    // the old text with the NEW text's inserted span spliced in at that offset.
    // Comparing that with `new` is the proof that the offset is right.
    let outcome = settle(candidates: candidates, previousCaret: previousCaret, rebuild: { offset in
        Array(old[0..<offset]) + Array(new[offset..<(offset + added)]) + old[offset...]
    }, new: new)
    // The caret sits at the END of what was inserted.
    if case .proved(let caret, let ambiguous) = outcome {
        return .proved(caret: caret + added, ambiguous: ambiguous)
    }
    return outcome ?? .refused(reason: "no offset reproduces the text: more than one edit, or a rewrite")
}

/// The caret after the application REMOVED one span somewhere.
///
/// `removedHint` is the count the tap believes it deleted (1 for a Delete key).
/// It is never trusted, only reported: a Delete key on a selection removes many
/// characters, and the application's own length difference is the authority.
func alignDeletion(old: [Character], new: [Character], removedHint: Int?,
                   previousCaret: Int?) -> Alignment {
    let removed = old.count - new.count
    guard removed > 0 else {
        return .refused(reason: "the text did not shrink (\(old.count) -> \(new.count) char)")
    }
    let edges = commonEdges(old, new)
    let lower = max(0, new.count - edges.suffix)
    let upper = min(edges.prefix, new.count)
    guard lower <= upper else {
        return .refused(reason: "the text is not \(old.count) char minus one span "
                        + "(prefix \(edges.prefix), suffix \(edges.suffix))")
    }
    guard upper - lower < alignmentCandidateLimit else {
        return .refused(reason: "\(upper - lower) candidate offsets: the text is too repetitive to measure")
    }
    let candidates = Array(lower...upper)
    let outcome = settle(candidates: candidates, previousCaret: previousCaret, rebuild: { offset in
        Array(old[0..<offset]) + old[(offset + removed)...]
    }, new: new)
    // A deletion leaves the caret at the START of what it removed.
    if case .proved = outcome { return outcome! }
    _ = removedHint
    return outcome ?? .refused(reason: "no offset reproduces the text: more than one edit, or a rewrite")
}

/// One edit of unknown kind, decided from the two texts alone.
///
/// Used when the tap's expectation is unavailable or contradicted: the lengths
/// say which kind of edit happened, and the alignment says where.
func alignAnyEdit(old: [Character], new: [Character], previousCaret: Int?) -> Alignment {
    if new.count > old.count {
        return alignInsertion(old: old, new: new, added: new.count - old.count,
                              previousCaret: previousCaret)
    }
    if new.count < old.count {
        return alignDeletion(old: old, new: new, removedHint: nil, previousCaret: previousCaret)
    }
    if old == new {
        return .refused(reason: "the text did not change")
    }
    return .refused(reason: "same length, different text: a replacement rather than an edit")
}

/// The text before the caret, from a text and a measured caret offset.
func textBeforeCaret(_ text: [Character], caret: Int) -> String {
    guard caret > 0 else { return "" }
    return String(text[0..<min(caret, text.count)])
}
AUTOCAP_EOF_2
mkdir -p "$SCRIPTS_DIR/Sources/Core" || fail "impossible de créer $SCRIPTS_DIR/Sources/Core"
cat > "$SCRIPTS_DIR/Sources/Core/SelfTest.swift" <<'AUTOCAP_EOF_3'
//
//  SelfTest.swift
//  AutoCap — the conformance suite.
//
//  This file is the reason the rewrite can be trusted. Every rule the daemon
//  applies to what the user types is checked here as a pure function of a text,
//  with no Mac in the loop, so the suite runs identically on the build machine,
//  on the Mac, and in CI.
//
//  Three families of cases:
//
//    1. the rule table — the contract inherited from the previous engine, case
//       for case: what opens a sentence, what does not (abbreviations, decimals,
//       domains, single letters, spaced punctuation), enumerators, glue rules;
//    2. the trust matrix — when a verdict may be believed: synthetic buffers,
//       observed Returns, the column-zero anchor, vertical moves, provenance;
//    3. the measurement layer — the NEW part: the caret is read out of the
//       application's own text by aligning it before and after an edit. Every
//       ambiguous case is exercised here, including the ones that must be
//       refused: a wrong offset would put a capital in the middle of a sentence.
//

import Foundation

final class CaseRunner {
    private(set) var total = 0
    private(set) var failures = 0

    func expect(_ name: String, _ condition: Bool) {
        total += 1
        if !condition {
            failures += 1
            print("FAIL  \(name)")
        }
    }

    func equal<T: Equatable>(_ name: String, _ got: T?, _ expected: T?) {
        total += 1
        if got != expected {
            failures += 1
            print("FAIL  \(name): expected \(String(describing: expected)), got \(String(describing: got))")
        }
    }
}

/// Run the whole suite. Returns the process exit code (0 = every case passed).
func runSelfTest(verbose: Bool = false) -> Int32 {
    let runner = CaseRunner()

    ruleTable(runner)
    reasonTable(runner)
    bufferTable(runner)
    trustMatrix(runner)
    alignmentTable(runner)
    typingScenarios(runner)

    let passed = runner.total - runner.failures
    print("\(passed)/\(runner.total) cases passed.")
    if runner.failures == 0 {
        print("VERDICT: rules, trust and caret measurement agree with the contract.")
    } else {
        print("VERDICT: \(runner.failures) case(s) FAILED — do not install this build.")
    }
    return runner.failures == 0 ? 0 : 1
}

// MARK: - 1. The rule table

private func ruleTable(_ runner: CaseRunner) {
    // (text before the caret, a capital is owed)
    let cases: [(String, Bool)] = [
        ("", true),
        (" ", true),
        ("        ", true),
        ("\t\t", true),
        ("line\n", true),
        ("line\n     ", true),
        ("line\n\t\t   ", true),
        ("line\n- ", true),
        ("line\n\u{2022} ", true),
        ("\"", true),
        ("Test. ", true),
        ("Test.  ", true),
        ("Test.       ", true),
        ("Test. Test. ", true),
        ("Test.\u{00A0}\u{00A0}", true),
        ("Wow!  ", true),
        ("Wow !   ", true),
        ("Really?\t", true),
        ("Il dit. \u{00AB} ", true),
        ("He said \"Hi.\" ", true),
        ("(fin.) ", true),
        ("done...   ", true),
        ("attends\u{2026} ", true),
        ("line1\nTest.  ", true),
        ("Plopo. ", true),
        ("Plopo. Plopoplpo.      ", true),
        // No capital owed: a token in progress, an abbreviation, a numbering.
        ("Test.", false),
        ("Wow!", false),
        ("3.14", false),
        ("etc. ", false),
        ("M. ", false),
        ("e.g. ", false),
        ("J. ", false),
        ("1. ", false),
        // Enumerators.
        ("1) ", true),
        ("12) ", true),
        ("1)", true),
        ("A) ", true),
        ("a) ", true),
        ("A)", true),
        (" 1) ", true),
        ("1.5) ", false),
        ("1234) ", false),
        ("AB) ", false),
        ("(1) ", false),
        ("Bonjour 1) ", false),
        ("line1\n1) ", true),
        ("line1\nA) ", true),
        ("x1) ", false),
        // Numbers, domains, plain words.
        ("42.   ", false),
        ("www. ", false),
        ("hello ", false),
        ("x, ", false),
        ("x; ", false),
        ("x: ", false),
        ("hello", false),
        ("Test.  P", false),
    ]
    for (text, expected) in cases {
        runner.expect("rule \(debugText(text)) -> \(expected)", shouldCapitalize(text) == expected)
    }
}

// MARK: - 2. Reasons

private func reasonTable(_ runner: CaseRunner) {
    let cases: [(String, Reason?)] = [
        ("", .start),
        ("   ", .start),
        (" ( ", .start),
        ("line\n  ", .linebreak),
        ("Test. ", .ender),
        ("1) ", .enumerator),
        ("A) ", .enumerator),
        ("etc. ", nil),
        ("hello ", nil),
    ]
    for (text, expected) in cases {
        runner.equal("reason \(debugText(text))", capitalizeReason(text), expected)
    }
}

// MARK: - 3. Buffer edits

private func bufferTable(_ runner: CaseRunner) {
    runner.equal("deleteBackward abc", deleteBackward("abc"), "ab")
    runner.equal("deleteBackward a", deleteBackward("a"), "")
    runner.equal("deleteBackward empty", deleteBackward(""), "")
    runner.equal("deleteWordBackward trailing spaces", deleteWordBackward("hello world  "), "hello ")
    runner.equal("deleteWordBackward plain", deleteWordBackward("hello world"), "hello ")
    runner.equal("deleteWordBackward single word", deleteWordBackward("word"), "")
    runner.equal("deleteLineBackward", deleteLineBackward("line1\nline2"), "line1\n")
    runner.equal("deleteLineBackward one line", deleteLineBackward("only"), "")
    runner.equal("double space period", applyDoubleSpacePeriod("mot  "), "mot. ")
    runner.equal("double space after closer", applyDoubleSpacePeriod("(fin)  "), "(fin). ")
    runner.equal("double space after three spaces", applyDoubleSpacePeriod("mot   "), "mot   ")
    runner.equal("double space after a period", applyDoubleSpacePeriod("fin.  "), "fin.  ")
    runner.equal("double space single space", applyDoubleSpacePeriod("mot "), "mot ")
    runner.equal("double space empty", applyDoubleSpacePeriod(""), "")
    runner.equal("stepLineBack one line up", stepLineBack("line1\nline2\n"), "line1\n")
    runner.equal("stepLineBack first line", stepLineBack("line1\n"), "")
    runner.equal("stepLineBack no break", stepLineBack("abc"), "")
    runner.equal("stepLineBack empty", stepLineBack(""), "")
}

// MARK: - 4. The trust matrix

private func trustMatrix(_ runner: CaseRunner) {
    // Rule cases are evaluated with a CONFIRMED, non-synthetic buffer.
    runner.expect("line start needs AX or an observed break",
                  canTrustLineStart(axTrusted: false, sawLineBreak: false, synthetic: false) == false)
    runner.expect("line start trusted after a real Return",
                  canTrustLineStart(axTrusted: false, sawLineBreak: true, synthetic: false))
    runner.expect("line start trusted when AX confirms it",
                  canTrustLineStart(axTrusted: true, sawLineBreak: false, synthetic: false))
    runner.expect("synthetic buffer never claims a line start",
                  canTrustLineStart(axTrusted: true, sawLineBreak: true, synthetic: true) == false)
    runner.expect("ender ignores the synthetic flag",
                  resolveCapitalization("Test. ", axTrusted: false, sawLineBreak: false, synthetic: true))
    runner.expect("break ignores the synthetic flag",
                  resolveCapitalization("a\n ", axTrusted: false, sawLineBreak: false, synthetic: true))

    // Reported regression: TAB, DEL, DEL, SPACE must never launder a capital.
    var shadow = "x"                       // neutral fallback after an accepted completion
    let synthetic = true
    shadow = deleteBackward(shadow)
    let step1 = resolveCapitalization(shadow, axTrusted: false, sawLineBreak: false, synthetic: synthetic)
    shadow = deleteBackward(shadow)
    let step2 = resolveCapitalization(shadow, axTrusted: false, sawLineBreak: false, synthetic: synthetic)
    shadow += " "
    let step3 = resolveCapitalization(shadow, axTrusted: false, sawLineBreak: false, synthetic: synthetic)
    runner.expect("TAB + DEL stays lowercase", step1 == false && step2 == false)
    runner.expect("TAB + DEL + DEL + SPACE stays lowercase", step3 == false)
    runner.expect("synthetic + spaces and quotes stays lowercase",
                  resolveCapitalization("  \u{00AB} ", axTrusted: false, sawLineBreak: false,
                                        synthetic: true) == false)
    runner.expect("confirmed empty field + SPACE capitalizes",
                  resolveCapitalization(" ", axTrusted: true, sawLineBreak: false, synthetic: false))

    // Column-zero anchor: the blank line after Shift+Return.
    runner.expect("anchor alone capitalizes a blank line",
                  resolveCapitalization("", axTrusted: false, sawLineBreak: false,
                                        synthetic: true, anchored: true))
    runner.expect("blank line stays lowercase without an anchor",
                  resolveCapitalization("", axTrusted: false, sawLineBreak: false,
                                        synthetic: true, anchored: false) == false)
    runner.expect("anchor survives a synthetic buffer edge",
                  canTrustLineStart(axTrusted: false, sawLineBreak: false, synthetic: true, anchored: true))
    runner.expect("no anchor still refuses a synthetic line start",
                  canTrustLineStart(axTrusted: false, sawLineBreak: false, synthetic: true,
                                    anchored: false) == false)
    runner.expect("enumerator ignores the synthetic flag",
                  resolveCapitalization("1) ", axTrusted: false, sawLineBreak: false, synthetic: true))
    runner.expect("enumerator ignores the buffer edge",
                  resolveCapitalization("A) ", axTrusted: false, sawLineBreak: false,
                                        synthetic: true, anchored: true))

    // The anchor only survives a vertical move it can PROVE.
    runner.expect("anchor survives an UP move into an empty line above", anchorSurvivesVertical(""))
    runner.expect("anchor falls when the line above carries text",
                  anchorSurvivesVertical("une phrase sans point") == false)
    runner.expect("no capital after UP into a text line",
                  resolveCapitalization("une phrase sans point", axTrusted: false, sawLineBreak: false,
                                        synthetic: true,
                                        anchored: anchorSurvivesVertical("une phrase sans point")) == false)
    runner.expect("a line above holding only a space is not empty",
                  anchorSurvivesVertical(" ") == false)
    runner.expect("a sentence end followed by a space still capitalizes after UP",
                  resolveCapitalization("Fin de phrase. ", axTrusted: false, sawLineBreak: false,
                                        synthetic: true,
                                        anchored: anchorSurvivesVertical("Fin de phrase. ")))

    // Provenance: a glued sentence end arms only when it was NOT just typed.
    runner.expect("a glued sentence end arms a capital after a deletion",
                  resolveCapitalization("Une phrase.", axTrusted: false, sawLineBreak: false,
                                        synthetic: true, typedGlued: false))
    runner.expect("the same glued dot does NOT arm when it was just typed",
                  resolveCapitalization("Une phrase.", axTrusted: false, sawLineBreak: false,
                                        synthetic: true, typedGlued: true) == false)
    runner.expect("a domain in progress stays lowercase",
                  resolveCapitalization("Test.", axTrusted: false, sawLineBreak: false,
                                        synthetic: true, typedGlued: true) == false)
    runner.expect("an abbreviation glued after a deletion stays lowercase",
                  resolveCapitalization("cf.", axTrusted: false, sawLineBreak: false,
                                        synthetic: true, typedGlued: false) == false)

    // Only .start waits for confirmation.
    runner.expect("start waits for a confirmed buffer", mayArmFromShadow(.start, known: false, reliable: true) == false)
    runner.expect("start still arms on a confirmed buffer", mayArmFromShadow(.start, known: true, reliable: false))
    runner.expect("an ender arms on a keyboard-only session", mayArmFromShadow(.ender, known: false, reliable: true))
    runner.expect("an ender does NOT arm on an unconfirmed pointer session",
                  mayArmFromShadow(.ender, known: false, reliable: false) == false)
    runner.expect("no verdict never arms", mayArmFromShadow(nil, known: true, reliable: true) == false)

    // A verified caret offset is a read fact, not an assumption.
    runner.expect("a PROVEN start arms the capital",
                  resolveCapitalization("", axTrusted: false, sawLineBreak: false, synthetic: true,
                                        provenStart: true))
    runner.expect("canTrustLineStart accepts a proven offset",
                  canTrustLineStart(axTrusted: false, sawLineBreak: false, synthetic: true, proven: true))
}

// MARK: - 5. Measuring the caret

private func alignmentTable(_ runner: CaseRunner) {
    // Insertion at the end of a sentence: one candidate, proved.
    var result = alignInsertion(old: Array("Fin. "), new: Array("Fin. a"), added: 1, previousCaret: 5)
    runner.equal("insertion at the end reports caret 6", result.caret, 6)
    runner.expect("insertion at the end is not ambiguous", result.isAmbiguous == false)

    // The user's own case: a sentence deleted from the line above.
    let crossOld = "Fin. Suite\nsur la ligne"
    let crossNew = "Fin.  la ligne"
    result = alignDeletion(old: Array(crossOld), new: Array(crossNew), removedHint: 1, previousCaret: 14)
    runner.equal("deletion crossing the line reports the caret at its start", result.caret, 5)
    runner.expect("the text before the caret is the real one",
                  textBeforeCaret(Array(crossNew), caret: 5) == "Fin. ")
    runner.expect("so the sentence end arms the capital",
                  resolveCapitalization("Fin. ", axTrusted: false, sawLineBreak: false, synthetic: true,
                                        provenStart: false))

    // A deletion inside a sentence must not arm anything.
    let midOld = "Bonjour tout le monde\nsalut les amis"
    let midNew = "Bonjour toutles amis"
    result = alignDeletion(old: Array(midOld), new: Array(midNew), removedHint: 1, previousCaret: 18)
    runner.equal("a crossing deletion mid-sentence gives the real offset", result.caret, 12)
    runner.expect("and nothing is capitalized mid-sentence",
                  resolveCapitalization(textBeforeCaret(Array(midNew), caret: 12),
                                        axTrusted: false, sawLineBreak: false, synthetic: true,
                                        provenStart: true) == false)

    // Deleting the whole field: the caret at offset 0 is a read fact.
    result = alignDeletion(old: Array("Une phrase entiere"), new: [], removedHint: 1, previousCaret: 18)
    runner.equal("deleting the whole text proves the caret at offset 0", result.caret, 0)
    runner.expect("a proven offset 0 arms the capital",
                  resolveCapitalization("", axTrusted: false, sawLineBreak: false, synthetic: true,
                                        provenStart: true))

    // Repeated characters: several offsets reproduce the text, the previous
    // caret picks one and the verdict is reported as an estimate.
    result = alignInsertion(old: Array("aaa"), new: Array("aaaa"), added: 1, previousCaret: 1)
    runner.equal("repeated characters: the nearest offset wins", result.caret, 2)
    runner.expect("and it is reported as an estimate, never a proof", result.isAmbiguous)

    result = alignInsertion(old: Array("aaa"), new: Array("aaaa"), added: 1, previousCaret: nil)
    runner.expect("with no previous caret, ambiguity is refused", result.caret == nil)
    if case .refused(let reason) = result {
        runner.expect("the refusal says why", reason.contains("offsets reproduce the same text"))
    } else {
        runner.expect("the refusal says why", false)
    }

    // Wrong expectations are refused, never guessed.
    result = alignInsertion(old: Array("abc"), new: Array("abcdef"), added: 1, previousCaret: 3)
    runner.expect("a wrong inserted length is refused", result.caret == nil)
    result = alignDeletion(old: Array("abc"), new: Array("abc"), removedHint: 1, previousCaret: 3)
    runner.expect("a text that did not shrink is refused", result.caret == nil)
    result = alignDeletion(old: Array("abc"), new: Array("axc"), removedHint: 1, previousCaret: 2)
    runner.expect("a replacement is refused", result.caret == nil)

    // Same length, different text.
    result = alignAnyEdit(old: Array("chat"), new: Array("chien"), previousCaret: 4)
    runner.expect("a rewrite of the same length is refused", result.caret == nil)

    // Kind inferred from the lengths.
    result = alignAnyEdit(old: Array("Fin. "), new: Array("Fin. a"), previousCaret: 5)
    runner.equal("alignAnyEdit infers an insertion", result.caret, 6)
    result = alignAnyEdit(old: Array("Fin. abc"), new: Array("Fin. "), previousCaret: 9)
    runner.equal("alignAnyEdit infers a deletion", result.caret, 5)

    // A single-character deletion at the caret: the ordinary Delete key.
    result = alignDeletion(old: Array("Plopo. ab"), new: Array("Plopo. a"), removedHint: 1, previousCaret: 9)
    runner.equal("a one-character deletion leaves the caret one back", result.caret, 8)

    // Typing at the very end of a long text.
    let long = String(repeating: "x", count: 400) + "Fin. "
    result = alignInsertion(old: Array(long), new: Array(long + "A"), added: 1, previousCaret: 405)
    runner.equal("an insertion at the end of a long text", result.caret, 406)
}

// MARK: - 6. Typing scenarios

/// Drive the daemon's model: a text, a caret, and the letters typed. The
/// alignment layer runs after every event, exactly as it does in the daemon, so
/// this exercises the composition of rules and measurement rather than either
/// one alone.
private func typingScenarios(_ runner: CaseRunner) {
    let typed = "Plopo. Plopoplpo.      Ploplgfdg dfmglf dgdgfd dgdfg. gdfgdfgdf.    dfdffd"
    let expected = "Plopo. Plopoplpo.      Ploplgfdg dfmglf dgdgfd dgdfg. Gdfgdfgdf.    Dfdffd"
    runner.equal("fast typing, whole sentence", simulateTyping(typed), expected)

    // The first letter of a field is capitalized: an empty buffer is .start, and
    // the daemon may only arm that on a field whose text it has confirmed — which
    // is the case here (the text before the first letter is empty, measured).
    runner.equal("the first letter of a field is capitalized", simulateTyping("hello world"), "Hello world")
    runner.equal("a domain in progress stays lowercase", simulateTyping("Test.com"), "Test.com")
    runner.equal("the first letter opens the line", simulateTyping("line1"), "Line1")
    runner.equal("new line opens a capital", simulateTyping("Fin.\nsuite"), "Fin.\nSuite")
    runner.equal("abbreviation keeps the next word lowercase", simulateTyping("etc. suite"), "Etc. suite")
    runner.equal("quoted sentence opener", simulateTyping("Il dit. \u{00AB}bonjour"), "Il dit. \u{00AB}Bonjour")
}

/// Minimal model of the daemon: shadow buffer plus capital decision, no macOS.
private func simulateTyping(_ input: String) -> String {
    var produced = ""
    var shadow = ""
    for character in input {
        if character.isLetter, capitalizeReason(shadow) != nil {
            produced.append(Character(String(character).uppercased()))
            shadow.append(Character(String(character).uppercased()))
        } else {
            produced.append(character)
            shadow.append(character)
        }
    }
    return produced
}

// MARK: - Helpers

private func debugText(_ text: String) -> String {
    let escaped = text
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\t", with: "\\t")
    return "\"\(escaped)\""
}
AUTOCAP_EOF_3
mkdir -p "$SCRIPTS_DIR/Sources/Mac" || fail "impossible de créer $SCRIPTS_DIR/Sources/Mac"
cat > "$SCRIPTS_DIR/Sources/Mac/AX.swift" <<'AUTOCAP_EOF_4'
//
//  AX.swift
//  AutoCap — the Accessibility side: what field has the focus, what it contains,
//  and where the insertion point is (when the platform is willing to say).
//
//  Deliberate design choices:
//
//   * The attribute names are written as string literals ("AXValue", …) rather
//     than through the imported constants. The names are ABI-stable, and the
//     imported constants have shifted type between SDKs; a literal cannot fail
//     to compile on a different toolchain.
//
//   * NOTHING here is called from inside the event tap. A synchronous
//     Accessibility read in a tap callback stalls the whole system event stream:
//     that is the one rule the previous engine learned the hard way, and it is
//     enforced by the caller (Daemon.scheduleRead), not by hope.
//
//   * A read that fails says WHY. "No capital" is not a diagnosis.
//

import Cocoa
import ApplicationServices

/// What the focused field said, once, at one instant.
struct FieldSnapshot {
    let role: String
    let subrole: String?
    let text: String?
    let caret: Int?
    let length: Int?
    let bundleID: String?

    var caretOffset: Int? { caret }

    /// Human-readable one-liner for --probe and for the journal.
    var summary: String {
        let textPart = text.map { "text=\($0.count) char" } ?? "text=unreadable"
        let caretPart = caret.map { "caret=\($0)" } ?? "caret=unreadable"
        return "role=\(role) subrole=\(subrole ?? "-") \(textPart) \(caretPart)"
    }
}

/// Why a read produced nothing usable. Always named, never silent.
enum AXFailure: String {
    case noFocusedElement = "no focused element"
    case notAnEditableField = "not an editable text field"
    case excludedField = "excluded field (secure, search or URL)"
    case noTextValue = "the field exposes no text value"
    case noCaretRange = "the field exposes no caret range"
}

/// Applications where automatic capitalization is harmful: shells, editors with
/// modal keybindings, IDEs with their own completion, remote sessions, games.
let blacklistedBundles: Set<String> = [
    "com.apple.terminal",
    "com.googlecode.iterm2",
    "co.zeit.hyper",
    "dev.warp.warp-stable",
    "net.kovidgoyal.kitty",
    "io.alacritty",
    "com.github.wez.wezterm",
    "com.microsoft.vscode",
    "com.microsoft.vscodeinsiders",
    "com.vscodium",
    "com.todesktop.230313mzl4w4u92",   // Cursor
    "com.exafunction.windsurf",
    "com.sublimetext.4",
    "com.apple.dt.xcode",
    "com.jetbrains.pycharm",
    "com.jetbrains.intellij",
    "com.jetbrains.webstorm",
    "com.jetbrains.clion",
    "com.jetbrains.goland",
    "com.jetbrains.rider",
    "org.vim.macvim",
    "org.gnu.emacs",
    "com.apple.screensharing",
    "com.teamviewer.teamviewer",
    "com.realvnc.vncviewer",
    "com.parallels.desktop.console",
    "com.vmware.fusion",
    "org.virtualbox.app.virtualboxvm",
    "com.utmapp.utm",
    "com.valvesoftware.steam",
]

/// AX roles that carry editable prose. Anything else is ignored outright.
let editableRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox"]

/// Subroles that must never be touched, even with an editable role.
let excludedSubroles: Set<String> = [
    "AXSecureTextField", "AXSearchField", "AXURIField", "AXAddressField",
]

func isBlacklisted(_ bundleID: String?) -> Bool {
    guard let bundleID else { return false }
    return blacklistedBundles.contains(bundleID.lowercased())
}

func isEditableTarget(role: String?, subrole: String?) -> Bool {
    guard let role, editableRoles.contains(role) else { return false }
    if let subrole, excludedSubroles.contains(subrole) { return false }
    if role.contains("Secure") { return false }
    return true
}

enum AX {
    // MARK: Permission

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask the system to show its own permission dialog (once).
    @discardableResult
    static func promptForTrust() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Frontmost application

    static func frontmostBundle() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    static func frontmostPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func frontmostName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
    }

    // MARK: Element access

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func intAttribute(_ element: AXUIElement, _ name: String) -> Int? {
        (attribute(element, name) as? NSNumber)?.intValue
    }

    static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        guard let raw = attribute(system, "AXFocusedUIElement") else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    /// The insertion point, when the platform publishes one.
    ///
    /// Chromium does not, in its contenteditable fields: that is not a bug to
    /// work around here, it is the reason Align.swift exists.
    static func caretOffset(_ element: AXUIElement) -> Int? {
        guard let raw = attribute(element, "AXSelectedTextRange") else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        var range = CFRange()
        let ok = withUnsafeMutablePointer(to: &range) { pointer -> Bool in
            AXValueGetValue(value, .cfRange, pointer)
        }
        guard ok else { return nil }
        // A negative offset is the platform's way of saying "no range"; anything
        // else is a real offset and is bounded by the caller.
        guard range.location >= 0 else { return nil }
        return range.location
    }

    /// Read the focused field, or say exactly why there is nothing to read.
    static func readField() -> (snapshot: FieldSnapshot?, failure: AXFailure?) {
        guard let element = focusedElement() else { return (nil, .noFocusedElement) }

        let role = stringAttribute(element, "AXRole")
        let subrole = stringAttribute(element, "AXSubrole")

        guard isEditableTarget(role: role, subrole: subrole) else {
            if let subrole, excludedSubroles.contains(subrole) { return (nil, .excludedField) }
            return (nil, .notAnEditableField)
        }

        let text = stringAttribute(element, "AXValue")
        let caret = caretOffset(element)
        let length = intAttribute(element, "AXNumberOfCharacters")

        if text == nil && caret == nil {
            return (nil, .noTextValue)
        }

        let snapshot = FieldSnapshot(role: role ?? "?", subrole: subrole, text: text,
                                     caret: caret, length: length ?? text?.count,
                                     bundleID: frontmostBundle())
        return (snapshot, caret == nil ? .noCaretRange : nil)
    }
}
AUTOCAP_EOF_4
mkdir -p "$SCRIPTS_DIR/Sources/Mac" || fail "impossible de créer $SCRIPTS_DIR/Sources/Mac"
cat > "$SCRIPTS_DIR/Sources/Mac/Tap.swift" <<'AUTOCAP_EOF_5'
//
//  Tap.swift
//  AutoCap — the event tap, and nothing else.
//
//  The tap is the only place allowed to look at a keystroke, and it is the only
//  place that must never be slow: a callback that blocks stalls the system event
//  stream. It therefore does buffer arithmetic and returns; every Accessibility
//  read happens later, on another queue (see Daemon).
//
//  macOS disables a tap that times out or that it considers tampered with. That
//  is normal, not exceptional: the watchdog re-enables it, and if the re-enable
//  fails the tap is rebuilt. Both events are journalled, because a tap silently
//  dead is precisely the failure that looks like "nothing happens".
//

import Cocoa
import CoreGraphics

let keyCodeReturn: Int64 = 36
let keyCodeKeypadEnter: Int64 = 76
let keyCodeDelete: Int64 = 51
let keyCodeForwardDelete: Int64 = 117
let keyCodeTab: Int64 = 48
let keyCodeEscape: Int64 = 53
let keyCodeLeftArrow: Int64 = 123
let keyCodeRightArrow: Int64 = 124
let keyCodeDownArrow: Int64 = 125
let keyCodeUpArrow: Int64 = 126
let keyCodeHome: Int64 = 115
let keyCodeEnd: Int64 = 119
let keyCodePageUp: Int64 = 116
let keyCodePageDown: Int64 = 121
let keyCodeA: Int64 = 0
let keyCodeX: Int64 = 7
let keyCodeV: Int64 = 9
let keyCodeY: Int64 = 16
let keyCodeZ: Int64 = 6

/// The C callback. No captures: it must be a plain function pointer, and the
/// daemon reaches it through `refcon`.
private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tap.reenable(reason: type == .tapDisabledByTimeout ? "timeout" : "user input")
        return Unmanaged.passUnretained(event)
    }

    if let replacement = tap.handler(type, event) {
        return Unmanaged.passUnretained(replacement)
    }
    return Unmanaged.passUnretained(event)
}

final class EventTap {
    typealias Handler = (CGEventType, CGEvent) -> CGEvent?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var createdAt = Date()
    private(set) var reenableCount = 0
    private(set) var rebuildCount = 0
    let handler: Handler

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isRunning: Bool {
        guard let tap else { return false }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// Build the tap and attach it to the main run loop.
    ///
    /// Returns false when the system refuses (missing permission, or a session
    /// where taps are not allowed) — the caller turns that into a clear verdict
    /// instead of a silent daemon.
    @discardableResult
    func start() -> Bool {
        stop()

        var mask: CGEventMask = 0
        let interesting: [CGEventType] = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .scrollWheel,
        ]
        for type in interesting {
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: port, enable: true)
        createdAt = Date()
        return isRunning
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
    }

    /// Ask the system to switch the tap back on after it disabled it.
    func reenable(reason: String) {
        guard let tap else { return }
        reenableCount += 1
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.shared.notice("tap was disabled by macOS (\(reason)) -> re-enabled "
                          + "(count=\(reenableCount), stillEnabled=\(CGEvent.tapIsEnabled(tap: tap)))")
    }

    /// Watchdog: re-enable, and rebuild if re-enabling did not take.
    ///
    /// A tap that stays dead is the worst failure this tool can have, because
    /// nothing the user does will look different from "the app does not work".
    func checkHealth() -> Bool {
        guard let tap else {
            rebuildCount += 1
            Log.shared.error("tap missing at health check -> rebuilding")
            return start()
        }
        if CGEvent.tapIsEnabled(tap: tap) { return true }
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            Log.shared.notice("tap was off at health check -> re-enabled")
            return true
        }
        rebuildCount += 1
        Log.shared.error("tap refused to re-enable -> rebuilding (count=\(rebuildCount))")
        return start()
    }
}
AUTOCAP_EOF_5
mkdir -p "$SCRIPTS_DIR/Sources/Mac" || fail "impossible de créer $SCRIPTS_DIR/Sources/Mac"
cat > "$SCRIPTS_DIR/Sources/Mac/Daemon.swift" <<'AUTOCAP_EOF_6'
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
    static let version = "1.0.1"

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
            expectation = .insertion(typed.count)
            scheduleRead(after: 0.012, expectation: .insertion(typed.count))
            return nil
        }

        let decision = decide()
        if decision.capitalize, let upper = uppercaseSingle(character) {
            setUnicodeString(event, upper)
            capitals += 1
            appendToModels(String(upper))
            Log.shared.debug("capital inserted before '\(upper)' "
                             + "(reason=\(decision.reason?.rawValue ?? "-") source=\(decision.source) "
                             + "note=\(decision.note) before=\(quoted(decision.beforeCaret)) app=\(bundleID ?? "-"))")
            if decision.source == "buffer" {
                Log.shared.condition("capitalFromBuffer", bundleID ?? "-",
                                     "capital decided from the local buffer in \(bundleID ?? "unknown app") "
                                     + "— the field text is unreadable here")
            }
        } else {
            appendToModels(typed)
            Log.shared.debug("no capital before '\(character)' "
                             + "(reason=\(decision.reason?.rawValue ?? "none") source=\(decision.source) "
                             + "note=\(decision.note) before=\(quoted(decision.beforeCaret)))")
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
        guard mayArmFromShadow(reason, known: known, reliable: reliable) else {
            return Decision(capitalize: false, reason: reason, source: "buffer",
                            beforeCaret: shadow,
                            note: "buffer trust is \(trust.rawValue): this verdict needs a confirmed buffer")
        }
        if reason == .start {
            let trusted = canTrustLineStart(axTrusted: known, sawLineBreak: sawReturn,
                                            synthetic: trust == .unknown, anchored: anchored)
            if !trusted {
                return Decision(capitalize: false, reason: reason, source: "buffer",
                                beforeCaret: shadow,
                                note: "start of text not provable here (trust=\(trust.rawValue), "
                                      + "anchored=\(anchored))")
            }
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
        advanceModel(inserting: text)
    }

    // MARK: - Reading the application

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

    private func applyRead(_ result: (snapshot: FieldSnapshot?, failure: AXFailure?),
                           generation: Int) {
        guard generation == readGeneration else {
            Log.shared.debug("stale read discarded (generation \(generation) != \(readGeneration))")
            return
        }
        reads += 1

        // Nothing usable: say why, once per condition, and fall back to the buffer.
        if result.snapshot == nil {
            let failure = result.failure?.rawValue ?? "unknown failure"
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

        // The platform's own caret, when it publishes one, is authoritative.
        if let platformCaret = snapshot.caret, platformCaret <= newText.count {
            fieldText = newText
            pendingOldText = nil
            measuredCaret = platformCaret
            caretProven = true
            trust = .confirmed
            shadow = textBeforeCaret(newText, caret: platformCaret)
            expectation = nil
            readRetries = 0
            Log.shared.debug("read: platform caret \(platformCaret)/\(newText.count) char "
                             + "role=\(snapshot.role) app=\(bundleID ?? "-")")
            Log.shared.clearCondition("alignment")
            return
        }

        // No caret from the platform: measure it by aligning the two texts.
        let old = pendingOldText ?? fieldText
        guard let previous = old else {
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
            // The application may not have published the edit yet (Chromium
            // answers late and its first answers repeat the old text). Wait and
            // ask again instead of dropping the expectation on the floor.
            if expectation != nil, readRetries < 3 {
                readRetries += 1
                Log.shared.debug("edit not visible yet (\(reason)) -> retry \(readRetries)/3")
                scheduleRead(after: 0.04 * Double(readRetries), expectation: expectation)
                return
            }
            Log.shared.condition("alignment", "\(bundleID ?? "-")|\(reason)",
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
AUTOCAP_EOF_6
mkdir -p "$SCRIPTS_DIR/Sources/Mac" || fail "impossible de créer $SCRIPTS_DIR/Sources/Mac"
cat > "$SCRIPTS_DIR/Sources/Mac/Log.swift" <<'AUTOCAP_EOF_7'
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
    var isDebug = false

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
        let size = (try? handle.offsetInFile) ?? 0
        guard Int(size) > maxBytes else { return }
        if let content = try? String(contentsOf: Log.statsURL, encoding: .utf8) {
            let tail = content.split(separator: "\n").suffix(keepLines).joined(separator: "\n")
            try? Data((tail + "\n").utf8).write(to: Log.statsURL)
        }
    }
}
AUTOCAP_EOF_7
mkdir -p "$SCRIPTS_DIR/Sources/Mac" || fail "impossible de créer $SCRIPTS_DIR/Sources/Mac"
cat > "$SCRIPTS_DIR/Sources/Mac/Doctor.swift" <<'AUTOCAP_EOF_8'
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
AUTOCAP_EOF_8
mkdir -p "$SCRIPTS_DIR/Sources/Mac" || fail "impossible de créer $SCRIPTS_DIR/Sources/Mac"
cat > "$SCRIPTS_DIR/Sources/Mac/Install.swift" <<'AUTOCAP_EOF_9'
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
            "StandardOutPath": Log.stderrURL.path,
            "StandardErrorPath": Log.stderrURL.path,
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
AUTOCAP_EOF_9
mkdir -p "$SCRIPTS_DIR/Resources" || fail "impossible de créer $SCRIPTS_DIR/Resources"
cat > "$SCRIPTS_DIR/Resources/Info.plist" <<'AUTOCAP_EOF_10'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>fr</string>
    <key>CFBundleExecutable</key>
    <string>AutoCap</string>
    <key>CFBundleIdentifier</key>
    <string>com.aurel.autocap</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AutoCap</string>
    <key>CFBundleDisplayName</key>
    <string>AutoCap</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>AutoCap — capitalisation automatique</string>
</dict>
</plist>
AUTOCAP_EOF_10
cat > "$SCRIPTS_DIR/build.sh" <<'AUTOCAP_EOF_11'
#!/bin/bash
# ============================================================================
#  build.sh — construit AutoCap.app (Swift, aucun interpréteur, aucune dépendance)
#
#  Sortie : un bundle signé ad-hoc à l'emplacement demandé (défaut
#  ~/Applications/AutoCap.app). La signature ad-hoc donne au système une identité
#  stable : l'autorisation Accessibilité porte sur une APPLICATION, pas sur un
#  interpréteur dans un venv qui change à chaque mise à jour.
#
#  Lignes attendues :
#    [build] swiftc : <version>
#    [build] sources : N fichiers
#    [build] binaire : <chemin> (<taille>)
#    [build] signature : ok | avertissement
#    [build] VERDICT : AutoCap.app prêt
#  En cas d'échec, la sortie de swiftc est imprimée ENTIÈRE (jamais tronquée).
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="${1:-$HOME/Applications/AutoCap.app}"
LOG_PREFIX="[build]"

fail() { echo "$LOG_PREFIX ERREUR : $*" >&2; exit 1; }

echo "$LOG_PREFIX démarré $(date '+%Y-%m-%d %H:%M:%S') sur $(uname -m) / macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"

# --- 1. Chaîne de compilation -----------------------------------------------
SWIFTC="$(command -v swiftc || true)"
if [ -z "$SWIFTC" ] && command -v xcrun >/dev/null 2>&1; then
    SWIFTC="$(xcrun --find swiftc 2>/dev/null || true)"
fi
[ -n "$SWIFTC" ] || fail "swiftc introuvable. Installe les outils de développement :
    xcode-select --install
puis relance cette commande."
echo "$LOG_PREFIX swiftc : $("$SWIFTC" --version 2>&1 | head -2 | tr '\n' ' ')"

[ -d "$HERE/Sources" ] || fail "dossier Sources absent dans $HERE"
[ -f "$HERE/Resources/Info.plist" ] || fail "Resources/Info.plist absent dans $HERE"

SOURCES=()
while IFS= read -r line; do SOURCES+=("$line"); done < <(find "$HERE/Sources" -name '*.swift' | sort)
[ "${#SOURCES[@]}" -gt 0 ] || fail "aucun fichier .swift trouvé dans $HERE/Sources"
echo "$LOG_PREFIX sources : ${#SOURCES[@]} fichiers"

# --- 2. Bundle ---------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" || fail "impossible de créer $APP"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist" || fail "copie Info.plist impossible"

# --- 3. Compilation ---------------------------------------------------------
echo "$LOG_PREFIX compilation…"
BUILD_OUT="$("$SWIFTC" -O -whole-module-optimization -swift-version 5 \
    -module-name AutoCap \
    -o "$APP/Contents/MacOS/AutoCap" \
    "${SOURCES[@]}" \
    -framework Cocoa -framework ApplicationServices -framework CoreGraphics 2>&1)"
BUILD_STATUS=$?
if [ $BUILD_STATUS -ne 0 ]; then
    echo "$BUILD_OUT" >&2
    fail "la compilation a échoué (code $BUILD_STATUS) — la sortie complète est ci-dessus.
Rien n'a été installé : l'ancienne version, si elle existe, est intacte."
fi
[ -n "$BUILD_OUT" ] && echo "$BUILD_OUT"
[ -x "$APP/Contents/MacOS/AutoCap" ] || fail "binaire absent après compilation"

SIZE="$(stat -f%z "$APP/Contents/MacOS/AutoCap" 2>/dev/null || echo '?')"
echo "$LOG_PREFIX binaire : $APP/Contents/MacOS/AutoCap ($SIZE octets)"

# --- 4. Signature ad-hoc ----------------------------------------------------
if codesign --force --sign - --timestamp=none "$APP" 2>/dev/null; then
    echo "$LOG_PREFIX signature : ok ($(codesign -dv "$APP" 2>&1 | grep -m1 'Signature' || echo 'ad-hoc'))"
else
    echo "$LOG_PREFIX signature : avertissement — signature ad-hoc impossible."
    echo "                 L'application fonctionnera, mais macOS redemandera"
    echo "                 l'autorisation Accessibilité après chaque reconstruction."
fi

# --- 5. Empreinte -----------------------------------------------------------
if command -v shasum >/dev/null 2>&1; then
    echo "$LOG_PREFIX empreinte : $(shasum -a 256 "$APP/Contents/MacOS/AutoCap" | cut -c1-16)"
fi

echo "$LOG_PREFIX VERDICT : AutoCap.app prêt dans $APP"
exit 0
AUTOCAP_EOF_11
cat > "$SCRIPTS_DIR/README.md" <<'AUTOCAP_EOF_12'
# AutoCap — capitalisation automatique pour macOS, 100 % Swift

Remplace le démon Python (`autocapitalize.py`, v20.12). Un binaire unique,
aucun interpréteur, aucune dépendance, aucune autorisation qui se perd à chaque
mise à jour.

## Installation (une seule commande, sur le Mac)

```bash
curl -fsSL -o /tmp/autocap-install.sh "https://raw.githubusercontent.com/Spymack/autocapitalize/main/swift/install.sh" && bash /tmp/autocap-install.sh
```

Le script compile, teste, refuse d'installer si un cas de conformité échoue,
désactive l'ancien démon Python, installe l'agent launchd et affiche un verdict.
Il ne reste ensuite qu'à accorder l'autorisation Accessibilité (un geste, guidé).

## Ce qui change vraiment

| Avant (Python) | Maintenant (Swift) |
|---|---|
| Le tampon local **devinait** le curseur | Le curseur est **mesuré** dans le texte de l'application (alignement avant/après édition) |
| Lectures AX en retard, figées, pré-suppression : trois familles d'heuristiques | Une seule règle : une édition est un segment qui change, l'alignement le localise |
| Curseur illisible dans Chromium → aucune règle applicable | L'alignement rend le curseur mesurable là où la plateforme ne le publie pas |
| Interpréteur dans un venv : autorisation à refaire, plantages Python | Application signée, identité stable, binaire unique |
| Exceptions avalées par `except BaseException` | Erreurs de compilation : la classe de bugs a disparu |
| Plafond mémoire, recyclage par `execv` | Pas de ramasse-miettes, pas de fuite connue ; taille résidente suivie |

## Architecture

```
Sources/
  Core/Rules.swift       décision pure : ce qui ouvre une phrase (188 cas hérités)
  Core/Align.swift       mesure du curseur dans le texte de l'application
  Core/SelfTest.swift    suite de conformité (144 cas) — tourne sans Mac
  Mac/AX.swift           Accessibility : champ focalisé, texte, curseur
  Mac/Tap.swift          CGEventTap + chien de garde
  Mac/Daemon.swift       machine à états, modèle, lectures différées, journal
  Mac/Log.swift          journal avec rotation + empreinte binaire
  Mac/Doctor.swift       --doctor, --probe
  Mac/Install.swift      LaunchAgent
  main.swift             CLI
```

Règle absolue conservée : **l'API Accessibilité n'est jamais appelée dans le
callback du tap** (gel du flux d'événements système).

## Commandes

| Commande | Effet |
|---|---|
| `--doctor` | Diagnostic complet, verdict + code de sortie (0 = prêt) |
| `--selftest` | Suite de conformité (règles, confiance, mesure du curseur) |
| `--status` | État de l'agent, plist, dernières lignes du journal |
| `--probe` | Décrit le champ focalisé de chaque application au premier plan |
| `--stats` | Échantillons mémoire et activité (un par minute) |
| `--debug` | Avec `--run` : trace complète, une ligne par événement |
| `--install` / `--uninstall` | Agent launchd |

## Journal

`~/Library/Logs/autocap.log` — rotation à 2 Mo, jamais de troncature.
Trois traces répondent à « pourquoi pas de majuscule ? » :

```
keydown observed: app=… trusted=1 tap=1
capital inserted before 'M' (reason=ender source=measured note=proved caret before='Fin. ')
target unreadable: the field exposes no caret range (role=AXTextArea, 310 char, app=…)
edit could not be measured: … (12 -> 12 char, app=…) : the caret stays unproven until the next edit
```

Chaque condition est écrite **une fois par changement**, jamais une fois par frappe.

## Désinstallation

```bash
"$HOME/Applications/AutoCap.app/Contents/MacOS/AutoCap" --uninstall --remove-permissions
```

Les sources restent dans `~/Scripts/autocap-swift` (recompilables par `build.sh`).
AUTOCAP_EOF_12


# --- 3. Vérification des sources -------------------------------------------
say "étape 3/9 — contrôle des sources"
SWIFT_COUNT=$(find "$SCRIPTS_DIR/Sources" -name '*.swift' | wc -l | tr -d ' ')
[ "$SWIFT_COUNT" -ge 10 ] || fail "sources incomplètes : $SWIFT_COUNT fichier(s) Swift au lieu de 10."
[ -f "$SCRIPTS_DIR/Resources/Info.plist" ] || fail "Resources/Info.plist manquant."
[ -f "$SCRIPTS_DIR/build.sh" ] || fail "build.sh manquant."
chmod +x "$SCRIPTS_DIR/build.sh"
say "        $SWIFT_COUNT fichiers Swift + Info.plist + build.sh"

# --- 4. Compilation ---------------------------------------------------------
say "étape 4/9 — compilation"
mkdir -p "$HOME/Applications" || fail "impossible de créer ~/Applications."
bash "$SCRIPTS_DIR/build.sh" "$APP" || fail "la compilation a échoué (sortie complète ci-dessus). Rien n'a été installé."
[ -x "$BIN" ] || fail "binaire absent après compilation : $BIN"

# --- 5. Conformité ----------------------------------------------------------
say "étape 5/9 — suite de conformité"
SELFTEST_OUT="$("$BIN" --selftest 2>&1)"
SELFTEST_STATUS=$?
echo "$SELFTEST_OUT"
[ $SELFTEST_STATUS -eq 0 ] || fail "la suite de conformité a échoué : installation refusée."
echo "$SELFTEST_OUT" | grep -q "agree with the contract" || fail "verdict de conformité inattendu."

# --- 6. Ancien démon Python -------------------------------------------------
say "étape 6/9 — ancien démon Python"
if launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null; then
    say "        $LEGACY_LABEL arrêté"
else
    say "        $LEGACY_LABEL absent (rien à arrêter)"
fi
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
if [ -f "$LEGACY_PLIST" ]; then
    mv "$LEGACY_PLIST" "$LEGACY_PLIST.disabled" && say "        plist désactivé : $LEGACY_PLIST.disabled"
fi
if pkill -f "autocapitalize.py" 2>/dev/null; then
    say "        processus autocapitalize.py arrêté"
fi

# --- 7. Agent launchd -------------------------------------------------------
say "étape 7/9 — agent launchd"
"$BIN" --install || fail "installation de l'agent impossible."

# --- 8. Diagnostic ----------------------------------------------------------
say "étape 8/9 — diagnostic"
DOCTOR_OUT="$("$BIN" --doctor 2>&1)"
DOCTOR_STATUS=$?
echo "$DOCTOR_OUT"

# --- 9. Vérification réelle -------------------------------------------------
say "étape 9/9 — vérification"
sleep 2
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    say "        agent chargé (launchctl print OK)"
else
    say "        agent NON chargé — lancer : \"$BIN\" --status"
fi
if pgrep -f "AutoCap.app/Contents/MacOS/AutoCap" >/dev/null 2>&1; then
    say "        processus en cours (pid $(pgrep -f 'AutoCap.app/Contents/MacOS/AutoCap' | head -1))"
else
    say "        processus non détecté (il attend peut-être l'autorisation)"
fi
if [ -f "$HOME/Library/Logs/autocap.log" ]; then
    say "        dernières lignes du journal :"
    tail -6 "$HOME/Library/Logs/autocap.log" 2>/dev/null | sed 's/^/[install]           /'
else
    say "        (journal pas encore créé)"
fi

echo ""
if [ $DOCTOR_STATUS -eq 0 ]; then
    echo "[install] VERDICT : PRÊT — AutoCap tourne."
else
    cat <<EOF
[install] VERDICT : ACTION REQUISE (1 geste, une seule fois)

  1. Réglages Système > Confidentialité et sécurité > Accessibilité
     cliquer « + », puis ⌘⇧G et coller :

$APP

     Activer l'interrupteur d'AutoCap.

  2. Si le journal mentionne « Input Monitoring », faire de même dans
     Confidentialité et sécurité > Surveillance de l'entrée.

  3. Puis relancer l'agent (une ligne) :

launchctl kickstart -k gui/$(id -u)/$LABEL

  4. Vérifier (une ligne) :

"$BIN" --doctor
EOF
fi

echo ""
echo "[install] commandes utiles :"
echo "    \"$BIN\" --status"
echo "    \"$BIN\" --doctor"
echo "    tail -f \"$HOME/Library/Logs/autocap.log\""
echo "    \"$BIN\" --uninstall"
