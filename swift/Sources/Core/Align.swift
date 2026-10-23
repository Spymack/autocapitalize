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
