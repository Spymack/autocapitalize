#!/usr/bin/env python3
"""
autocapitalize.py — macOS auto-capitalization daemon (single file).

WHEN A CAPITAL IS INSERTED
----
Scanning backwards from the caret, every "skippable" character is consumed — an
unlimited number of horizontal spaces (space, tab, NBSP, thin/figure/ideographic
spaces) and opening/closing punctuation (" ' « » ( ) [ ] { } < > * _ - • – —) —
then:

  CASE 2  nothing left, or a hard line break        -> UPPERCASE
          (empty field, empty line, only spaces, list bullet at line start)
  CASE 1  the character found is '.', '!', '?', '…' -> UPPERCASE
          provided at least one space or one punctuation mark was skipped
  otherwise                    -> nothing

NEVER capitalized
  * letter glued to the symbol: "Test.p", "3.14"
  * abbreviations and initials before the dot: "etc. ", "M. ", "e.g. ", "J. "
  * numbered items / decimals: "1. ", "3. "
  * right after the Tab key (until Return, a click, a focus change, or a real
    character is typed)
  * secure / password fields

REAL-TIME MODEL
----
Two cooperating sources of truth:

  1. A synchronous shadow buffer of the text before the caret, updated inside the
     event tap for every insertion and every deletion.
  2. The Accessibility API, read from a 20 ms CFRunLoop timer plus a forced refresh
     a few milliseconds after every key press, click, scroll-wheel move and
     application switch — but ONLY when that read proves it is tracking reality
     (see "AX trust" below).

  CRITICAL: the Accessibility API is NEVER called from inside the event-tap callback.
  Synchronous AX calls there block system event distribution and freeze the whole Mac.

AX TRUST
----
An AX read is accepted only when it cannot be proven wrong.

  * LAGGING READS (fixes "sometimes a capital after '.  ' works, sometimes not").
    The event tap sees a keystroke BEFORE the application processes it. The forced
    poll a few milliseconds later — and the regular 20 ms poll during fast typing —
    can therefore return the field content as it was one to several characters ago.
    Such a read is shorter than the shadow buffer while still being one of its
    prefixes; accepting it silently rewound the state to just before the spaces that
    follow the period, so `pending` was recomputed as False and the next letter
    stayed lowercase. Whether it happened depended purely on typing speed, which is
    exactly the observed intermittency. These reads are now detected and discarded,
    and a short guard window after every insertion or deletion prevents any AX read
    that is behind the shadow buffer from overriding it.
  * MISSING INSERTION POINT. If the field holds text and no AXSelectedTextRange can
    be read, the read is rejected instead of assuming the caret sits at the end of
    the value (that assumption caused whole words in capitals, or no capital at all,
    when the caret was at the start of the first line).
  * FROZEN VALUES. Every accepted read is fingerprinted (value length, caret, prefix
    hash). If characters were typed since the previous read and the fingerprint has
    not moved, the AX source is declared stale for that field and the shadow buffer
    stays authoritative until the fingerprint moves again.
  * `pending` is only ever re-armed from a trusted source; a keystroke consumes it
    synchronously so a late poll can no longer re-arm it mid-word.

PREVIOUS FIXES
----
  * Fatal IndentationError in the key-insertion branch (daemon could not start).
  * Modified Return (Cmd+Return in Notion, Ctrl/Shift/Option+Return) is handled
    before the Cmd/Ctrl guard, so a new paragraph is a real line start.
  * Click into a not-yet-focused field: the AX read is retried for ~600 ms and
    resolved through the frontmost application when the system-wide query fails.
  * Closing punctuation (» ) ] } ” ’) is skippable: 'He said "Hi." p', "(fin.) p".

Requirements
----
    python3 -m pip install --user pyobjc-framework-Quartz pyobjc-framework-ApplicationServices pyobjc-framework-Cocoa

Permissions (one time)
----
    System Settings > Privacy & Security > Accessibility -> add & enable the Python
    binary printed by `--install`; add it to "Input Monitoring" as well if keystrokes
    are not intercepted.

Usage
----
    python3 autocapitalize.py --install     # LaunchAgent (start at login) + start now
    python3 autocapitalize.py --uninstall
    python3 autocapitalize.py --run         # foreground
    python3 autocapitalize.py --status
    python3 autocapitalize.py --debug       # foreground + live decision trace
    python3 autocapitalize.py --selftest    # rule engine check, no permissions needed

Known limitations
----
  * Soft (word-wrap) line breaks are not line starts: only real newlines are.
  * In apps whose AX text is frozen or caret-less, the shadow buffer alone is used;
    a caret moved with the mouse inside such an app cannot be detected, so the state
    is reset conservatively instead (no capital until a line break or an ender).
  * Rewriting uses CGEventKeyboardSetUnicodeString; a few custom text engines may
    ignore it (medium confidence).
"""

import os
import sys
import time
import plistlib
import subprocess

LABEL = "com.local.autocap"
PLIST_PATH = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
LOG_PATH = os.path.expanduser("~/Library/Logs/autocapitalize.log")

SENTENCE_ENDERS = ".!?\u2026\u3002\uff01\uff1f"                  # . ! ? … 。 ！ ？
SPACES = " \t\u00a0\u202f\u2009\u200a\u2007\u2002\u2003\u3000"    # horizontal spaces
LINE_BREAKS = "\n\r\u2028\u2029\u000b\u000c"
OPENERS = "\"'`\u201c\u2018\u00ab\u2039([{<*_-\u2022\u2013\u2014\u00b7"
CLOSERS = "\u201d\u2019\u00bb\u203a)]}>"                         # ” ’ » › ) ] } >
SKIPPABLE_PUNCTUATION = OPENERS + CLOSERS

# Words that end with a dot without ending a sentence (French + English).
ABBREVIATIONS = {
    "m", "mm", "mme", "mlle", "mr", "mrs", "ms", "dr", "pr", "st", "ste",
    "etc", "cf", "ex", "p", "pp", "pj", "nb", "ndlr", "env", "av", "bd", "fig",
    "vol", "no", "n\u00b0", "art", "ch", "tel", "t\u00e9l", "min", "max", "sec",
    "e.g", "i.e", "vs", "approx", "dept", "inc", "ltd", "jr", "sr", "prof",
    "www", "http", "https", "org", "com", "net", "fr", "co", "gov", "edu",
}

POLL_INTERVAL = 0.020      # continuous AX refresh period (s)
FOLLOWUP_DELAY = 0.012     # forced refresh right after a key event
FOCUS_DELAY = 0.030        # first refresh after a pointer event / focus change
FOCUS_RETRIES = 30         # ~600 ms of retries before the conservative fallback
STALE_STRIKES = 2          # identical fingerprints tolerated before distrusting AX
EDIT_GUARD = 0.150         # AX reads behind the shadow buffer are ignored for this long
IDLE_AFTER = 3.0           # inactivity threshold before backing off
IDLE_SKIP = 15             # while idle, poll every Nth tick only
SHADOW_SIZE = 256          # shadow buffer window (characters)


# --------------------------------------------------------------------------- #
#                        Rule engine (pure, testable)                         #
# --------------------------------------------------------------------------- #

def _preceding_token(text: str, dot_index: int) -> str:
    """Word attached to the dot at `dot_index` (letters, digits, inner dots/hyphens)."""
    index = dot_index - 1
    while index >= 0 and (text[index].isalnum() or text[index] in ".-'\u2019"):
        index -= 1
    return text[index + 1:dot_index]


def _is_false_sentence_end(text: str, index: int) -> bool:
    """
    True when the ender at `index` does not really end a sentence: abbreviation,
    single-letter initial, numbered item or decimal number.
    Only '.' can be a false ender; '!', '?' and '…' always end a sentence.
    """
    if text[index] != ".":
        return False
    token = _preceding_token(text, index).strip("-'\u2019").lower()
    if token == "":
        return False                    # ".. " or " . " -> treat as a real ender
    if token.isdigit():
        return True                     # "1. ", "3. ", decimals
    if len(token) == 1 and token.isalpha():
        return True                     # initial: "J. Smith"
    return token in ABBREVIATIONS


def should_capitalize(before_caret: str) -> bool:
    """
    Return True when the next letter typed must be uppercased, given the whole text
    located before the caret. See the module docstring for the exact rule set.
    """
    index = len(before_caret) - 1
    skipped_space = False
    skipped_punctuation = False

    while index >= 0:
        char = before_caret[index]
        if char in SPACES:
            skipped_space = True
        elif char in SKIPPABLE_PUNCTUATION:
            skipped_punctuation = True
        else:
            break
        index -= 1

    # CASE 2 — nothing (or spaces/punctuation only) before the caret, or line start.
    if index < 0:
        return True
    if before_caret[index] in LINE_BREAKS:
        return True

    # CASE 1 — real sentence ender separated from the caret by a space or punctuation.
    if before_caret[index] in SENTENCE_ENDERS:
        if not (skipped_space or skipped_punctuation):
            return False                # letter glued to the symbol
        return not _is_false_sentence_end(before_caret, index)

    return False


# --------------------------------------------------------------------------- #
#                       Shadow buffer helpers (pure)                          #
# --------------------------------------------------------------------------- #

def delete_backward(text: str) -> str:
    """Backspace: remove the last character."""
    return text[:-1]


def delete_word_backward(text: str) -> str:
    """Option+Backspace: remove trailing spaces then the preceding word."""
    index = len(text)
    while index > 0 and text[index - 1] in SPACES:
        index -= 1
    while index > 0 and text[index - 1] not in SPACES + LINE_BREAKS:
        index -= 1
    return text[:index]


def delete_line_backward(text: str) -> str:
    """Cmd+Backspace: remove everything back to the start of the current line."""
    for index in range(len(text) - 1, -1, -1):
        if text[index] in LINE_BREAKS:
            return text[:index + 1]
    return ""


def ax_fingerprint(value_length: int, caret: int, before_caret: str):
    """
    Compact signature of an Accessibility read. Two reads with the same fingerprint
    describe the same field state; if the user typed in between, the AX source is not
    following reality.
    """
    return (int(value_length), int(caret), hash(before_caret[-64:]))


def is_stale_ax_read(previous, current, typed_since: int) -> bool:
    """
    True when characters were typed since `previous` yet the fingerprint is unchanged,
    i.e. the AX value is frozen and must not override the shadow buffer.
    """
    if previous is None or typed_since <= 0:
        return False
    return previous == current


def is_lagging_ax_read(shadow: str, before: str, typed_since: int) -> bool:
    """
    True when `before` is an out-of-date snapshot of `shadow`: strictly shorter, and
    a prefix of it (allowing for the truncated shadow window). This is what happens
    while typing quickly, because the event tap runs ahead of the application.

    Accepting such a read rewinds the caret context — typically back to just before
    the run of spaces following a period — and wrongly cancels the pending capital.
    """
    if typed_since <= 0:
        return False
    missing = len(shadow) - len(before)
    if missing <= 0:
        return False
    if missing > max(typed_since, 1) + 2:
        return False                    # too far apart to be a mere lag
    if shadow.startswith(before):
        return True
    # The shadow is a right-aligned window of the field: compare the overlap only.
    overlap = len(shadow) - missing
    return overlap > 0 and before.endswith(shadow[:overlap])


# --------------------------------------------------------------------------- #
#                          LaunchAgent management                             #
# --------------------------------------------------------------------------- #

def _script_path() -> str:
    return os.path.realpath(os.path.abspath(__file__))


def _python_path() -> str:
    return os.path.realpath(sys.executable)


def install() -> None:
    os.makedirs(os.path.dirname(PLIST_PATH), exist_ok=True)
    payload = {
        "Label": LABEL,
        "ProgramArguments": [_python_path(), _script_path(), "--run"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Interactive",        # event taps need an interactive session
        "StandardOutPath": LOG_PATH,
        "StandardErrorPath": LOG_PATH,
    }
    with open(PLIST_PATH, "wb") as handle:
        plistlib.dump(payload, handle)

    uid = os.getuid()
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"],
                   capture_output=True, check=False)
    result = subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", PLIST_PATH],
                            capture_output=True, text=True, check=False)
    if result.returncode != 0:
        subprocess.run(["launchctl", "load", "-w", PLIST_PATH],
                       capture_output=True, text=True, check=False)
        print(f"launchctl warning: {result.stderr.strip()}")

    print(f"Installed: {PLIST_PATH}")
    print(f"Log file : {LOG_PATH}")
    print("\nGrant Accessibility (and Input Monitoring) permission to:")
    print(f"    {_python_path()}")
    print("System Settings > Privacy & Security > Accessibility")


def uninstall() -> None:
    uid = os.getuid()
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{LABEL}"],
                   capture_output=True, check=False)
    subprocess.run(["launchctl", "unload", "-w", PLIST_PATH],
                   capture_output=True, check=False)
    if os.path.exists(PLIST_PATH):
        os.remove(PLIST_PATH)
    print("Uninstalled.")


def status() -> None:
    uid = os.getuid()
    result = subprocess.run(["launchctl", "print", f"gui/{uid}/{LABEL}"],
                            capture_output=True, text=True, check=False)
    print("Installed plist:", os.path.exists(PLIST_PATH))
    print(result.stdout.strip() if result.returncode == 0 else "Service not loaded.")


def selftest() -> None:
    rule_cases = [
        # CASE 2 — nothing, spaces, line starts, bullets
        ("", True),
        (" ", True),
        ("        ", True),
        ("\t\t", True),
        ("line\n", True),
        ("line\n     ", True),
        ("line\n\t\t   ", True),
        ("line\n- ", True),
        ("line\n\u2022 ", True),
        ("\"", True),
        # CASE 1 — real ender + any number of spaces / punctuation
        ("Test. ", True),
        ("Test.  ", True),
        ("Test.       ", True),
        ("Test. Test. ", True),
        ("Test. Test.  ", True),
        ("Test. Test.       ", True),
        ("Test.\u00a0\u00a0", True),
        ("Wow!  ", True),
        ("Wow !   ", True),
        ("Really?\t", True),
        ("Really?\t\t   ", True),
        ("Il dit. \u00ab ", True),
        ("Il dit. \u00ab", True),
        ("He said \"Hi.\" ", True),
        ("(fin.) ", True),
        ("done...   ", True),
        ("attends\u2026 ", True),
        ("line1\nTest.  ", True),
        # the exact reported sample, at every capitalizable position
        ("Plopo. ", True),
        ("Plopo. Plopoplpo.      ", True),
        ("Plopo. Plopoplpo.      Ploplgfdg dfmglf dgdgfd dgdfg. ", True),
        ("Plopo. Plopoplpo.      Ploplgfdg dfmglf dgdgfd dgdfg. Gdfgdfgdf.    ", True),
        # glued to the symbol -> untouched
        ("Test.", False),
        ("Wow!", False),
        ("3.14", False),
        # false enders -> untouched
        ("etc. ", False),
        ("Etc.  ", False),
        ("M. ", False),
        ("Mme. ", False),
        ("e.g. ", False),
        ("J. ", False),
        ("1. ", False),
        ("42.   ", False),
        ("www. ", False),
        # plain mid-line spaces / other punctuation
        ("hello ", False),
        ("hello world    ", False),
        ("x, ", False),
        ("x; ", False),
        ("x: ", False),
        # already past the first letter
        ("hello", False),
        ("Test.  P", False),
    ]
    buffer_cases = [
        (delete_backward, "abc", "ab"),
        (delete_backward, "a", ""),
        (delete_backward, "", ""),
        (delete_word_backward, "hello world  ", "hello "),
        (delete_word_backward, "hello world", "hello "),
        (delete_word_backward, "word", ""),
        (delete_line_backward, "line1\nline2", "line1\n"),
        (delete_line_backward, "only", ""),
    ]

    failures = 0
    for text, expected in rule_cases:
        got = should_capitalize(text)
        if got != expected:
            failures += 1
            print(f"FAIL rule {text!r}: expected {expected}, got {got}")
    for function, text, expected in buffer_cases:
        got = function(text)
        if got != expected:
            failures += 1
            print(f"FAIL {function.__name__} {text!r}: expected {expected!r}, got {got!r}")

    scenarios = []

    # Type, delete, type again -> empty line must capitalize.
    scenarios.append(("empty line after deletion",
                      should_capitalize(delete_backward("a")) is True))

    # Ender followed by several spaces.
    scenarios.append(("ender + multiple spaces", should_capitalize("Test.   ") is True))

    # Modified Return (Cmd+Return) empties the buffer -> line start.
    scenarios.append(("modified Return = line start", should_capitalize("") is True))

    # Frozen AX value: same fingerprint after typing -> must be declared stale.
    frozen = ax_fingerprint(0, 0, "")
    scenarios.append(("frozen AX detected",
                      is_stale_ax_read(frozen, ax_fingerprint(0, 0, ""), 1) is True))
    scenarios.append(("moving AX trusted",
                      is_stale_ax_read(frozen, ax_fingerprint(1, 1, "a"), 1) is False))
    scenarios.append(("idle AX not stale",
                      is_stale_ax_read(frozen, ax_fingerprint(0, 0, ""), 0) is False))

    # Lagging AX reads: the tap is ahead of the app while typing spaces.
    scenarios.append(("lag: missing trailing spaces",
                      is_lagging_ax_read("Plopo.   ", "Plopo.", 3) is True))
    scenarios.append(("lag: one character behind",
                      is_lagging_ax_read("Plopo.  ", "Plopo. ", 1) is True))
    scenarios.append(("no lag when in sync",
                      is_lagging_ax_read("Plopo.  ", "Plopo.  ", 2) is False))
    scenarios.append(("no lag when idle",
                      is_lagging_ax_read("Plopo.  ", "Plopo.", 0) is False))
    scenarios.append(("different text is not a lag",
                      is_lagging_ax_read("Plopo.  ", "autre", 3) is False))
    scenarios.append(("deletion is not a lag",
                      is_lagging_ax_read("Plop", "Plopo.  ", 1) is False))

    # The reported sequence, typed fast, with a lagging poll after every keystroke.
    text = "Plopo. Plopoplpo.      Ploplgfdg dfmglf dgdgfd dgdfg. gdfgdfgdf.    dfdffd"
    shadow = ""
    produced = ""
    pending = should_capitalize(shadow)
    for char in text:
        if char.isalpha():
            produced += char.upper() if pending else char
            shadow += char
            pending = False
        else:
            produced += char
            shadow += char
            pending = should_capitalize(shadow)
        # A poll fires here with the field content as it was one character ago.
        lagging_read = shadow[:-1]
        if not is_lagging_ax_read(shadow, lagging_read, 1):
            pending = should_capitalize(shadow)
    expected = "Plopo. Plopoplpo.      Ploplgfdg dfmglf dgdgfd dgdfg. Gdfgdfgdf.    Dfdffd"
    if produced != expected:
        print(f"FAIL scenario: fast typing -> {produced!r}")
        failures += 1

    for name, ok in scenarios:
        if not ok:
            failures += 1
            print(f"FAIL scenario: {name}")

    total = len(rule_cases) + len(buffer_cases) + len(scenarios) + 1
    print(f"{total - failures}/{total} passed.")
    sys.exit(1 if failures else 0)


# --------------------------------------------------------------------------- #
#                                 Daemon                                      #
# --------------------------------------------------------------------------- #

def run(debug: bool = False) -> None:
    import Quartz
    from ApplicationServices import (
        AXUIElementCreateSystemWide,
        AXUIElementCreateApplication,
        AXUIElementCopyAttributeValue,
        AXValueGetValue,
        AXIsProcessTrusted,
        kAXFocusedUIElementAttribute,
        kAXValueAttribute,
        kAXRoleAttribute,
        kAXSelectedTextRangeAttribute,
        kAXNumberOfCharactersAttribute,
        kAXValueCFRangeType,
    )

    if not AXIsProcessTrusted():
        print("ERROR: Accessibility permission missing for:", _python_path(),
              file=sys.stderr)
        print("Enable it in System Settings > Privacy & Security > Accessibility.",
              file=sys.stderr)
        # Keep running: permission may be granted while the process is alive.

    # ---- key codes (layout independent) ---------------------------------- #
    KEY_RETURN, KEY_KP_ENTER, KEY_LINEFEED = 36, 76, 52
    KEY_TAB, KEY_ESCAPE, KEY_DELETE, KEY_FWD_DELETE = 48, 53, 51, 117
    KEY_Z, KEY_V, KEY_X, KEY_A, KEY_Y = 6, 9, 7, 0, 16
    RETURN_KEYS = {KEY_RETURN, KEY_KP_ENTER, KEY_LINEFEED}
    NAVIGATION = {123, 124, 125, 126, 115, 116, 119, 121}   # arrows, home/end, page up/down

    system_element = AXUIElementCreateSystemWide()

    state = {
        "shadow": "",            # synchronous model of the text before the caret
        "known": True,           # False -> shadow unreliable, wait for AX
        "pending": True,         # next letter must be uppercased
        "ax_ok": False,          # last poll produced a usable AX read
        "ax_print": None,        # fingerprint of the last accepted AX read
        "ax_strikes": 0,         # consecutive frozen reads
        "ax_frozen": False,      # AX declared unreliable for the current field
        "typed_since_ax": 0,     # characters typed since the last accepted read
        "guard_until": 0.0,      # ignore AX reads behind the shadow until this time
        "tab_lock": False,       # Tab just pressed -> no capital
        "retries": 0,            # remaining AX attempts before the safe fallback
        "pointer_lost": False,   # caret moved by the mouse and never resolved
        "last_input": 0.0,
        "followup_at": 0.0,
        "tick": 0,
        "last_trace": None,
    }

    def apply_rule():
        """Recompute the decision from the shadow buffer (synchronous, tap-safe)."""
        if state["tab_lock"]:
            state["pending"] = False
        elif state["known"]:
            state["pending"] = should_capitalize(state["shadow"])
        # unknown shadow: keep the previous decision until the poller settles it.

    def set_shadow(text: str, known: bool = True):
        state["shadow"] = text[-SHADOW_SIZE:]
        state["known"] = known
        apply_rule()

    def reset_ax_tracking():
        """Forget the fingerprint: a new field / caret deserves a fresh verdict."""
        state["ax_print"] = None
        state["ax_strikes"] = 0
        state["ax_frozen"] = False
        state["typed_since_ax"] = 0
        state["guard_until"] = 0.0

    def note_edit(count: int = 1):
        """An edit was made through the keyboard: AX will be behind for a moment."""
        state["typed_since_ax"] += max(1, count)
        state["guard_until"] = time.monotonic() + EDIT_GUARD

    def invalidate(delay: float = FOCUS_DELAY, pointer: bool = False):
        """Caret/focus may have moved: force a fast, repeated AX resolution."""
        state["known"] = False
        state["retries"] = FOCUS_RETRIES
        state["followup_at"] = time.monotonic() + delay
        if pointer:
            state["pointer_lost"] = True
        reset_ax_tracking()

    def start_new_line():
        """
        A line break was produced (plain Return, Shift+Return, Cmd+Return in Notion,
        Ctrl+Return...): the caret is at the start of a fresh line -> CASE 2.
        The AX fingerprint is reset because the caret jumped, and a verification is
        scheduled since some apps map modified Return to "send"/"submit" instead.
        """
        state["tab_lock"] = False
        state["retries"] = 0
        state["pointer_lost"] = False
        reset_ax_tracking()
        set_shadow("", known=True)              # sets pending = True
        state["followup_at"] = time.monotonic() + FOLLOWUP_DELAY

    # ---- AX helpers: timer context ONLY, never inside the tap ------------- #
    def ax_attribute(element, attribute):
        if element is None:
            return None
        try:
            error, value = AXUIElementCopyAttributeValue(element, attribute, None)
        except Exception:
            return None
        return value if error == 0 else None

    def focused_element():
        """
        Focused UI element. The system-wide query can transiently fail right after a
        click (focus changes are asynchronous), so fall back to the frontmost
        application's own focused element.
        """
        element = ax_attribute(system_element, kAXFocusedUIElementAttribute)
        if element is not None:
            return element
        try:
            from Cocoa import NSWorkspace
            application = NSWorkspace.sharedWorkspace().frontmostApplication()
            if application is None:
                return None
            app_element = AXUIElementCreateApplication(application.processIdentifier())
            return ax_attribute(app_element, kAXFocusedUIElementAttribute)
        except Exception:
            return None

    def read_caret(element, value_length: int):
        """
        Insertion point index, or None when it cannot be determined. Never guessed:
        assuming the end of the value is what produced the runaway-capital and
        no-capital loops in Notion-like editors.
        """
        range_value = ax_attribute(element, kAXSelectedTextRangeAttribute)
        if range_value is None:
            return None
        try:
            ok, cf_range = AXValueGetValue(range_value, kAXValueCFRangeType, None)
        except Exception:
            return None
        if not ok or cf_range is None:
            return None
        try:
            # A selection is replaced by what is typed: its start is the caret.
            return max(0, min(int(cf_range.location), value_length))
        except Exception:
            return None

    def ax_read():
        """
        (text_before_caret, fingerprint) for the focused field, or None when the
        field is unreadable, caret-less or protected.
        """
        element = focused_element()
        if element is None:
            return None

        role = ax_attribute(element, kAXRoleAttribute)
        if role and "Secure" in str(role):
            return None                         # never touch password fields

        value = ax_attribute(element, kAXValueAttribute)
        if not isinstance(value, str):
            count = ax_attribute(element, kAXNumberOfCharactersAttribute)
            if isinstance(count, int) and count == 0:
                return "", ax_fingerprint(0, 0, "")     # empty field -> CASE 2
            return None

        if value == "":
            return "", ax_fingerprint(0, 0, "")

        caret = read_caret(element, len(value))
        if caret is None:
            return None                         # no insertion point: do NOT guess
        before = value[:caret]
        return before, ax_fingerprint(len(value), caret, before)

    def refresh_from_context():
        """Authoritative refresh from the live field content (outside the tap)."""
        result = ax_read()
        if result is None:
            state["ax_ok"] = False              # shadow buffer stays in charge
            return
        before, fingerprint = result

        # 1. Lagging snapshot: the application has not processed the last keystrokes
        #    yet. Keep the shadow buffer, keep `pending`, and try again next tick.
        if state["known"] and time.monotonic() < state["guard_until"] \
                and is_lagging_ax_read(state["shadow"], before,
                                       state["typed_since_ax"]):
            state["ax_ok"] = False
            if debug:
                print(f"[autocap] lagging AX read ignored: {before[-24:]!r}",
                      flush=True)
            return

        # 2. Frozen value: fingerprint unchanged although characters were typed.
        if is_stale_ax_read(state["ax_print"], fingerprint, state["typed_since_ax"]):
            state["ax_strikes"] += 1
            if state["ax_strikes"] >= STALE_STRIKES:
                state["ax_frozen"] = True
                state["ax_ok"] = False
                if not state["known"] and not state["pointer_lost"]:
                    state["known"] = True
                    apply_rule()
            return

        # 3. Trusted read: it becomes the reference.
        state["ax_strikes"] = 0
        state["ax_frozen"] = False
        state["ax_print"] = fingerprint
        state["typed_since_ax"] = 0
        state["guard_until"] = 0.0
        state["ax_ok"] = True
        state["retries"] = 0
        state["pointer_lost"] = False
        set_shadow(before, known=True)
        if debug:
            trace = (state["shadow"][-24:], state["pending"])
            if trace != state["last_trace"]:
                state["last_trace"] = trace
                print(f"[autocap] before={state['shadow'][-24:]!r} "
                      f"-> capitalize={state['pending']}", flush=True)

    def event_chars(event):
        """Unicode string produced by a key event ('' when none, e.g. dead keys)."""
        try:
            result = Quartz.CGEventKeyboardGetUnicodeString(event, 8, None, None)
        except Exception:
            return ""
        if isinstance(result, tuple):
            for item in result:                 # tolerate pyobjc binding variations
                if isinstance(item, str):
                    return item
                if isinstance(item, (bytes, bytearray)):
                    return item.decode("utf-16-le", "ignore")
            return ""
        return result if isinstance(result, str) else ""

    def shadow_insert(text: str):
        """Append typed characters, resetting the buffer on real line breaks."""
        current = state["shadow"]
        unknown = not state["known"]
        for char in text:
            if char in LINE_BREAKS:
                current = ""
                unknown = False                 # a fresh line is a known context
            else:
                current = current + char
        note_edit(len(text))
        if unknown and state["retries"] <= 0:
            # Caret never resolved: prepend a neutral character so the rule engine
            # cannot invent a capital in the middle of an unreadable word.
            set_shadow("x" + current, known=True)
            state["pointer_lost"] = False
        else:
            set_shadow(current, known=not unknown)

    # ---- event tap callback: no AX, no blocking, no logging -------------- #
    def callback(proxy, event_type, event, refcon):
        try:
            now = time.monotonic()
            state["last_input"] = now

            if event_type in (Quartz.kCGEventTapDisabledByTimeout,
                              Quartz.kCGEventTapDisabledByUserInput):
                Quartz.CGEventTapEnable(tap, True)
                return event

            # Any pointer activity may move the caret or change the focused field.
            if event_type in (Quartz.kCGEventLeftMouseDown,
                              Quartz.kCGEventRightMouseDown,
                              Quartz.kCGEventOtherMouseDown,
                              Quartz.kCGEventLeftMouseUp,
                              Quartz.kCGEventScrollWheel):
                state["tab_lock"] = False
                invalidate(pointer=True)
                return event

            if event_type != Quartz.kCGEventKeyDown:
                return event

            state["followup_at"] = now + FOLLOWUP_DELAY   # always re-verify via AX

            keycode = int(Quartz.CGEventGetIntegerValueField(
                event, Quartz.kCGKeyboardEventKeycode))
            flags = Quartz.CGEventGetFlags(event)
            command = bool(flags & Quartz.kCGEventFlagMaskCommand)
            control = bool(flags & Quartz.kCGEventFlagMaskControl)
            option = bool(flags & Quartz.kCGEventFlagMaskAlternate)

            # ---- structural keys FIRST: they must win over the modifier guard ---- #
            # Return / Enter with ANY modifier still creates a new line or paragraph
            # (Notion: Cmd+Return, Shift+Return; many editors: Ctrl/Option+Return).
            if keycode in RETURN_KEYS:
                start_new_line()
                return event

            # ---- deletions: re-evaluate IMMEDIATELY, synchronously ---- #
            if keycode == KEY_DELETE:
                state["tab_lock"] = False
                note_edit()                      # the field changed: AX must follow
                if command:
                    set_shadow(delete_line_backward(state["shadow"]), state["known"])
                elif option:
                    set_shadow(delete_word_backward(state["shadow"]), state["known"])
                else:
                    set_shadow(delete_backward(state["shadow"]), state["known"])
                return event

            if keycode == KEY_FWD_DELETE:
                state["tab_lock"] = False
                note_edit()
                apply_rule()            # text after the caret changes, not before it
                return event

            if keycode == KEY_TAB:
                if command or control:
                    state["tab_lock"] = False
                    invalidate(FOLLOWUP_DELAY)   # Cmd+Tab / Ctrl+Tab: app or tab switch
                    return event
                state["tab_lock"] = True         # explicitly no capital after Tab
                state["retries"] = 0
                reset_ax_tracking()
                set_shadow("", known=True)
                state["pending"] = False
                return event

            # ---- editing shortcuts ---- #
            if command and keycode in (KEY_Z, KEY_Y, KEY_V, KEY_X, KEY_A):
                state["tab_lock"] = False
                invalidate(FOLLOWUP_DELAY)       # undo/redo/paste/cut/select-all
                return event

            if command or control:
                invalidate(FOLLOWUP_DELAY)       # unknown side effect: let AX decide
                return event

            if keycode == KEY_ESCAPE or keycode in NAVIGATION:
                state["tab_lock"] = False
                invalidate(FOLLOWUP_DELAY)       # caret moved: AX will resolve it
                return event

            chars = event_chars(event)
            if not chars:
                return event                     # dead key: nothing inserted yet

            first = chars[0]

            if first.isalpha():
                if state["pending"] and not state["tab_lock"]:
                    upper = first.upper()
                    if upper != first:           # works for accented letters too
                        chars = upper + chars[1:]
                        Quartz.CGEventKeyboardSetUnicodeString(
                            event, len(chars), chars)
                state["tab_lock"] = False
                shadow_insert(chars)
                # Consumed for this word. A late or frozen AX read can no longer
                # re-arm it: apply_rule() runs only on a trusted read or a shadow edit.
                state["pending"] = False
                return event

            # Any other character (space, ender, digit, comma, quote, bracket...):
            # append it and let the rule engine decide again.
            state["tab_lock"] = False
            shadow_insert(chars)
            return event
        except Exception:
            return event                         # never eat or delay input

    # ---- tap setup ------------------------------------------------------- #
    mask = (Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseUp)
            | Quartz.CGEventMaskBit(Quartz.kCGEventRightMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventOtherMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventScrollWheel))

    tap = Quartz.CGEventTapCreate(
        Quartz.kCGSessionEventTap,
        Quartz.kCGHeadInsertEventTap,
        Quartz.kCGEventTapOptionDefault,         # default = events may be modified
        mask,
        callback,
        None,
    )
    if tap is None:
        print("ERROR: could not create the event tap (missing Accessibility / "
              "Input Monitoring permission).", file=sys.stderr)
        sys.exit(1)

    source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
    Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetCurrent(), source,
                              Quartz.kCFRunLoopCommonModes)
    Quartz.CGEventTapEnable(tap, True)

    # ---- continuous poller, outside the tap ------------------------------ #
    def timer_callback(*args):
        try:
            state["tick"] += 1
            now = time.monotonic()
            forced = 0.0 < state["followup_at"] <= now
            if forced:
                state["followup_at"] = 0.0
            elif not state["known"]:
                pass                             # must resolve an unknown caret now
            elif (now - state["last_input"]) > IDLE_AFTER \
                    and (state["tick"] % IDLE_SKIP):
                return

            refresh_from_context()

            if not state["ax_ok"] and not state["known"]:
                # After a click the focus change is asynchronous and the field often
                # becomes readable only a few frames later: retry before giving up.
                if state["retries"] > 0:
                    state["retries"] -= 1
                    return
                if state["pointer_lost"]:
                    # The caret was moved with the mouse and the app exposes nothing:
                    # stay conservative rather than guessing a capital mid-word.
                    state["pointer_lost"] = False
                    set_shadow("x", known=True)
                else:
                    # Keyboard-only context: the shadow buffer is trustworthy.
                    state["known"] = True
                    apply_rule()
        except Exception:
            pass                                 # polling must never kill the loop

    timer = Quartz.CFRunLoopTimerCreate(
        None,
        Quartz.CFAbsoluteTimeGetCurrent() + POLL_INTERVAL,
        POLL_INTERVAL, 0, 0,
        timer_callback,
        None,
    )
    if timer is not None:
        Quartz.CFRunLoopAddTimer(Quartz.CFRunLoopGetCurrent(), timer,
                                 Quartz.kCFRunLoopCommonModes)

    # ---- application switches invalidate the context --------------------- #
    try:
        from Cocoa import NSWorkspace, NSObject

        class Watcher(NSObject):
            def appChanged_(self, notification):
                state["tab_lock"] = False
                invalidate(pointer=True)

        watcher = Watcher.alloc().init()
        NSWorkspace.sharedWorkspace().notificationCenter() \
            .addObserver_selector_name_object_(
                watcher, "appChanged:",
                "NSWorkspaceDidActivateApplicationNotification", None)
    except Exception:
        pass                                     # optional refinement only

    try:
        refresh_from_context()                   # initial state (outside the tap)
    except Exception:
        pass

    if debug:
        print("[autocap] running — type in any text field.", flush=True)

    Quartz.CFRunLoopRun()


# --------------------------------------------------------------------------- #
#                                  Entry                                      #
# --------------------------------------------------------------------------- #

if __name__ == "__main__":
    argument = sys.argv[1] if len(sys.argv) > 1 else "--run"
    if argument == "--install":
        install()
    elif argument == "--uninstall":
        uninstall()
    elif argument == "--status":
        status()
    elif argument == "--selftest":
        selftest()
    elif argument == "--debug":
        run(debug=True)
    elif argument == "--run":
        run()
    else:
        print(__doc__)
        sys.exit(2)
