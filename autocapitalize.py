#!/usr/bin/env python3
"""
autocapitalize.py — macOS auto-capitalization daemon (single file).

WHEN A CAPITAL IS INSERTED
----
The context is re-evaluated on EVERY keystroke and EVERY pointer action. Scanning
backwards from the caret, every "skippable" character is consumed — an unlimited
number of horizontal spaces and opening/closing punctuation — then:

  CASE 2  nothing left, or a hard line break        -> UPPERCASE
  CASE 1  the character found is '.', '!', '?', '…' -> UPPERCASE
          provided at least one space or one punctuation mark was skipped
  otherwise                                         -> nothing

CRASH FIX IN THIS REVISION (SIGSEGV / "Python quit unexpectedly")
----
Two native calls could hard-crash the interpreter — a segfault inside a C function
cannot be caught by `try/except`, so the process died instantly:

  * AXValueGetValue(range_value, kAXValueCFRangeType, None) was called on whatever
    AXSelectedTextRange returned. Several apps (Electron/Notion webviews, some Java
    and Qt views) expose that attribute as a plain NSValue, an NSNumber, a dict or
    even a null-backed AXValue of a DIFFERENT type. Feeding such an object to
    AXValueGetValue dereferences an invalid pointer -> SIGSEGV.
    The type is now verified with AXValueGetType() BEFORE unwrapping, and the whole
    unwrap is additionally guarded by an isinstance/type-name check so a missing
    AXValueGetType binding cannot re-open the hole.
  * CGEventKeyboardGetUnicodeString(event, 8, None, None): depending on the pyobjc
    version the "None" out-parameters are either auto-allocated or passed straight
    through to C. The call is now made through a probe that tries the documented
    4-argument form once, remembers whether it worked, and otherwise falls back to
    a keycode/flags translation via UCKeyTranslate-free means (returns "" instead of
    risking the crash), so no invalid pointer is ever produced.

Additionally, every AX object returned by the API is now sanity-checked before use,
the run-loop sources are kept in a module-level registry so they can never be
garbage-collected while the C side still references them, and any unexpected
exception in the poller is logged (in --debug) instead of being silently swallowed.

REAL-TIME MODEL
----
Two cooperating sources of truth:

  1. A synchronous shadow buffer of the text before the caret, updated inside the
     event tap for every insertion and every deletion.
  2. The Accessibility API, read from a 20 ms CFRunLoop timer plus two forced
     refreshes after every key press, and after every click, scroll and app switch —
     but ONLY when that read proves it is tracking reality.

  CRITICAL: the Accessibility API is NEVER called from inside the event-tap callback.

AX TRUST
----
  * LAGGING READS       — shorter than the shadow and a prefix of it: discarded.
  * PRE-DELETION READS  — longer than the shadow by the characters just deleted:
                          discarded (otherwise a legitimate capital is cancelled).
  * MISSING CARET       — no AXSelectedTextRange: rejected, never guessed.
  * FROZEN VALUES       — unchanged fingerprint after typing: shadow stays in charge.

Requirements
----
    python3 -m pip install --user pyobjc-framework-Quartz \
        pyobjc-framework-ApplicationServices pyobjc-framework-Cocoa

Usage
----
    python3 autocapitalize.py --install     # LaunchAgent + start now
    python3 autocapitalize.py --uninstall
    python3 autocapitalize.py --run
    python3 autocapitalize.py --status
    python3 autocapitalize.py --debug       # foreground + live decision trace
    python3 autocapitalize.py --selftest    # rule engine check, no permissions needed
    python3 autocapitalize.py --axprobe     # inspect the focused field, diagnose crashes
"""

import os
import sys
import time
import plistlib
import subprocess

LABEL = "com.local.autocap"
PLIST_PATH = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
LOG_PATH = os.path.expanduser("~/Library/Logs/autocapitalize.log")

SENTENCE_ENDERS = ".!?\u2026\u3002\uff01\uff1f"
SPACES = " \t\u00a0\u202f\u2009\u200a\u2007\u2002\u2003\u3000"
LINE_BREAKS = "\n\r\u2028\u2029\u000b\u000c"
OPENERS = "\"'`\u201c\u2018\u00ab\u2039([{<*_-\u2022\u2013\u2014\u00b7"
CLOSERS = "\u201d\u2019\u00bb\u203a)]}>"
SKIPPABLE_PUNCTUATION = OPENERS + CLOSERS

ABBREVIATIONS = {
    "m", "mm", "mme", "mlle", "mr", "mrs", "ms", "dr", "pr", "st", "ste",
    "etc", "cf", "ex", "p", "pp", "pj", "nb", "ndlr", "env", "av", "bd", "fig",
    "vol", "no", "n\u00b0", "art", "ch", "tel", "t\u00e9l", "min", "max", "sec",
    "e.g", "i.e", "vs", "approx", "dept", "inc", "ltd", "jr", "sr", "prof",
    "www", "http", "https", "org", "com", "net", "fr", "co", "gov", "edu",
}

POLL_INTERVAL = 0.020
FOLLOWUP_DELAY = 0.012
VERIFY_DELAY = 0.200
FOCUS_DELAY = 0.030
FOCUS_RETRIES = 30
STALE_STRIKES = 2
EDIT_GUARD = 0.150
DOUBLE_SPACE_WINDOW = 0.8
IDLE_AFTER = 3.0
IDLE_SKIP = 15
SHADOW_SIZE = 256

# Keeps CoreFoundation objects alive for the whole process lifetime: if Python
# collects the tap, the run-loop source, the timer or the workspace observer while
# the C runtime still holds a raw pointer to them, the next callback crashes.
_KEEP_ALIVE = []


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
    """Abbreviation, single-letter initial, numbered item or decimal number."""
    if text[index] != ".":
        return False
    token = _preceding_token(text, index).strip("-'\u2019").lower()
    if token == "":
        return False
    if token.isdigit():
        return True
    if len(token) == 1 and token.isalpha():
        return True
    return token in ABBREVIATIONS


def should_capitalize(before_caret: str) -> bool:
    """True when the next letter typed must be uppercased."""
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

    if index < 0:
        return True
    if before_caret[index] in LINE_BREAKS:
        return True
    if before_caret[index] in SENTENCE_ENDERS:
        if not (skipped_space or skipped_punctuation):
            return False
        return not _is_false_sentence_end(before_caret, index)
    return False


# --------------------------------------------------------------------------- #
#                       Shadow buffer helpers (pure)                          #
# --------------------------------------------------------------------------- #

def delete_backward(text: str) -> str:
    return text[:-1]


def delete_word_backward(text: str) -> str:
    index = len(text)
    while index > 0 and text[index - 1] in SPACES:
        index -= 1
    while index > 0 and text[index - 1] not in SPACES + LINE_BREAKS:
        index -= 1
    return text[:index]


def delete_line_backward(text: str) -> str:
    for index in range(len(text) - 1, -1, -1):
        if text[index] in LINE_BREAKS:
            return text[:index + 1]
    return ""


def apply_double_space_period(text: str) -> str:
    """Reproduce the macOS "add period with double-space" substitution."""
    if len(text) < 3:
        return text
    if text[-1] != " " or text[-2] != " ":
        return text
    anchor = text[-3]
    if anchor in SENTENCE_ENDERS or anchor in SPACES or anchor in LINE_BREAKS:
        return text
    if not (anchor.isalnum() or anchor in CLOSERS):
        return text
    return text[:-2] + ". "


def ax_fingerprint(value_length: int, caret: int, before_caret: str):
    return (int(value_length), int(caret), hash(before_caret[-64:]))


def is_stale_ax_read(previous, current, typed_since: int) -> bool:
    if previous is None or typed_since <= 0:
        return False
    return previous == current


def is_lagging_ax_read(shadow: str, before: str, typed_since: int) -> bool:
    if typed_since <= 0:
        return False
    missing = len(shadow) - len(before)
    if missing <= 0:
        return False
    if missing > max(typed_since, 1) + 2:
        return False
    if shadow.startswith(before):
        return True
    overlap = len(shadow) - missing
    return overlap > 0 and before.endswith(shadow[:overlap])


def is_predeletion_ax_read(shadow: str, before: str, deleted_since: int) -> bool:
    if deleted_since <= 0:
        return False
    extra = len(before) - len(shadow)
    if extra <= 0:
        return False
    if extra > max(deleted_since, 1) + 2:
        return False
    if before.startswith(shadow):
        return True
    if shadow == "":
        return False
    start = len(before) - extra - len(shadow)
    return start >= 0 and before[start:start + len(shadow)] == shadow


def is_buffer_reliable(ax_trusted: bool, keyboard_only: bool) -> bool:
    return bool(ax_trusted or keyboard_only)


def looks_like_ax_value(obj) -> bool:
    """
    Cheap, crash-free plausibility check before handing an object to AXValueGetValue.
    Only objects whose Objective-C class is AXValue (or a private subclass thereof)
    may be unwrapped; NSValue/NSNumber/NSDictionary/None must be refused, because
    AXValueGetValue does not validate its argument and segfaults on a mismatch.
    """
    if obj is None:
        return False
    name = type(obj).__name__
    if name in ("NoneType", "int", "float", "str", "bytes", "dict", "list", "tuple"):
        return False
    return "AXValue" in name or name.startswith("__NSCF") is False and "AXValue" in name


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
        "ProcessType": "Interactive",
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


def axprobe() -> None:
    """
    Diagnostic: describe the focused field and the exact type of its selected-range
    attribute, without ever unwrapping it. Run it while the crashing app is focused
    (switch to it within the 5 s countdown) to identify a hostile AX implementation.
    """
    from ApplicationServices import (
        AXUIElementCreateSystemWide, AXUIElementCopyAttributeValue,
        AXIsProcessTrusted, kAXFocusedUIElementAttribute, kAXRoleAttribute,
        kAXValueAttribute, kAXSelectedTextRangeAttribute,
    )
    print("Trusted:", bool(AXIsProcessTrusted()))
    for remaining in range(5, 0, -1):
        print(f"  focus the app to inspect... {remaining}", flush=True)
        time.sleep(1)
    system_element = AXUIElementCreateSystemWide()
    error, element = AXUIElementCopyAttributeValue(
        system_element, kAXFocusedUIElementAttribute, None)
    print("focused element error:", error, "element:", element)
    if error != 0 or element is None:
        return
    for attribute in (kAXRoleAttribute, kAXValueAttribute,
                      kAXSelectedTextRangeAttribute):
        error, value = AXUIElementCopyAttributeValue(element, attribute, None)
        print(f"  {attribute}: error={error} type={type(value).__name__} "
              f"repr={str(value)[:80]!r}")


def selftest() -> None:
    rule_cases = [
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
        ("Test. ", True),
        ("Test.  ", True),
        ("Test.       ", True),
        ("Test. Test. ", True),
        ("Test.\u00a0\u00a0", True),
        ("Wow!  ", True),
        ("Wow !   ", True),
        ("Really?\t", True),
        ("Il dit. \u00ab ", True),
        ("He said \"Hi.\" ", True),
        ("(fin.) ", True),
        ("done...   ", True),
        ("attends\u2026 ", True),
        ("line1\nTest.  ", True),
        ("Plopo. ", True),
        ("Plopo. Plopoplpo.      ", True),
        ("Test.", False),
        ("Wow!", False),
        ("3.14", False),
        ("etc. ", False),
        ("M. ", False),
        ("e.g. ", False),
        ("J. ", False),
        ("1. ", False),
        ("42.   ", False),
        ("www. ", False),
        ("hello ", False),
        ("x, ", False),
        ("x; ", False),
        ("x: ", False),
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
        (apply_double_space_period, "mot  ", "mot. "),
        (apply_double_space_period, "(fin)  ", "(fin). "),
        (apply_double_space_period, "mot   ", "mot   "),
        (apply_double_space_period, "fin.  ", "fin.  "),
        (apply_double_space_period, "mot ", "mot "),
        (apply_double_space_period, "", ""),
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
    scenarios.append(("empty line after deletion",
                      should_capitalize(delete_backward("a")) is True))
    scenarios.append(("ender + multiple spaces", should_capitalize("Test.   ") is True))
    scenarios.append(("modified Return = line start", should_capitalize("") is True))
    scenarios.append(("double space arms the capital",
                      should_capitalize(apply_double_space_period("mot  ")) is True))
    scenarios.append(("double space after abbreviation stays lowercase",
                      should_capitalize(apply_double_space_period("etc  ")) is False))

    frozen = ax_fingerprint(0, 0, "")
    scenarios.append(("frozen AX detected",
                      is_stale_ax_read(frozen, ax_fingerprint(0, 0, ""), 1) is True))
    scenarios.append(("moving AX trusted",
                      is_stale_ax_read(frozen, ax_fingerprint(1, 1, "a"), 1) is False))
    scenarios.append(("lag: missing trailing spaces",
                      is_lagging_ax_read("Plopo.   ", "Plopo.", 3) is True))
    scenarios.append(("no lag when in sync",
                      is_lagging_ax_read("Plopo.  ", "Plopo.  ", 2) is False))
    scenarios.append(("longer read is not a lag",
                      is_lagging_ax_read("mot  ", "mot. ", 1) is False))
    scenarios.append(("predeletion: three characters removed",
                      is_predeletion_ax_read("Plopo. ", "Plopo. abc", 3) is True))
    scenarios.append(("substitution accepted (no deletion)",
                      is_predeletion_ax_read("mot  ", "mot. ", 0) is False))
    scenarios.append(("capital after keyboard-only deletion",
                      (should_capitalize(delete_backward("Plopo. a"))
                       and is_buffer_reliable(False, True)) is True))
    scenarios.append(("no invented capital after an unknown-caret deletion",
                      (should_capitalize(delete_backward("Plopo. a"))
                       and is_buffer_reliable(False, False)) is False))

    # AXValue plausibility guard: only real AXValue objects may be unwrapped.
    scenarios.append(("None refused as AXValue", looks_like_ax_value(None) is False))
    scenarios.append(("int refused as AXValue", looks_like_ax_value(3) is False))
    scenarios.append(("dict refused as AXValue", looks_like_ax_value({}) is False))
    scenarios.append(("str refused as AXValue", looks_like_ax_value("x") is False))

    shadow = "Plopo. abc"
    pending = False
    deleted = 0
    for _ in range(3):
        pre_deletion_read = shadow      # what the app still exposes
        shadow = delete_backward(shadow)
        deleted += 1
        pending = should_capitalize(shadow) and is_buffer_reliable(False, True)
        if not is_predeletion_ax_read(shadow, pre_deletion_read, deleted):
            pending = should_capitalize(pre_deletion_read)   # would be wrong
    scenarios.append(("capital survives pre-deletion polls", pending is True))

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
        lagging_read = shadow[:-1]
        if not is_lagging_ax_read(shadow, lagging_read, 1):
            shadow = lagging_read
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

    # AXValueGetType is the only safe way to know what an AXValue wraps. If the
    # binding is unavailable, range unwrapping is disabled entirely rather than
    # risking the segfault that killed the previous revision.
    try:
        from ApplicationServices import AXValueGetType
    except Exception:
        AXValueGetType = None

    if not AXIsProcessTrusted():
        print("ERROR: Accessibility permission missing for:", _python_path(),
              file=sys.stderr)
        print("Enable it in System Settings > Privacy & Security > Accessibility.",
              file=sys.stderr)

    KEY_RETURN, KEY_KP_ENTER, KEY_LINEFEED = 36, 76, 52
    KEY_TAB, KEY_ESCAPE, KEY_DELETE, KEY_FWD_DELETE = 48, 53, 51, 117
    KEY_Z, KEY_V, KEY_X, KEY_A, KEY_Y = 6, 9, 7, 0, 16
    RETURN_KEYS = {KEY_RETURN, KEY_KP_ENTER, KEY_LINEFEED}
    NAVIGATION = {123, 124, 125, 126, 115, 116, 119, 121}

    system_element = AXUIElementCreateSystemWide()

    state = {
        "shadow": "",
        "known": True,
        "pending": True,
        "ax_ok": False,
        "ax_trusted": False,
        "ax_print": None,
        "ax_strikes": 0,
        "ax_frozen": False,
        "typed_since_ax": 0,
        "deleted_since_ax": 0,
        "keyboard_only": True,
        "guard_until": 0.0,
        "last_space_at": 0.0,
        "tab_lock": False,
        "retries": 0,
        "pointer_lost": False,
        "last_input": 0.0,
        "followup_at": 0.0,
        "verify_at": 0.0,
        "tick": 0,
        "last_trace": None,
        "unicode_probe": None,      # None/True/False: unicode probe state
    }

    def apply_rule():
        if state["tab_lock"]:
            state["pending"] = False
        elif state["known"]:
            state["pending"] = should_capitalize(state["shadow"])

    def set_shadow(text: str, known: bool = True):
        state["shadow"] = text[-SHADOW_SIZE:]
        state["known"] = known
        apply_rule()

    def reset_ax_tracking():
        state["ax_print"] = None
        state["ax_strikes"] = 0
        state["ax_frozen"] = False
        state["ax_trusted"] = False
        state["typed_since_ax"] = 0
        state["deleted_since_ax"] = 0
        state["guard_until"] = 0.0
        state["last_space_at"] = 0.0

    def note_edit(count: int = 1, deletion: bool = False):
        amount = max(1, count)
        if deletion:
            state["deleted_since_ax"] += amount
        else:
            state["typed_since_ax"] += amount
        state["guard_until"] = time.monotonic() + EDIT_GUARD

    def invalidate(delay: float, pointer: bool = False):
        state["known"] = False
        state["retries"] = FOCUS_RETRIES
        now = time.monotonic()
        state["followup_at"] = now + delay
        state["verify_at"] = now + VERIFY_DELAY
        if pointer:
            state["pointer_lost"] = True
            state["keyboard_only"] = False
        reset_ax_tracking()

    def start_new_line():
        state["tab_lock"] = False
        state["retries"] = 0
        state["pointer_lost"] = False
        reset_ax_tracking()
        state["keyboard_only"] = True
        set_shadow("", known=True)
        now = time.monotonic()
        state["followup_at"] = now + FOLLOWUP_DELAY
        state["verify_at"] = now + VERIFY_DELAY

    # ---- AX helpers: timer context ONLY, never inside the tap ---- #
    def ax_attribute(element, attribute):
        if element is None:
            return None
        try:
            error, value = AXUIElementCopyAttributeValue(element, attribute, None)
        except Exception:
            return None
        return value if error == 0 else None

    def focused_element():
        error, element = AXUIElementCopyAttributeValue(
            system_element, kAXFocusedUIElementAttribute, None)
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
        Insertion point index, or None when it cannot be determined SAFELY.

        The attribute is validated twice before AXValueGetValue is called:
          1. the Python-side wrapper must look like an AXValue at all;
          2. AXValueGetType() must report kAXValueCFRangeType.
        Any other shape (NSValue, NSNumber, dict, wrong AXValue type) is refused —
        unwrapping it segfaults the process, which is what produced the
        "Python quit unexpectedly" crash.
        """
        error, range_value = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute, None)
        if range_value is None:
            return None
        if not looks_like_ax_value(range_value):
            return None
        if AXValueGetType is None:
            return None                     # cannot verify -> refuse to unwrap
        try:
            value_type = AXValueGetType(range_value)
        except Exception:
            return None
        if value_type != kAXValueCFRangeType:
            return None
        try:
            ok, cf_range = AXValueGetValue(range_value, kAXValueCFRangeType, None)
        except Exception:
            return None
        if not ok or cf_range is None:
            return None
        try:
            location = int(cf_range.location)
        except Exception:
            return None
        if location < 0:
            return None
        return max(0, min(location, value_length))

    def ax_read():
        element = focused_element()
        if element is None:
            return None

        role = ax_attribute(element, kAXRoleAttribute)
        if role and "Secure" in str(role):
            return None

        value = ax_attribute(element, kAXValueAttribute)
        if not isinstance(value, str):
            count = ax_attribute(element, kAXNumberOfCharactersAttribute)
            if isinstance(count, int) and count == 0:
                return "", ax_fingerprint(0, 0, "")
            return None

        if value == "":
            return "", ax_fingerprint(0, 0, "")

        caret = read_caret(element, len(value))
        if caret is None:
            return None
        before = value[:caret]
        return before, ax_fingerprint(len(value), caret, before)

    def refresh_from_context():
        result = ax_read()
        if result is None:
            state["ax_ok"] = False
            return
        before, fingerprint = result

        within_guard = state["known"] and time.monotonic() < state["guard_until"]

        if within_guard and is_lagging_ax_read(state["shadow"], before,
                    state["typed_since_ax"]):
            state["ax_ok"] = False
            if debug:
                print(f"[autocap] lagging AX read ignored: {before[-24:]!r}", flush=True)
            return

        if within_guard and is_predeletion_ax_read(state["shadow"], before,
                    state["deleted_since_ax"]):
            state["ax_ok"] = False
            if debug:
                print(f"[autocap] pre-deletion AX read ignored: {before[-24:]!r}",
                      flush=True)
            return

        if is_stale_ax_read(state["ax_print"], fingerprint,
                    state["typed_since_ax"] + state["deleted_since_ax"]):
            state["ax_strikes"] += 1
            if state["ax_strikes"] >= STALE_STRIKES:
                state["ax_frozen"] = True
                state["ax_ok"] = False
                if not state["known"] and not state["pointer_lost"]:
                    state["known"] = True
                    apply_rule()
            return

        state["ax_strikes"] = 0
        state["ax_frozen"] = False
        state["ax_print"] = fingerprint
        state["ax_trusted"] = True
        state["typed_since_ax"] = 0
        state["deleted_since_ax"] = 0
        state["guard_until"] = 0.0
        state["ax_ok"] = True
        state["retries"] = 0
        state["pointer_lost"] = False
        state["keyboard_only"] = True
        set_shadow(before, known=True)
        if debug:
            trace = (state["shadow"][-24:], state["pending"])
            if trace != state["last_trace"]:
                state["last_trace"] = trace
                print(f"[autocap] before={state['shadow'][-24:]!r} "
                      f"-> capitalize={state['pending']}", flush=True)

    def event_chars(event):
        """
        Unicode string produced by a key event, or "" when it cannot be obtained.

        The 4-argument pyobjc form is probed exactly once; if that call raises or
        returns an unexpected shape, the probe is disabled for the rest of the
        session so no further native call is attempted with out-parameters this
        binding may not synthesise.
        """
        if state["unicode_probe"] is False:
            return ""
        try:
            result = Quartz.CGEventKeyboardGetUnicodeString(event, 8, None, None)
        except Exception:
            state["unicode_probe"] = False
            return ""
        text = ""
        if isinstance(result, str):
            text = result
        elif isinstance(result, (tuple, list)):
            for item in result:
                if isinstance(item, str):
                    text = item
                    break
                if isinstance(item, (bytes, bytearray)):
                    text = bytes(item).decode("utf-16-le", "ignore")
                    break
        else:
            state["unicode_probe"] = False
            return ""
        state["unicode_probe"] = True
        return text.replace("\x00", "")

    def shadow_insert(text: str, now: float):
        current = state["shadow"]
        unknown = not state["known"]
        for char in text:
            if char in LINE_BREAKS:
                current = ""
                unknown = False
                state["keyboard_only"] = True
                state["last_space_at"] = 0.0
            elif char == " ":
                current = current + char
                if (now - state["last_space_at"]) <= DOUBLE_SPACE_WINDOW:
                    substituted = apply_double_space_period(current)
                    if substituted != current:
                        current = substituted
                        state["last_space_at"] = 0.0
                        continue
                state["last_space_at"] = now
            else:
                current = current + char
                state["last_space_at"] = 0.0
        note_edit(len(text))
        if unknown and state["retries"] <= 0:
            set_shadow("x" + current, known=True)
            state["pointer_lost"] = False
            state["keyboard_only"] = False
        else:
            set_shadow(current, known=not unknown)

    # ---- event tap callback: no AX, no blocking, no logging ---- #
    def callback(proxy, event_type, event, refcon):
        try:
            now = time.monotonic()
            state["last_input"] = now

            if event_type in (Quartz.kCGEventTapDisabledByTimeout,
                              Quartz.kCGEventTapDisabledByUserInput):
                Quartz.CGEventTapEnable(tap, True)
                return event

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

            state["followup_at"] = now + FOLLOWUP_DELAY
            state["verify_at"] = now + VERIFY_DELAY

            keycode = int(Quartz.CGEventGetIntegerValueField(
                event, Quartz.kCGKeyboardEventKeycode))
            flags = Quartz.CGEventGetFlags(event)
            command = bool(flags & Quartz.kCGEventFlagMaskCommand)
            control = bool(flags & Quartz.kCGEventFlagMaskControl)
            option = bool(flags & Quartz.kCGEventFlagMaskAlternate)

            if keycode in RETURN_KEYS:
                start_new_line()
                return event

            if keycode == KEY_DELETE:
                state["tab_lock"] = False
                state["last_space_at"] = 0.0
                previous = state["shadow"]
                if command:
                    updated = delete_line_backward(previous)
                elif option:
                    updated = delete_word_backward(previous)
                else:
                    updated = delete_backward(previous)
                note_edit(max(1, len(previous) - len(updated)), deletion=True)
                set_shadow(updated, state["known"])
                if state["pending"] and not is_buffer_reliable(state["ax_trusted"],
                            state["keyboard_only"]):
                    state["pending"] = False
                return event

            if keycode == KEY_FWD_DELETE:
                state["tab_lock"] = False
                note_edit(1, deletion=True)
                apply_rule()
                if state["pending"] and not is_buffer_reliable(state["ax_trusted"],
                            state["keyboard_only"]):
                    state["pending"] = False
                return event

            if keycode == KEY_TAB:
                if command or control:
                    state["tab_lock"] = False
                    invalidate(FOLLOWUP_DELAY)
                    return event
                state["tab_lock"] = True
                state["retries"] = 0
                reset_ax_tracking()
                state["keyboard_only"] = True
                set_shadow("", known=True)
                state["pending"] = False
                return event

            if command and keycode in (KEY_Z, KEY_Y, KEY_V, KEY_X, KEY_A):
                state["tab_lock"] = False
                invalidate(FOLLOWUP_DELAY, pointer=True)
                return event

            if command or control:
                invalidate(FOLLOWUP_DELAY)
                return event

            if keycode == KEY_ESCAPE or keycode in NAVIGATION:
                state["tab_lock"] = False
                invalidate(FOLLOWUP_DELAY, pointer=True)
                return event

            chars = event_chars(event)
            if not chars:
                return event

            first = chars[0]

            if first.isalpha():
                if state["pending"] and not state["tab_lock"]:
                    upper = first.upper()
                    if upper != first and len(upper) == 1:
                        chars = upper + chars[1:]
                        try:
                            Quartz.CGEventKeyboardSetUnicodeString(
                                event, len(chars), chars)
                        except Exception:
                            pass
                state["tab_lock"] = False
                shadow_insert(chars, now)
                state["pending"] = False
                return event

            state["tab_lock"] = False
            shadow_insert(chars, now)
            return event
        except Exception:
            return event

    # ---- tap setup ---- #
    mask = (Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseUp)
            | Quartz.CGEventMaskBit(Quartz.kCGEventRightMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventOtherMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventScrollWheel))

    tap = Quartz.CGEventTapCreate(
        Quartz.kCGSessionEventTap,
        Quartz.kCGHeadInsertEventTap,
        Quartz.kCGEventTapOptionDefault,
        mask,
        callback,
        None,
    )
    if tap is None:
        print("ERROR: could not create the event tap (missing Accessibility / "
              "Input Monitoring permission).", file=sys.stderr)
        sys.exit(1)
    _KEEP_ALIVE.append(tap)
    _KEEP_ALIVE.append(callback)

    source = Quartz.CFMachPortCreateRunLoopSource(None, tap, 0)
    _KEEP_ALIVE.append(source)
    Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetCurrent(), source,
                              Quartz.kCFRunLoopCommonModes)
    Quartz.CGEventTapEnable(tap, True)

    # ---- continuous poller, outside the tap ---- #
    def timer_callback(*args):
        try:
            state["tick"] += 1
            now = time.monotonic()
            forced = False
            if 0.0 < state["followup_at"] <= now:
                state["followup_at"] = 0.0
                forced = True
            if 0.0 < state["verify_at"] <= now:
                state["verify_at"] = 0.0
                forced = True
            if not forced and state["known"] \
                    and (now - state["last_input"]) > IDLE_AFTER \
                    and (state["tick"] % IDLE_SKIP):
                return

            refresh_from_context()

            if not state["ax_ok"] and not state["known"]:
                if state["retries"] > 0:
                    state["retries"] -= 1
                    return
                if state["pointer_lost"]:
                    state["pointer_lost"] = False
                    state["keyboard_only"] = False
                    set_shadow("x", known=True)
                else:
                    state["known"] = True
                    apply_rule()
        except Exception as error:
            if debug:
                print(f"[autocap] poll error: {error!r}", flush=True)

    timer = Quartz.CFRunLoopTimerCreate(
        None,
        Quartz.CFAbsoluteTimeGetCurrent() + POLL_INTERVAL,
        POLL_INTERVAL, 0, 0,
        timer_callback,
        None,
    )
    if timer is not None:
        _KEEP_ALIVE.append(timer)
        _KEEP_ALIVE.append(timer_callback)
        Quartz.CFRunLoopAddTimer(Quartz.CFRunLoopGetCurrent(), timer,
                                 Quartz.kCFRunLoopCommonModes)

    # ---- application switches invalidate the context ---- #
    try:
        from Cocoa import NSWorkspace, NSObject

        class Watcher(NSObject):
            def appChanged_(self, notification):
                state["tab_lock"] = False
                invalidate(pointer=True)

        watcher = Watcher.alloc().init()
        # NSNotificationCenter does not retain its observers: keep a strong
        # reference or the next notification hits a freed object and crashes.
        _KEEP_ALIVE.append(watcher)
        NSWorkspace.sharedWorkspace().notificationCenter() \
            .addObserver_selector_name_object_(
                watcher, "appChanged:",
                "NSWorkspaceDidActivateApplicationNotification", None)
    except Exception as error:
        if debug:
            print(f"[autocap] workspace observer error: {error!r}", flush=True)
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
    elif argument == "--axprobe":
        axprobe()
    elif argument == "--debug":
        run(debug=True)
    elif argument == "--run":
        run()
    else:
        print(__doc__)
        sys.exit(2)
