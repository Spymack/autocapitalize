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
