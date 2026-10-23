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
