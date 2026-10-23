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
#  Version embarquée : 1.0.12
# ============================================================================
set -uo pipefail

SCRIPTS_DIR="$HOME/Scripts/autocap-swift"
APP="$HOME/Applications/AutoCap.app"
BIN="$APP/Contents/MacOS/AutoCap"
LEGACY_LABEL="com.local.autocap"
LABEL="com.aurel.autocap"

say()  { echo "[install] $*"; }
fail() { echo "[install] ERREUR : $*" >&2; echo "[install] VERDICT : ÉCHEC — rien de cassé, l'installation précédente (si elle existe) est intacte." >&2; exit 1; }

say "démarrage $(date '+%Y-%m-%d %H:%M:%S') — AutoCap 1.0.12"

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
case flag("--axdiag"):
    exit(AXDiag.run())
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
func doubleSpaceAsPeriod(_ text: String) -> String {
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

/// The caret after the application REPLACED one span with another.
///
/// A typed character over a selection is exactly that: `removed` characters
/// disappear where the caret is, `added` appear in their place. Modelling it as
/// a plain insertion is what made the old alignment refuse (the lengths did not
/// match) and drop the caret — after which the buffer, which still held the
/// replaced text, decided every following letter.
func alignReplacement(old: [Character], new: [Character], removed: Int, added: Int,
                      previousCaret: Int?) -> Alignment {
    guard removed > 0, added > 0 else {
        return .refused(reason: "a replacement needs something removed (\(removed)) "
                        + "and something added (\(added))")
    }
    guard new.count == old.count - removed + added else {
        return .refused(reason: "length mismatch: \(old.count) - \(removed) + \(added) != \(new.count)")
    }
    let highest = old.count - removed
    guard highest >= 0 else {
        return .refused(reason: "more characters removed (\(removed)) than the text holds (\(old.count))")
    }
    // The previous caret comes first: a selection starts where the caret was, so
    // the right offset is usually the one already known. The others are only
    // there to prove it is the only possibility.
    var candidates: [Int] = []
    if let previousCaret, previousCaret >= 0, previousCaret <= highest {
        candidates.append(previousCaret)
    }
    candidates.append(contentsOf: (0...highest).filter { $0 != previousCaret })
    guard candidates.count < alignmentCandidateLimit else {
        return .refused(reason: "\(candidates.count) candidate offsets: the text is too long to scan")
    }
    let outcome = settle(candidates: candidates, previousCaret: previousCaret, rebuild: { offset in
        Array(old[0..<offset]) + Array(new[offset..<(offset + added)]) + old[(offset + removed)...]
    }, new: new)
    // The caret sits at the END of what was inserted, inside the small text.
    if case .proved(let caret, let ambiguous) = outcome {
        return .proved(caret: caret + added, ambiguous: ambiguous)
    }
    return outcome ?? .refused(reason: "no offset reproduces the text: more than one edit, or a rewrite")
}

/// Does the read confirm the model EXACTLY?
///
/// The strongest agreement a read can give, and it must outrank alignment. The
/// measured case is macOS's own double-space substitution: it turns "mot  " into
/// "mot. " by moving the space AFTER the dot, so aligning "mot " → "mot. " finds
/// the one offset that reproduces the text — the dot inserted BEFORE the space —
/// and reports the caret one character early. The next letter then sees a dot
/// glued to the caret, the "token, not a sentence" guard refuses it, and the
/// user gets no capital after the period macOS just inserted.
///
/// When the model already predicts the published text, there is nothing to
/// align: the model's caret sits inside a text the application itself confirms.
func readConfirmsModel(modelText: [Character]?, readText: [Character]) -> Bool {
    guard let modelText else { return false }
    return modelText == readText
}

/// The text before the caret, from the LOCAL buffer.
///
/// The buffer holds everything typed since it was last anchored, and it ends at
/// the caret. A selection starts at the caret, so its start is also the length of
/// what precedes it: once the application publishes that start, the tail of the
/// buffer is not "before the caret" any more — it is the text about to be
/// replaced. Ignoring that is what kept the capital off the first letter typed
/// over a selection in a field whose text is unreadable: the buffer still held
/// the old word, so the engine saw "another word before the caret" where there
/// is nothing at all.
func bufferBeforeCaret(_ buffer: String, selectionStart: Int?) -> String {
    guard let selectionStart, selectionStart >= 0, selectionStart < buffer.count else {
        return buffer
    }
    return String(buffer.prefix(selectionStart))
}

/// The text before the caret, from a text and a measured caret offset.
func textBeforeCaret(_ text: [Character], caret: Int) -> String {
    guard caret > 0 else { return "" }
    return String(text[0..<min(caret, text.count)])
}

// MARK: - Which source decides the caret

/// Where a read's caret should come from.
enum CaretSource: String {
    case platform
    case alignment
    case keep
}

/// Decide the caret's provenance for one read.
///
/// AFTER AN EDIT, THE TEXT IS THE AUTHORITY. An application may answer a read
/// that arrives before it applied the edit, and it may report the caret it held
/// BEFORE the edit: TickTick's quick-add window did exactly that, keeping the
/// caret at 0 while the text grew, so every apostrophe was followed by a capital
/// ("J'Ai eu L'iDée"). Alignment measures the caret inside the text the
/// application actually published, which cannot be stale.
///
/// AN IDLE READ NEVER OVERRIDES A KNOWN CARET. When the text has not changed and
/// the model already holds a position — proved by alignment, then advanced by the
/// tap's own keystrokes — a disagreeing caret from the application is its stale
/// answer, not news. That is what made "J'ai. keidkfefdf" keep a lowercase "k":
/// the application answered a caret one character behind, the model believed it,
/// and the dot looked glued to the caret.
///
/// The platform's caret therefore serves two cases only: a first read (no model
/// caret yet) and an externally modified text.
func preferredCaretSource(hasPendingEdit: Bool, platformCaretAvailable: Bool,
                          textUnchanged: Bool, modelCaretKnown: Bool) -> CaretSource {
    if hasPendingEdit { return .alignment }
    if textUnchanged, modelCaretKnown { return .keep }
    return platformCaretAvailable ? .platform : .keep
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
    reportedBugs(runner)

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
    runner.equal("double space period", doubleSpaceAsPeriod("mot  "), "mot. ")
    // The reported bug: "type a word, two spaces, then a letter" gave no capital,
    // because the model kept two spaces where macOS had inserted a period.
    runner.expect("the double-space substitution opens the next sentence",
                  shouldCapitalize(doubleSpaceAsPeriod("mot  ")) == true)
    runner.expect("two spaces alone do not open a sentence",
                  shouldCapitalize("mot  ") == false)
    runner.equal("double space after closer", doubleSpaceAsPeriod("(fin)  "), "(fin). ")
    runner.equal("double space after three spaces", doubleSpaceAsPeriod("mot   "), "mot   ")
    runner.equal("double space after a period", doubleSpaceAsPeriod("fin.  "), "fin.  ")
    runner.equal("double space single space", doubleSpaceAsPeriod("mot "), "mot ")
    runner.equal("double space empty", doubleSpaceAsPeriod(""), "")
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

    // --- reported bug: TickTick's quick-add window ---
    // The application kept answering "caret 0" while the text grew, so every
    // apostrophe was followed by a capital ("J'Ai eu L'iDée"). A stale platform
    // caret must not be able to drag the measured caret back to 0.
    var model: [Character] = []
    var caretProbe = 0
    for character in "l'idée" {
        let previous = model
        model.append(character)
        if let measured = alignInsertion(old: previous, new: model, added: 1,
                                         previousCaret: caretProbe).caret {
            caretProbe = measured
        }
    }
    runner.equal("a stale platform caret cannot drag the measured caret to 0", caretProbe, 6)
    runner.expect("an apostrophe never opens a sentence",
                  resolveCapitalization("l'", axTrusted: true, sawLineBreak: false,
                                        synthetic: false) == false)
    runner.expect("an elision never opens a sentence",
                  resolveCapitalization("j'ai eu l'", axTrusted: true, sawLineBreak: false,
                                        synthetic: false) == false)

    // --- where the caret comes from ---
    runner.expect("after an edit the text decides, not the platform caret",
                  preferredCaretSource(hasPendingEdit: true, platformCaretAvailable: true,
                                       textUnchanged: false, modelCaretKnown: true) == .alignment)
    runner.expect("after an edit without a platform caret, alignment still decides",
                  preferredCaretSource(hasPendingEdit: true, platformCaretAvailable: false,
                                       textUnchanged: false, modelCaretKnown: false) == .alignment)
    runner.expect("a first read uses the platform caret",
                  preferredCaretSource(hasPendingEdit: false, platformCaretAvailable: true,
                                       textUnchanged: false, modelCaretKnown: false) == .platform)
    runner.expect("an idle read with unchanged text never overrides a known caret",
                  preferredCaretSource(hasPendingEdit: false, platformCaretAvailable: true,
                                       textUnchanged: true, modelCaretKnown: true) == .keep)
    runner.expect("an idle read with no model caret adopts the platform's",
                  preferredCaretSource(hasPendingEdit: false, platformCaretAvailable: true,
                                       textUnchanged: true, modelCaretKnown: false) == .platform)
    runner.expect("an idle read without a caret changes nothing",
                  preferredCaretSource(hasPendingEdit: false, platformCaretAvailable: false,
                                       textUnchanged: false, modelCaretKnown: true) == .keep)

    // --- reported bug: "J'ai. keidkfefdf" (a caret one character behind) ---
    // With the REAL text, the sentence end opens a capital...
    runner.expect("a sentence end followed by a space opens the next sentence",
                  resolveCapitalization("j'ai. ", axTrusted: true, sawLineBreak: false,
                                        synthetic: false) == true)
    // ...and with a caret one character behind, the dot looks glued and the
    // capital is refused. That is why the stale caret must never be adopted.
    runner.expect("a caret one character behind would glue the dot (the bug)",
                  resolveCapitalization(textBeforeCaret(Array("j'ai. "), caret: 5),
                                        axTrusted: true, sawLineBreak: false,
                                        synthetic: false) == false)
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

// MARK: - 7. The two reported bugs

/// The two failures reported on v1.0.8, each reproduced before being fixed.
///
/// Both are composition bugs: the rule table was right, the measurement was
/// right, and the two together produced a lowercase where a capital was owed.
private func reportedBugs(_ runner: CaseRunner) {
    // --- "no capital after the period macOS inserts on a double space" ---
    //
    // macOS turns "mot  " into "mot. " by moving the space AFTER the dot. The
    // tap models the substitution, so its text is exact — but the read that
    // follows used to reconcile by ALIGNMENT, and the only offset that reproduces
    // "mot. " from "mot " is the dot inserted BEFORE the space. The caret came
    // back one character early, the next letter saw a dot glued to it, and the
    // "token, not a sentence" guard refused the capital.
    runner.equal("aligning the substitution alone puts the caret before the space (the trap)",
                 alignInsertion(old: Array("mot "), new: Array("mot. "), added: 1,
                                previousCaret: 5).caret, 4)
    runner.expect("the substituted text does open a sentence",
                  capitalizeReason("mot. ") == .ender)
    runner.expect("a read that repeats the model confirms it",
                  readConfirmsModel(modelText: Array("mot. "), readText: Array("mot. ")))
    runner.expect("a read that differs never confirms the model",
                  readConfirmsModel(modelText: Array("mot  "), readText: Array("mot. ")) == false)
    runner.expect("no model text confirms nothing",
                  readConfirmsModel(modelText: nil, readText: Array("mot. ")) == false)
    // The whole pipeline, in both worlds: v1.0.8 stopped at "Mot. suite".
    runner.equal("v1.0.8: the letter after the inserted period stays lowercase",
                 simulateSubstitutedTyping("mot  suite", confirmModel: false), "Mot. suite")
    runner.equal("the letter after the inserted period opens a sentence",
                 simulateSubstitutedTyping("mot  suite", confirmModel: true), "Mot. Suite")

    // --- "I select the text I typed, typing replaces it, and it gives a lowercase" ---
    //
    // The field is read, the whole text is selected (Cmd-A, or a selection that
    // covers everything), so the insert point is offset 0. That is a READ fact,
    // not the left edge of a buffer that was just emptied — which is why the
    // buffer alone refused to believe it.
    runner.expect("nothing before the caret is a start", capitalizeReason("") == .start)
    runner.equal("a selection starting at offset 0 leaves nothing before the caret",
                 textBeforeCaret(Array("Bonjour"), caret: 0), "")
    runner.expect("a proven offset 0 opens the field even with an empty buffer",
                  canTrustLineStart(axTrusted: false, sawLineBreak: false, synthetic: true,
                                    anchored: false, proven: true))
    runner.expect("an unproven offset 0 still does not",
                  canTrustLineStart(axTrusted: false, sawLineBreak: false, synthetic: true,
                                    anchored: false, proven: false) == false)
    // The replacement itself is measurable, so the caret is not lost after it.
    runner.equal("typing over the whole selection is measured",
                 alignReplacement(old: Array("Bonjour"), new: Array("s"), removed: 7, added: 1,
                                  previousCaret: 0).caret, 1)
    runner.equal("a partial selection replacement is measured",
                 alignReplacement(old: Array("le chat noir"), new: Array("le chien noir"),
                                  removed: 4, added: 5, previousCaret: 3).caret, 8)
    runner.equal("a replacement of the wrong length is refused",
                 alignReplacement(old: Array("Bonjour"), new: Array("s"), removed: 6, added: 1,
                                  previousCaret: 0).caret, nil)
    runner.equal("a replacement with nothing removed is refused",
                 alignReplacement(old: Array("Bonjour"), new: Array("Bonjour s"), removed: 0,
                                  added: 2, previousCaret: 7).caret, nil)

    // ...and in a field whose text is UNREADABLE, where the local buffer decides.
    // The buffer ends at the caret, so a selection starting at the caret means its
    // tail is not "before the caret" any more: keeping it made the engine see the
    // old word it was about to replace, and refuse the capital.
    runner.equal("the buffer keeps only what precedes the selection",
                 bufferBeforeCaret("Bonjour", selectionStart: 0), "")
    runner.equal("a selection further in keeps the text before it",
                 bufferBeforeCaret("Bonjour le monde", selectionStart: 7), "Bonjour")
    runner.expect("a selection at offset 0 makes the buffer empty, so it is a start",
                  capitalizeReason(bufferBeforeCaret("Bonjour", selectionStart: 0)) == .start)
    runner.expect("without the selection start, the old word still blocks the capital (the bug)",
                  capitalizeReason(bufferBeforeCaret("Bonjour", selectionStart: nil)) == nil)
    runner.expect("and that empty buffer is trusted when the selection starts at 0",
                  canTrustLineStart(axTrusted: false, sawLineBreak: false, synthetic: true,
                                    anchored: true))
    runner.expect("a selection starting at 39 never empties the buffer",
                  bufferBeforeCaret("Fdsfdfds\nPlop. Mplpop. Fdfdf\n-Fdfsfsdf\n", selectionStart: 39)
                  == "Fdsfdfds\nPlop. Mplpop. Fdfdf\n-Fdfsfsdf\n")
}

/// The daemon's pipeline for one typed character, with no Mac: decide from the
/// model, advance the model, apply macOS's substitution, then reconcile with the
/// text the application publishes.
///
/// `confirmModel` picks the rule under test: false reconciles every read by
/// alignment (v1.0.8 and before, which misplaces the caret after the double-space
/// substitution), true keeps the model's caret when the read confirms its text.
private func simulateSubstitutedTyping(_ input: String, confirmModel: Bool) -> String {
    var model: [Character] = []      // what the daemon believes the field holds
    var caret: Int? = 0              // what the daemon believes the caret is
    var appText: [Character] = []    // what the application really holds
    var appCaret = 0                 // where the application really put the caret
    for character in input {
        // 1. The decision, from the text before the caret in the model.
        let before = caret.map { textBeforeCaret(model, caret: $0) } ?? ""
        let capitalize = character.isLetter && capitalizeReason(before, typedGlued: true) != nil
        let emitted: Character = capitalize ? Character(String(character.uppercased())) : character

        // 2. The application inserts it at ITS caret, then applies macOS's own
        //    "add period with double-space".
        if appCaret > appText.count { appCaret = appText.count }
        appText.insert(emitted, at: appCaret)
        appCaret += 1
        if emitted == " " {
            let upToCaret = String(appText[0..<appCaret])
            let substituted = doubleSpaceAsPeriod(upToCaret)
            if substituted != upToCaret {
                appText = Array(substituted) + Array(appText[appCaret...])
                appCaret = substituted.count
            }
        }

        // 3. The daemon advances its own model the same way (appendToModels).
        let previousModel = model
        let previousCaret = caret
        if let position = caret {
            model.insert(emitted, at: position)
            caret = position + 1
        }
        if emitted == " " {
            let upToCaret = String(model[0..<(caret ?? 0)])
            let substituted = doubleSpaceAsPeriod(upToCaret)
            if substituted != upToCaret {
                model = Array(substituted) + Array(model[(caret ?? 0)...])
                caret = substituted.count
            }
        }

        // 4. The read: the application publishes appText.
        if confirmModel, readConfirmsModel(modelText: model, readText: appText) {
            continue
        }
        if let measured = alignInsertion(old: previousModel, new: appText, added: 1,
                                         previousCaret: previousCaret).caret {
            caret = measured
        } else {
            caret = nil
        }
        model = appText
    }
    return String(appText)
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
//  THREE ROUTES, ALWAYS NAMED. The system-wide element is the documented way to
//  ask "what has the focus"; on some systems it answers nothing while the
//  application's own element answers fine. The read therefore tries the
//  system-wide element, then the frontmost application's element, then that
//  application's focused window — and it reports WHICH route answered, and, when
//  all of them fail, the AXError of each. "No focused element" without a code is
//  a dead end; a code names the fault.
//
//  Attribute names are written as string literals ("AXValue", …) rather than
//  through the imported constants: the names are ABI-stable and a literal cannot
//  fail to compile on a different toolchain.
//
//  NOTHING here is called from inside the event tap: a synchronous Accessibility
//  read in a tap callback stalls the whole system event stream. The caller
//  (Daemon.scheduleRead) enforces that.
//

import Cocoa
import ApplicationServices

/// What the focused field said, once, at one instant.
struct FieldSnapshot {
    let role: String
    let subrole: String?
    let text: String?
    let caret: Int?
    /// How many characters are selected, when the field publishes it.
    ///
    /// 0 means "nothing is selected" — a fact. nil means "cannot tell", which
    /// must never be read as "nothing": a typed character then replaces an
    /// unknown span instead of appending, and conflating the two is what left a
    /// lowercase letter where the field had just been replaced from its start.
    let selection: Int?
    let length: Int?
    let bundleID: String?
    let route: String

    /// Human-readable one-liner for --probe, --doctor and the journal.
    var summary: String {
        let textPart = text.map { "text=\($0.count) char" } ?? "text=unreadable"
        let caretPart = caret.map { "caret=\($0)" } ?? "caret=unreadable"
        let selectionPart = selection.map { "selection=\($0)" } ?? "selection=unreadable"
        return "role=\(role) subrole=\(subrole ?? "-") \(textPart) \(caretPart) "
            + "\(selectionPart) via \(route)"
    }
}

/// One read: a snapshot, or a reason that carries its codes.
struct AXReadResult {
    let snapshot: FieldSnapshot?
    let failure: String?

    static func failed(_ reason: String) -> AXReadResult {
        AXReadResult(snapshot: nil, failure: reason)
    }
}

/// Name and numeric code of an AXError: a diagnosis, not a shrug.
func axErrorName(_ error: AXError) -> String {
    let name: String
    switch error {
    case .success: name = "success"
    case .failure: name = "failure"
    case .illegalArgument: name = "illegalArgument"
    case .invalidUIElement: name = "invalidUIElement"
    case .invalidUIElementObserver: name = "invalidUIElementObserver"
    case .cannotComplete: name = "cannotComplete"
    case .attributeUnsupported: name = "attributeUnsupported"
    case .actionUnsupported: name = "actionUnsupported"
    case .notificationUnsupported: name = "notificationUnsupported"
    case .notImplemented: name = "notImplemented"
    case .notificationAlreadyRegistered: name = "notificationAlreadyRegistered"
    case .notificationNotRegistered: name = "notificationNotRegistered"
    case .apiDisabled: name = "apiDisabled"
    case .noValue: name = "noValue"
    case .parameterizedAttributeUnsupported: name = "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: name = "notEnoughPrecision"
    @unknown default: name = "unknown"
    }
    return "\(name)(\(error.rawValue))"
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

/// Roles that HOLD the focus instead of being the field: browsers and Electron
/// apps answer AXWebArea for the page, and the real input is its focused child.
let containerRoles: Set<String> = ["AXWebArea", "AXScrollArea", "AXGroup"]

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

    /// Read one attribute, keeping the error instead of throwing it away.
    static func attribute(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error == .success ? value : nil, error)
    }

    static func string(_ element: AXUIElement, _ name: String) -> (value: String?, error: AXError) {
        let result = attribute(element, name)
        return (result.value as? String, result.error)
    }

    static func integer(_ element: AXUIElement, _ name: String) -> Int? {
        (attribute(element, name).value as? NSNumber)?.intValue
    }

    /// Find the focused element, trying every documented route.
    ///
    /// Returns the element, the route that answered, and — when nothing answers
    /// — a description carrying each route's error code.
    static func focusedElement() -> (element: AXUIElement?, route: String, error: String?) {
        var trail: [String] = []

        // Route 1: the system-wide element.
        let system = AXUIElementCreateSystemWide()
        let systemResult = attribute(system, "AXFocusedUIElement")
        if let raw = systemResult.value {
            return (unsafeBitCast(raw, to: AXUIElement.self), "system-wide", nil)
        }
        trail.append("system-wide=\(axErrorName(systemResult.error))")

        guard let pid = frontmostPID() else {
            trail.append("frontmost application=unknown")
            return (nil, "none", trail.joined(separator: " "))
        }

        // Route 2: the frontmost application's own element.
        let application = AXUIElementCreateApplication(pid)
        let appResult = attribute(application, "AXFocusedUIElement")
        if let raw = appResult.value {
            return (unsafeBitCast(raw, to: AXUIElement.self), "application(pid \(pid))", nil)
        }
        trail.append("application(pid \(pid))=\(axErrorName(appResult.error))")

        // Route 3: the application's focused window, then its focused element.
        let windowResult = attribute(application, "AXFocusedWindow")
        if let windowRaw = windowResult.value {
            let window = unsafeBitCast(windowRaw, to: AXUIElement.self)
            let inner = attribute(window, "AXFocusedUIElement")
            if let raw = inner.value {
                return (unsafeBitCast(raw, to: AXUIElement.self), "window(pid \(pid))", nil)
            }
            trail.append("window(pid \(pid))=\(axErrorName(inner.error))")
        } else {
            trail.append("AXFocusedWindow=\(axErrorName(windowResult.error))")
        }

        return (nil, "none", trail.joined(separator: " "))
    }

    /// The selected range, when the platform publishes one.
    ///
    /// Its LOCATION is the insert point — a selection starts where the caret is —
    /// and its LENGTH is what a typed character is about to replace.
    static func selectedRange(_ element: AXUIElement) -> CFRange? {
        let result = attribute(element, "AXSelectedTextRange")
        guard let raw = result.value else { return nil }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        var range = CFRange()
        let ok = withUnsafeMutablePointer(to: &range) { pointer -> Bool in
            AXValueGetValue(value, .cfRange, pointer)
        }
        return ok ? range : nil
    }

    /// The insertion point, when the platform publishes one.
    ///
    /// Chromium does not, in its contenteditable fields: that is not a bug to
    /// work around here, it is the reason Align.swift exists.
    static func caretOffset(_ element: AXUIElement) -> Int? {
        // A negative offset is the platform's way of saying "no range"; anything
        // else is a real offset and is bounded by the caller.
        guard let range = selectedRange(element), range.location >= 0 else { return nil }
        return range.location
    }

    /// How many characters are selected, when the field publishes it.
    ///
    /// Two sources, in order: the range's own length, then AXSelectedText — some
    /// applications publish the selected TEXT without its range. nil when
    /// neither answers, which is not the same fact as 0.
    static func selectionLength(_ element: AXUIElement) -> Int? {
        if let range = selectedRange(element) { return max(0, range.length) }
        if let selected = string(element, "AXSelectedText").value { return selected.count }
        return nil
    }

    /// Walk up from an element to the nearest editable text field.
    static func editableAncestor(_ element: AXUIElement, depth: Int = 4) -> (AXUIElement, String)? {
        var current = element
        var level = 0
        while level <= depth {
            let role = string(current, "AXRole").value
            if isEditableTarget(role: role, subrole: string(current, "AXSubrole").value) {
                return (current, "ancestor \(level)")
            }
            guard let parent = attribute(current, "AXParent").value else { return nil }
            current = unsafeBitCast(parent, to: AXUIElement.self)
            level += 1
        }
        return nil
    }

    /// The editable field UNDER THE POINTER.
    ///
    /// The focused element is not always the field: clicking into a page can leave
    /// the focus on a toolbar button (measured in Zen: role=AXButton right after
    /// the click), and the system-wide route sometimes times out on a busy
    /// application (cannotComplete −25204). The pointer knows where the user
    /// clicked, so the element under it is asked instead, then its ancestors.
    /// Only used when no route found an editable field — the alternative is
    /// reading nothing at all, which is how a selection stopped being seen.
    static func elementUnderPointer(_ point: CGPoint) -> (AXUIElement, String)? {
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                     Float(point.x), Float(point.y), &element)
        guard error == .success, let element else { return nil }
        return editableAncestor(element)
    }

    /// Read the focused field, or say exactly why there is nothing to read.
    ///
    /// `pointer` is the location of the last click, in AX (top-left) coordinates:
    /// the last resort when no route finds an editable element.
    static func readField(pointer: CGPoint? = nil) -> AXReadResult {
        let focused = readFocusedField()
        if focused.snapshot != nil { return focused }
        if let pointer, let under = elementUnderPointer(pointer) {
            return read(element: under.0, route: "pointer(\(Int(pointer.x)),\(Int(pointer.y))) > \(under.1)")
        }
        return focused
    }

    private static func readFocusedField() -> AXReadResult {
        let focused = focusedElement()
        guard var element = focused.element else {
            return .failed("no focused element after every route [\(focused.error ?? "no detail")]")
        }
        var route = focused.route

        // An application may answer with the CONTAINER that holds the focus
        // instead of the field itself: Chromium (and therefore every browser and
        // Electron app) returns AXWebArea, whose own focused child is the real
        // input. Asking that container for its focused element is the difference
        // between measuring the caret and falling back to a blind buffer.
        var role = string(element, "AXRole")
        var depth = 0
        while let name = role.value, containerRoles.contains(name), depth < 3 {
            guard let inner = attribute(element, "AXFocusedUIElement").value else { break }
            let child = unsafeBitCast(inner, to: AXUIElement.self)
            let childRole = string(child, "AXRole")
            guard let childName = childRole.value, childName != name else { break }
            element = child
            role = childRole
            route += " > \(childName)"
            depth += 1
        }

        return read(element: element, route: route)
    }

    /// Snapshot ONE element, or say exactly why it cannot be read.
    private static func read(element: AXUIElement, route: String) -> AXReadResult {
        let role = string(element, "AXRole")
        let subrole = string(element, "AXSubrole")

        guard isEditableTarget(role: role.value, subrole: subrole.value) else {
            if let subroleName = subrole.value, excludedSubroles.contains(subroleName) {
                return .failed("excluded field (subrole=\(subroleName), role=\(role.value ?? "-"))")
            }
            return .failed("not an editable text field (role=\(role.value ?? "-"), "
                           + "subrole=\(subrole.value ?? "-"), via \(route))")
        }

        let text = string(element, "AXValue")
        let caret = caretOffset(element)
        let selection = selectionLength(element)
        let length = integer(element, "AXNumberOfCharacters")

        if text.value == nil && caret == nil {
            return .failed("the field exposes neither text nor caret "
                           + "(role=\(role.value ?? "-"), AXValue=\(axErrorName(text.error)), "
                           + "via \(route))")
        }

        let snapshot = FieldSnapshot(role: role.value ?? "?", subrole: subrole.value,
                                     text: text.value, caret: caret, selection: selection,
                                     length: length ?? text.value?.count,
                                     bundleID: frontmostBundle(), route: route)
        return AXReadResult(snapshot: snapshot, failure: nil)
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
    /// A typed character over a selection: `removed` characters disappear where
    /// the caret is, `added` appear in their place.
    case replacement(removed: Int, added: Int)

    var label: String {
        switch self {
        case .insertion(let count): return "insertion of \(count)"
        case .deletion(let count): return "deletion of \(count)"
        case .replacement(let removed, let added): return "replacement of \(removed) by \(added)"
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
    static let version = "1.0.12"

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
    /// A period substitution the tap has modelled but the application has not
    /// confirmed yet ("mot  " -> "mot. "). A read that still shows two spaces is
    /// an answer from before the substitution, not a refutation.
    private var pendingSubstitution = false
    /// The selection the next typed character will overwrite, as last read — or
    /// as a shortcut proves it. `start` is where the selection begins, which is
    /// also where the caret is; both are nil when nothing is selected.
    private var selectionStart: Int?
    private var selectionLength: Int?
    private var expectation: Expectation?
    private var readRetries = 0
    /// Extra reads allowed after a POINTER event, while the target is still
    /// unreadable. A click into a text area sometimes answers with the wrong
    /// focused element for a few hundred milliseconds (measured in Zen:
    /// "role=AXButton" right after the click, then the real field) — and a click is
    /// exactly the gesture that makes a selection, so giving up at the first
    /// answer means never learning that selection exists.
    private var pointerReadRetries = 0
    /// Until when the mouse position may be used to FIND the field.
    private var pointerFreshUntil = Date.distantPast
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

    /// The mouse position in AX coordinates (origin top-left), for a moment after
    /// a click — nil otherwise, so a stale position never points at another field.
    private func pointerInAXCoordinates() -> CGPoint? {
        guard Date() < pointerFreshUntil, let screen = NSScreen.screens.first else { return nil }
        let location = NSEvent.mouseLocation
        return CGPoint(x: location.x, y: screen.frame.maxY - location.y)
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
        // A click also collapses or replaces the selection. The read that follows
        // in 60 ms reports the new one, if the application publishes it.
        clearSelection()
        pointerReadRetries = 3
        // The pointer is only trusted for a moment after a click: a stale position
        // could name a field the user is not typing in.
        pointerFreshUntil = Date().addingTimeInterval(2.0)
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
            case keyCodeA:
                // SELECT-ALL: two keyboard-known facts, nothing guessed. The
                // insert point is offset 0 and the whole field is selected, so a
                // typed letter replaces everything and opens the field. This is
                // the reported "I select the text I typed, the typing replaces
                // it, and the first letter comes out lowercase": the buffer had
                // just been emptied, so its left edge proved nothing.
                let selectedLength = fieldText?.count ?? 0
                measuredCaret = 0
                caretProven = true
                selectionStart = 0
                selectionLength = selectedLength > 0 ? selectedLength : nil
                shadow = ""
                anchored = false
                typedGlued = false
                trust = .confirmed
                expectation = nil
                pendingOldText = nil
                Log.shared.debug("Command-A -> \(selectedLength) char selected from offset 0, "
                                 + "the next letter opens the field")
                scheduleRead(after: 0.12, expectation: nil)
                return nil
            case keyCodeX, keyCodeV, keyCodeZ, keyCodeY:
                let name = shortcutName(keycode)
                Log.shared.debug("\(name) -> caret unknown, buffer trust unknown")
                if keycode == keyCodeX { expectation = .deletion(1) }
                clearSelection()
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
            // Delete over a SELECTION removes the selection and nothing else: the
            // character before it stays, and the caret does not move. Modelling it
            // as a one-character deletion ate a character that is still there.
            let overwritten = pendingSelection()
            clearSelection()
            let replacedCharacters = overwritten?.removed ?? 0
            if replacedCharacters > 0 {
                advanceModel(replacing: replacedCharacters, with: "")
                anchored = false
                typedGlued = false
                Log.shared.debug("Delete over a selection -> \(replacedCharacters) char removed "
                                 + "at the caret, nothing before it")
                scheduleRead(after: 0.012, expectation: .deletion(replacedCharacters))
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
            let overwritten = pendingSelection()
            clearSelection()
            appendToModels(typed, replacing: overwritten)
            if typed == " " { applyPeriodSubstitutionIfNeeded() }
            let expectationAfter = expectationFor(added: typed.count,
                                                  replacing: overwritten?.removed ?? 0)
            expectation = expectationAfter
            scheduleRead(after: 0.012, expectation: expectationAfter)
            return nil
        }

        let decision = decide()
        // The decision needs the selection (its start is the caret); the model
        // needs its length. Consume it only once the verdict is made.
        let overwritten = pendingSelection()
        clearSelection()
        if decision.capitalize, let upper = uppercaseSingle(character) {
            setUnicodeString(event, String(upper))
            capitals += 1
            appendToModels(String(upper), replacing: overwritten)
            Log.shared.notice("capital inserted before '\(upper)' "
                              + "(reason=\(decision.reason?.rawValue ?? "-") source=\(decision.source) "
                              + "note=\(decision.note) before=\(quoted(decision.beforeCaret)) app=\(bundleID ?? "-"))")
            if decision.source == "buffer" {
                Log.shared.condition("capitalFromBuffer", bundleID ?? "-",
                                     "capital decided from the local buffer in \(bundleID ?? "unknown app") "
                                     + "— the field text is unreadable here")
            }
        } else {
            appendToModels(typed, replacing: overwritten)
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
                // NOTHING FIRED — this used to be a --debug line only, so a missing
                // capital left NO trace in the journal: the reported "sometimes it
                // works, sometimes not" was unreadable. It is now a permanent line,
                // deduplicated on a COARSE state (caret: none/0/set, selection:
                // none/0/set) so a word typed mid-sentence prints it once, never
                // once per letter — the v20.7 lesson.
                let caretKind = measuredCaret.map { $0 == 0 ? "0" : "set" } ?? "none"
                let selectionKind = selectionStart.map { $0 == 0 ? "0" : "set" } ?? "none"
                Log.shared.condition("noCapital",
                                     "\(bundleID ?? "-")|\(decision.source)|\(caretKind)|\(selectionKind)",
                                     "no capital before '\(character)' — no rule matched "
                                     + "(source=\(decision.source) before=\(quoted(decision.beforeCaret)) "
                                     + "trust=\(trust.rawValue) caret=\(caretKind) "
                                     + "selectionStart=\(selectionKind) app=\(bundleID ?? "-"))")
            }
        }
        expectation = expectationFor(added: 1, replacing: overwritten?.removed ?? 0)
        scheduleRead(after: 0.012, expectation: expectation)
        return nil
    }

    // MARK: - The decision

    private func decide() -> Decision {
        // 1. Measured caret: the application's own text, at an offset proved (or
        //    estimated) by alignment. No trust question remains — this is a read.
        //    A selection START is the same kind of fact: the application published
        //    a range that begins there, so the text before the caret is readable
        //    even in a field that publishes no insertion point.
        let caretForDecision = measuredCaret ?? selectionStart
        if let text = fieldText, let caret = caretForDecision, caret >= 0, caret <= text.count {
            let before = textBeforeCaret(text, caret: caret)
            let reason = capitalizeReason(before, typedGlued: typedGlued)
            guard let reason else {
                return Decision(capitalize: false, reason: nil, source: "measured",
                                beforeCaret: before, note: "no rule matches the measured text")
            }
            let note = measuredCaret != nil
                ? (caretProven ? "proved caret" : "estimated caret")
                : "selection start at \(caret) (no readable caret)"
            return Decision(capitalize: true, reason: reason, source: "measured",
                            beforeCaret: before, note: note)
        }

        // 2. Local buffer, with an explicit trust level. The buffer ends at the
        //    caret, and a selection starts there: what follows that start is not
        //    "before the caret", it is what the next letter replaces.
        let bufferText = bufferBeforeCaret(shadow, selectionStart: selectionStart)
        let reason = capitalizeReason(bufferText, typedGlued: typedGlued)
        guard let reason else {
            return Decision(capitalize: false, reason: nil, source: "buffer",
                            beforeCaret: bufferText, note: "no rule matches the buffer")
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
            // A selection starting at offset 0 is the third keyboard-known left
            // edge: everything before the caret is selected (Cmd-A) or the
            // selection itself begins at 0, and a typed letter then opens the
            // field even though the buffer was just emptied.
            let trusted = canTrustLineStart(axTrusted: known, sawLineBreak: sawReturn,
                                            synthetic: trust == .unknown,
                                            anchored: anchored || selectionStart == 0)
            if !trusted {
                return Decision(capitalize: false, reason: reason, source: "buffer",
                                beforeCaret: bufferText,
                                note: "start of text not provable here (trust=\(trust.rawValue), "
                                      + "anchored=\(anchored), selectionStart=\(selectionStart.map(String.init) ?? "-"))")
            }
        } else if !(known || reliable) {
            return Decision(capitalize: false, reason: reason, source: "buffer",
                            beforeCaret: bufferText,
                            note: "buffer trust is \(trust.rawValue): type once to restore it")
        }
        return Decision(capitalize: true, reason: reason, source: "buffer",
                        beforeCaret: bufferText,
                        note: "buffer verdict, trust=\(trust.rawValue), "
                              + "selectionStart=\(selectionStart.map(String.init) ?? "-")")
    }

    // MARK: - Advancing the model between reads

    /// The selection the next typed character will overwrite, read without
    /// consuming it — the decision needs its start, the model needs its length.
    private func pendingSelection() -> (start: Int, removed: Int)? {
        guard let start = selectionStart else { return nil }
        return (start, max(0, selectionLength ?? 0))
    }

    private func clearSelection() {
        selectionStart = nil
        selectionLength = nil
    }

    private func expectationFor(added: Int, replacing removed: Int) -> Expectation {
        removed > 0 ? .replacement(removed: removed, added: added) : .insertion(added)
    }

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

    /// Same, for a typed character that REPLACES a selection.
    ///
    /// The selection's length comes from the application, so the model can
    /// predict the exact resulting text. Without it the model would grow by one
    /// character where the application lost N, every read would refuse to align,
    /// and the buffer — still holding the replaced text — would then decide that
    /// there is "another word" before the caret that is no longer there.
    private func advanceModel(replacing removed: Int, with text: String) {
        guard removed > 0, let current = fieldText, let caret = measuredCaret,
              caret >= 0, caret <= current.count, caret + removed <= current.count else {
            measuredCaret = nil
            caretProven = false
            return
        }
        pendingOldText = current
        var updated = current
        updated.removeSubrange(caret..<(caret + removed))
        updated.insert(contentsOf: Array(text), at: caret)
        fieldText = updated
        measuredCaret = caret + text.count
        caretProven = false
    }

    private func appendToModels(_ text: String, replacing selection: (start: Int, removed: Int)? = nil) {
        if let selection, selection.start >= 0, selection.start < shadow.count {
            // The buffer ends at the caret, and the caret is the selection start:
            // everything from there on is what this character replaces, so it must
            // not stay in the buffer and be read as "a word before the caret".
            shadow = String(shadow.prefix(selection.start))
        }
        shadow.append(text)
        if shadow.count > 512 { shadow = String(shadow.suffix(512)) }
        anchored = false
        typedGlued = true
        // New typing supersedes any substitution still waiting to be confirmed.
        pendingSubstitution = false
        // Typing restores a usable buffer: the characters the tap itself produced
        // are real even when the field cannot be read through Accessibility. Only
        // .start keeps needing a confirmed left edge (see decide()).
        if trust == .unknown { trust = .keyboardOnly }
        if let selection, selection.removed > 0 {
            advanceModel(replacing: selection.removed, with: text)
        } else {
            advanceModel(inserting: text)
        }
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

        var substituted = false
        if let text = fieldText, let caret = measuredCaret, caret > 0, caret <= text.count {
            let before = String(text[0..<caret])
            let prefix = doubleSpaceAsPeriod(before)
            if prefix != before {
                fieldText = Array(prefix) + Array(text[caret...])
                substituted = true
            }
        }

        let tail = doubleSpaceAsPeriod(shadow)
        if tail != shadow {
            shadow = tail
            substituted = true
            Log.shared.debug("double space modelled as a period -> buffer now \(quoted(shadow))")
        }
        // The substitution is a PREDICTION about the application, and the next
        // read has to be judged against it (see applyRead): an application that
        // publishes late answers "mot  " for a moment.
        if substituted { pendingSubstitution = true }
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
        case .replacement(let removed, let added):
            return newCount == old.count - removed + added
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
        // The pointer, in AX coordinates: the last resort for finding the field
        // when every focus route fails — measured in Zen, where a click can leave
        // the focus on a toolbar button (role=AXButton) or where a busy app answers
        // cannotComplete (−25204). Computed here, on the main thread.
        let pointer = pointerInAXCoordinates()
        readQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            let result = AX.readField(pointer: pointer)
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
            // A click is how a selection is made, and the first answer after one
            // can name the wrong element. Ask again before concluding that the
            // target is unreadable: a selection we never see is a capital we never
            // place.
            if pointerReadRetries > 0 {
                pointerReadRetries -= 1
                let delay = [0.10, 0.20, 0.40][min(2 - pointerReadRetries, 2)]
                Log.shared.debug("target still unreadable after a pointer event (\(failure)) "
                                 + "-> retry in \(Int(delay * 1000)) ms "
                                 + "(\(pointerReadRetries) left)")
                scheduleRead(after: delay, expectation: nil)
                return
            }
            Log.shared.condition("target", "\(bundleID ?? "-")|\(failure)",
                                 "target unreadable: \(failure) (app=\(bundleID ?? "-")): "
                                 + "decisions fall back to the local buffer")
            return
        }
        Log.shared.clearCondition("target")
        pointerReadRetries = 0     // the target answered: nothing left to recover

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

        // A SELECTION is what the next typed character will overwrite: its length
        // from the application, its start from the published range (or from the
        // fact that a selection covering the whole text cannot start anywhere but
        // at 0). Adopted before any verdict, because the next keystroke may
        // arrive in a few milliseconds.
        adoptSelection(from: snapshot, text: newText)

        // THE MODEL IS THE AUTHORITY WHEN IT MATCHES THE APPLICATION EXACTLY.
        //
        // macOS's double-space substitution moves the space AFTER the dot it
        // inserts ("mot  " -> "mot. "). Aligning "mot " with "mot. " finds the one
        // offset that reproduces that text — the dot inserted BEFORE the space —
        // and would report the caret one character early. The next letter then
        // sees a dot glued to the caret, the "token, not a sentence" guard refuses
        // it, and no capital ever appears after the period macOS just inserted.
        // When the model already predicts the published text there is nothing to
        // align: its caret sits inside a text the application itself confirms.
        if readConfirmsModel(modelText: fieldText, readText: newText), let modelCaret = measuredCaret {
            pendingOldText = nil
            expectation = nil
            readRetries = 0
            pendingSubstitution = false   // the application published the prediction
            caretProven = false      // advanced by hand: still to be confirmed
            trust = .confirmed
            Log.shared.debug("read confirms the model exactly (\(newText.count) char) -> "
                             + "model caret \(modelCaret) kept, app=\(bundleID ?? "-")")
            return
        }

        // A period substitution the tap modelled is a PREDICTION: "mot  " must come
        // back as "mot. ". A read that still shows the two spaces is an answer from
        // BEFORE the application applied it (Chromium and Electron publish late) —
        // ask again rather than adopt a text that will be wrong in 20 ms.
        if pendingSubstitution, let modelText = fieldText, modelText != newText, readRetries < 3 {
            readRetries += 1
            Log.shared.debug("read still shows the unsubstituted text (\(newText.count) char, "
                             + "expected \(modelText.count)) -> retry \(readRetries)/3")
            scheduleRead(after: 0.03 * Double(readRetries), expectation: expectation)
            return
        }
        pendingSubstitution = false

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
        case .replacement(let removed, let added):
            alignment = alignReplacement(old: previous, new: newText, removed: removed,
                                         added: added, previousCaret: measuredCaret)
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

    /// Take the selection the application reports, when it reports one.
    ///
    /// A field that says "nothing is selected" is believed (the selection was
    /// collapsed by a click or an arrow). A field that says nothing at all is not
    /// — an unreadable selection is not an empty one, and the fact we already
    /// hold (Cmd-A, or an earlier read) stays.
    private func adoptSelection(from snapshot: FieldSnapshot, text: [Character]) {
        guard let length = snapshot.selection else { return }
        guard length > 0 else { clearSelection(); return }
        selectionLength = length
        selectionStart = nil      // re-derived from THIS read only, never inherited
        if let platformCaret = snapshot.caret, platformCaret >= 0,
           platformCaret + length <= text.count {
            selectionStart = platformCaret
        } else if length >= text.count {
            // A selection at least as long as the text can only be the whole
            // text, and that starts at 0.
            selectionStart = 0
        }
        if let start = selectionStart {
            // The selection's start IS the insert point: a typed character lands
            // there. Recording it as the caret means a stale measured caret can
            // never make the verdict read text that is about to disappear.
            measuredCaret = start
            caretProven = true
        } else {
            Log.shared.condition("selection", bundleID ?? "-",
                                 "a selection of \(length) of \(text.count) char is visible but "
                                 + "its start is not published (app=\(bundleID ?? "-")): "
                                 + "only its length is used, to recognise the replacement")
        }
    }

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
        // An arrow or Escape collapses the selection: whatever we knew about one
        // no longer describes the field.
        clearSelection()
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
        pendingSubstitution = false
        clearSelection()
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
        let size = handle.offsetInFile
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

        // 2b. macOS's own text substitutions change what a keystroke produces.
        let autoCap = SystemTextPreferences.systemCapitalizationEnabled
        let autoPeriod = SystemTextPreferences.periodSubstitutionEnabled
        checks.append(Check(name: "macOS text",
                            result: .pass,
                            detail: "auto-capitalization=\(autoCap ? "ON (the system's own)" : "off"), "
                                  + "double-space period=\(autoPeriod ? "ON (modelled)" : "off (not modelled)")"))

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
mkdir -p "$SCRIPTS_DIR/Sources/Mac" || fail "impossible de créer $SCRIPTS_DIR/Sources/Mac"
cat > "$SCRIPTS_DIR/Sources/Mac/Preferences.swift" <<'AUTOCAP_EOF_10'
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
AUTOCAP_EOF_10
mkdir -p "$SCRIPTS_DIR/Resources" || fail "impossible de créer $SCRIPTS_DIR/Resources"
cat > "$SCRIPTS_DIR/Resources/Info.plist" <<'AUTOCAP_EOF_11'
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
AUTOCAP_EOF_11
cat > "$SCRIPTS_DIR/build.sh" <<'AUTOCAP_EOF_12'
#!/bin/bash
# ============================================================================
#  build.sh — construit AutoCap.app (Swift, aucun interpréteur, aucune dépendance)
#
#  Sortie : un bundle signé, à l'emplacement demandé (défaut ~/Applications/AutoCap.app).
#
#  Signature : une identité PERSISTANTE (« AutoCap Local Signing ») créée une
#  fois dans le trousseau, pour que l'autorisation Accessibilité survive aux
#  reconstructions. Une signature ad-hoc change d'identité à chaque binaire, donc
#  macOS redemande l'autorisation à chaque fois : c'est précisément ce qu'on
#  supprime ici. Repli honnête sur l'ad-hoc si le certificat ne peut être créé.
#
#  Aucun mot de passe, aucun PKCS#12 : clé privée et certificat sont importés
#  directement au format PEM.
#
#  Lignes attendues :
#    [build] swiftc : <version>
#    [build] sources : N fichiers
#    [build] binaire : <chemin> (<taille>)
#    [build] signature : identité persistante (AutoCap Local Signing) | ad-hoc
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

# --- 4. Signature -----------------------------------------------------------
IDENTITY_NAME="AutoCap Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

have_identity() { security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; }

create_identity() {
    local tmpd
    tmpd="$(mktemp -d)" || return 1
    cat > "$tmpd/req.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = AutoCap Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
    # Portable on both OpenSSL and LibreSSL: the extensions live in a config file
    # rather than on the command line.
    if ! openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$tmpd/key.pem" -out "$tmpd/cert.pem" \
            -config "$tmpd/req.cnf" 2>"$tmpd/e1"; then
        echo "$LOG_PREFIX           certificat : ÉCHEC — $(head -3 "$tmpd/e1" | tr '\n' ' ')"
        echo "$LOG_PREFIX           diagnostic complet : bash tools/signer_diag.sh"
        rm -rf "$tmpd"; return 1
    fi
    # Direct PEM imports: no password to transmit, so no argument can be mangled.
    if ! security import "$tmpd/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign \
            >/dev/null 2>"$tmpd/e2"; then
        echo "$LOG_PREFIX           clé privée : ÉCHEC — $(head -3 "$tmpd/e2" | tr '\n' ' ')"
        rm -rf "$tmpd"; return 1
    fi
    if ! security import "$tmpd/cert.pem" -k "$KEYCHAIN" -T /usr/bin/codesign \
            >/dev/null 2>"$tmpd/e3"; then
        echo "$LOG_PREFIX           certificat : ÉCHEC — $(head -3 "$tmpd/e3" | tr '\n' ' ')"
        rm -rf "$tmpd"; return 1
    fi
    rm -rf "$tmpd"
    have_identity
}

SIGN_MODE=""
if [ "${AUTOCAP_PERSISTENT_IDENTITY:-1}" = "1" ]; then
    if have_identity || create_identity; then
        if codesign --force --sign "$IDENTITY_NAME" --timestamp=none "$APP" >/dev/null 2>&1; then
            SIGN_MODE="identité persistante ($IDENTITY_NAME)"
        fi
    fi
fi
if [ -z "$SIGN_MODE" ]; then
    if codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1; then
        SIGN_MODE="ad-hoc"
    else
        SIGN_MODE="échec de signature (l'application peut tout de même se lancer)"
    fi
fi
echo "$LOG_PREFIX signature : $SIGN_MODE"
if [ "$SIGN_MODE" = "ad-hoc" ]; then
    echo "$LOG_PREFIX           note : signature ad-hoc, donc chaque reconstruction redemandera"
    echo "$LOG_PREFIX                  l'autorisation Accessibilité. Diagnostic : bash tools/signer_diag.sh"
    echo "$LOG_PREFIX                  forcer l'ad-hoc : AUTOCAP_PERSISTENT_IDENTITY=0 bash build.sh"
fi

# --- 5. Empreinte -----------------------------------------------------------
if command -v shasum >/dev/null 2>&1; then
    echo "$LOG_PREFIX empreinte : $(shasum -a 256 "$APP/Contents/MacOS/AutoCap" | cut -c1-16)"
fi

echo "$LOG_PREFIX VERDICT : AutoCap.app prêt dans $APP"
exit 0
AUTOCAP_EOF_12
cat > "$SCRIPTS_DIR/README.md" <<'AUTOCAP_EOF_13'
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

## Corrigé en 1.0.9

- **Point inséré par macOS sur un double espace** : l'alignement plaçait le curseur
  *avant* l'espace (`mot ` vs `mot. `), donc un point collé au curseur et aucune
  majuscule. Une lecture qui reproduit exactement le modèle garde désormais le
  curseur du modèle, et une lecture en retard est réessayée au lieu d'être crue.
- **Frappe sur une sélection** : la sélection (longueur + début) est lue par
  Accessibility et modélisée. Une sélection qui commence à l'offset 0 ouvre le
  champ, et le remplacement est mesuré (`alignReplacement`) au lieu d'être refusé.
  Un Delete sur une sélection n'enlève plus le caractère d'avant.
- **1.0.10 — champ illisible** : quand le texte du champ n'est pas publiable
  (Zen, Electron), la décision vient du tampon local, et ce tampon ignorait le
  début de la sélection : il gardait le mot qu'on s'apprêtait à remplacer, donc
  « un autre mot avant le curseur » alors qu'il n'y a rien. Le tampon est
  maintenant tronqué au début de la sélection (`bufferBeforeCaret`).
- **1.0.12 — le champ sous le pointeur** : quand toutes les routes « élément
  focalisé » échouent (`role=AXButton` après un clic dans Zen, `cannotComplete`
  sur une app occupée), le champ est cherché **sous le pointeur** —
  `AXUIElementCopyElementAtPosition`, puis remontée des parents jusqu'à un champ
  éditable. Le pointeur n'est utilisé que 2 s après un clic. C'est la cause exacte
  du « parfois oui, parfois non » : au moment du geste, le démon ne voyait rien.
- **1.0.11 — l'échec devient lisible** : quand aucune règle ne s'applique, le
  journal l'écrit (`no capital before 'x' — no rule matched`, avec source,
  curseur, sélection, confiance), dédupliqué sur un état grossier. Et après un
  clic, une lecture qui nomme le mauvais élément est **réessayée** (3 fois, 0,1 à
  0,4 s) au lieu de conclure : c'est le clic qui crée la sélection.

## Architecture

```
Sources/
  Core/Rules.swift       décision pure : ce qui ouvre une phrase (188 cas hérités)
  Core/Align.swift       mesure du curseur dans le texte de l'application
  Core/SelfTest.swift    suite de conformité (178 cas) — tourne sans Mac
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
read confirms the model exactly (5 char) -> model caret 5 kept, app=…
Command-A -> 7 char selected from offset 0, the next letter opens the field
```

Chaque condition est écrite **une fois par changement**, jamais une fois par frappe.

## Désinstallation

```bash
"$HOME/Applications/AutoCap.app/Contents/MacOS/AutoCap" --uninstall --remove-permissions
```

Les sources restent dans `~/Scripts/autocap-swift` (recompilables par `build.sh`).
AUTOCAP_EOF_13


# --- 3. Vérification des sources -------------------------------------------
say "étape 3/9 — contrôle des sources"
SWIFT_COUNT=$(find "$SCRIPTS_DIR/Sources" -name '*.swift' | wc -l | tr -d ' ')
[ "$SWIFT_COUNT" -ge 11 ] || fail "sources incomplètes : $SWIFT_COUNT fichier(s) Swift au lieu de 11."
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
