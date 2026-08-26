#!/usr/bin/env python3
"""
autocapitalize.py — macOS auto-capitalization daemon (single file).

WHEN A CAPITAL IS INSERTED
----
Scanning backwards from the caret, every "skippable" character is consumed — any
number of horizontal spaces and opening/closing punctuation — then:

  "start"      nothing left                       -> UPPERCASE (guarded, see below)
  "linebreak"  a hard line break                  -> UPPERCASE
  "ender"      '.', '!', '?', '…'                 -> UPPERCASE
               provided at least one space or one punctuation mark was skipped
  otherwise                                       -> nothing

FIXED IN THIS REVISION
----
The "start of text" reason is the only one that depends on the LEFT EDGE of the
shadow buffer, i.e. on something the buffer cannot prove on its own. The previous
build guarded it with a test on `shadow == ""`, which was too narrow:

    TAB accepts a Cotypist completion -> context invalidated -> AX cannot resolve
    it -> neutral fallback shadow "x"
    DEL          -> shadow ""    -> guarded, no capital          (correct)
    DEL          -> shadow ""    -> guarded, no capital          (correct)
    SPACE        -> shadow " "   -> NOT empty, guard bypassed,
                                    should_capitalize(" ") is True -> CAPITAL (bug)

The same happened without TAB: once deletions had emptied a buffer whose left edge
was never confirmed, a single space re-armed the capital.

should_capitalize() is now expressed through capitalize_reason(), and the reason
"start" is accepted only when can_trust_line_start() agrees:

  * the Accessibility API confirmed the text before the caret, or
  * this process itself observed the Return that created the line,

and, in both cases, only when the buffer is not SYNTHETIC — a buffer is synthetic
whenever its left edge was fabricated rather than observed:

  * the neutral "x" fallback used after a pointer event, TAB, or an unresolvable
    focus change,
  * a buffer truncated to SHADOW_SIZE, whose real beginning is unknown.

Trailing spaces and punctuation therefore no longer launder an unknown context
into a "start of line" claim.

EARLIER FIXES RETAINED
----
* TAB never asserts "start of line": it invalidates the context like a pointer
  event, so an accepted inline completion (Cotypist, IDEs) cannot arm a capital.
* A deletion cannot invent a capital from a buffer the AX layer never confirmed.
* faulthandler + a global excepthook writing to the log.
* SIGTERM / SIGINT / SIGHUP handlers stopping the run loop cleanly.
* Event-tap watchdog: re-enabled, and recreated when macOS kills it.
* AXIsProcessTrustedWithOptions() startup check with a distinct exit code.
* Application blacklist (terminals, editors, IDEs, VMs, remote desktops, games).
* Field-shape awareness: search / URL / password fields and non-text roles skipped.
* Dead keys and IME compositions are never rewritten.
* CAPITALIZE_BY_SHIFT for undo-friendly capitalization.
* Active selections invalidate the context instead of being mismodelled.
* AXObserver on the focused application; the 20 ms poll is only a fallback.
* Fully idle when no editable field has focus.
* Every ObjC-facing callback ends in a bare except (an escaping Python exception
  becomes an ObjC exception and aborts the process — the original SIGABRT).
* AXValueGetValue is only called after AXValueGetType() == kAXValueCFRangeType.

REAL-TIME MODEL
----
  1. A synchronous shadow buffer of the text before the caret, updated in the tap.
  2. The Accessibility API, read from AX notifications plus a fallback timer —
     but ONLY when the read proves it is tracking reality.

  CRITICAL: the Accessibility API is NEVER called from inside the event-tap callback.

Requirements
----
    python3 -m pip install --user pyobjc-framework-Quartz \
        pyobjc-framework-ApplicationServices pyobjc-framework-Cocoa

Usage
----
    python3 autocapitalize.py --install
    python3 autocapitalize.py --uninstall
    python3 autocapitalize.py --run
    python3 autocapitalize.py --status
    python3 autocapitalize.py --debug
    python3 autocapitalize.py --selftest
    python3 autocapitalize.py --axprobe
"""

import os
import sys
import time
import signal
import plistlib
import subprocess
import traceback
import faulthandler

LABEL = "com.local.autocap"
PLIST_PATH = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
LOG_PATH = os.path.expanduser("~/Library/Logs/autocapitalize.log")
FAULT_LOG_PATH = os.path.expanduser("~/Library/Logs/autocapitalize-fault.log")

EXIT_NO_PERMISSION = 3
EXIT_NO_TAP = 4

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

# Applications where automatic capitalization is harmful: shells, editors with
# modal keybindings, IDEs with their own completion, remote sessions, games.
BLACKLISTED_BUNDLES = {
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
    "com.todesktop.230313mzl4w4u92",   # Cursor
    "com.exafunction.windsurf",
    "com.sublimetext.4",
    "com.apple.dt.xcode",
    "com.jetbrains.pycharm",
    "com.jetbrains.intellij",
    "com.jetbrains.webstorm",
    "com.jetbrains.clion",
    "com.jetbrains.goland",
    "com.jetbrains.rider",
    "org.vim.MacVim",
    "org.gnu.Emacs",
    "com.apple.screensharing",
    "com.apple.ScreenSharing",
    "com.teamviewer.TeamViewer",
    "com.realvnc.vncviewer",
    "com.parallels.desktop.console",
    "com.vmware.fusion",
    "org.virtualbox.app.VirtualBoxVM",
    "com.utmapp.UTM",
    "com.valvesoftware.steam",
}

# AX roles that carry editable prose. Anything else is ignored outright.
EDITABLE_ROLES = {"AXTextArea", "AXTextField", "AXComboBox"}
# Subroles that must never be touched, even with an editable role.
EXCLUDED_SUBROLES = {
    "AXSecureTextField",
    "AXSearchField",
    "AXURIField",
    "AXAddressField",
}

POLL_INTERVAL = 0.020
IDLE_POLL_INTERVAL = 0.250
FOLLOWUP_DELAY = 0.012
VERIFY_DELAY = 0.200
FOCUS_DELAY = 0.030
FOCUS_RETRIES = 30
STALE_STRIKES = 2
EDIT_GUARD = 0.150
DOUBLE_SPACE_WINDOW = 0.8
IDLE_AFTER = 3.0
SHADOW_SIZE = 256
TAP_CHECK_INTERVAL = 1.0
COMPOSITION_TIMEOUT = 2.0

# False -> rewrite the event's Unicode payload (most reliable).
# True  -> keep the original event and add the Shift modifier (undo-friendly).
CAPITALIZE_BY_SHIFT = False

# CoreFoundation / Objective-C objects referenced by raw pointers on the C side.
# Collecting any of them would make the next callout dereference freed memory.
_KEEP_ALIVE = []


def _log_line(message: str) -> None:
    try:
        print(message, flush=True)
    except Exception:
        pass


def _log_callback_error(where: str, debug: bool) -> None:
    """
    Last line of defence for callbacks invoked from Objective-C.

    An exception escaping a PyObjC closure is re-raised as an Objective-C
    exception; AppKit's dispatch code does not catch it and the process aborts
    with SIGABRT. Every callback therefore ends in a bare except calling this.
    """
    if not debug:
        return
    try:
        _log_line(f"[autocap] {where} error:\n{traceback.format_exc()}")
    except Exception:
        pass


def _install_crash_diagnostics() -> None:
    try:
        handle = open(FAULT_LOG_PATH, "a", buffering=1)
        _KEEP_ALIVE.append(handle)
        faulthandler.enable(handle, all_threads=True)
    except Exception:
        pass

    def hook(exc_type, exc_value, exc_traceback):
        try:
            text = "".join(traceback.format_exception(
                exc_type, exc_value, exc_traceback))
            _log_line(f"[autocap] uncaught exception:\n{text}")
        except Exception:
            pass

    sys.excepthook = hook


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


def capitalize_reason(before_caret: str):
    """
    Why the next letter should be uppercased, or None.

      "start"      the backwards scan consumed the whole buffer
      "linebreak"  a hard line break was found
      "ender"      a sentence-ending mark was found, with a separator after it

    The distinction matters: "start" is the ONLY reason that depends on the left
    edge of the buffer, so it is the only one that needs external confirmation
    before it may arm a capital.
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

    if index < 0:
        return "start"
    char = before_caret[index]
    if char in LINE_BREAKS:
        return "linebreak"
    if char in SENTENCE_ENDERS:
        if not (skipped_space or skipped_punctuation):
            return None
        return None if _is_false_sentence_end(before_caret, index) else "ender"
    return None


def should_capitalize(before_caret: str) -> bool:
    """True when the next letter typed must be uppercased (rule only)."""
    return capitalize_reason(before_caret) is not None


def can_trust_line_start(ax_trusted: bool, saw_line_break: bool,
            synthetic: bool) -> bool:
    """
    Whether a "start of text/line" verdict may be believed.

    It is the strongest reason to capitalize and therefore the one that must never
    be assumed. A synthetic buffer — one whose left edge was fabricated (the "x"
    fallback after a pointer event or a TAB completion) or lost (truncated at
    SHADOW_SIZE) — can never claim it, no matter how many spaces or punctuation
    marks trail behind the caret. That laundering is exactly what turned
    "TAB, DEL, DEL, SPACE" into a spurious capital.
    """
    if synthetic:
        return False
    return bool(ax_trusted or saw_line_break)


def resolve_capitalization(before_caret: str, ax_trusted: bool,
            saw_line_break: bool, synthetic: bool) -> bool:
    """Full decision: rule engine plus the trust requirement on "start"."""
    reason = capitalize_reason(before_caret)
    if reason is None:
        return False
    if reason == "start" and not can_trust_line_start(
            ax_trusted, saw_line_break, synthetic):
        return False
    return True


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


def is_app_blacklisted(bundle_id) -> bool:
    if not bundle_id:
        return False
    return str(bundle_id).lower() in {item.lower() for item in BLACKLISTED_BUNDLES}


def is_editable_target(role, subrole) -> bool:
    if role is None:
        return False
    role_name = str(role)
    if role_name not in EDITABLE_ROLES:
        return False
    if subrole is not None and str(subrole) in EXCLUDED_SUBROLES:
        return False
    if "Secure" in role_name:
        return False
    return True


def looks_like_ax_value(obj) -> bool:
    """
    Crash-free plausibility check before handing an object to AXValueGetValue.
    Only wrappers whose class name contains "AXValue" may be unwrapped; None,
    NSNumber, NSValue and dicts must be refused, because AXValueGetValue does not
    validate its argument and segfaults on a mismatch.
    """
    if obj is None:
        return False
    name = type(obj).__name__
    if name in ("NoneType", "int", "float", "str", "bytes", "dict", "list", "tuple"):
        return False
    return "AXValue" in name


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
    print(f"Fault log: {FAULT_LOG_PATH}")
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
    """Describe the focused field without ever unwrapping its range attribute."""
    from ApplicationServices import (
        AXUIElementCreateSystemWide, AXUIElementCopyAttributeValue,
        AXIsProcessTrusted, kAXFocusedUIElementAttribute, kAXRoleAttribute,
        kAXSubroleAttribute, kAXValueAttribute, kAXSelectedTextRangeAttribute,
    )
    print("Trusted:", bool(AXIsProcessTrusted()))
    try:
        from Cocoa import NSWorkspace
        application = NSWorkspace.sharedWorkspace().frontmostApplication()
        print("Frontmost:", application.bundleIdentifier() if application else None)
    except Exception:
        pass
    for remaining in range(5, 0, -1):
        print(f"  focus the app to inspect... {remaining}", flush=True)
        time.sleep(1)
    system_element = AXUIElementCreateSystemWide()
    error, element = AXUIElementCopyAttributeValue(
        system_element, kAXFocusedUIElementAttribute, None)
    print("focused element error:", error, "element:", element)
    if error != 0 or element is None:
        return
    for attribute in (kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute,
                      kAXSelectedTextRangeAttribute):
        error, value = AXUIElementCopyAttributeValue(element, attribute, None)
        print(f"  {attribute}: error={error} type={type(value).__name__} "
              f"repr={str(value)[:80]!r}")


def selftest() -> None:
    # Rule-engine cases are evaluated with a CONFIRMED, non-synthetic buffer.
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
    reason_cases = [
        ("", "start"),
        ("   ", "start"),
        (" ( ", "start"),
        ("line\n  ", "linebreak"),
        ("Test. ", "ender"),
        ("etc. ", None),
        ("hello ", None),
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
    for text, expected in reason_cases:
        got = capitalize_reason(text)
        if got != expected:
            failures += 1
            print(f"FAIL reason {text!r}: expected {expected!r}, got {got!r}")
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

    # --- line-start trust --- #
    scenarios.append(("line start needs AX or an observed break",
                      can_trust_line_start(False, False, False) is False))
    scenarios.append(("line start trusted after a real Return",
                      can_trust_line_start(False, True, False) is True))
    scenarios.append(("line start trusted when AX confirms it",
                      can_trust_line_start(True, False, False) is True))
    scenarios.append(("synthetic buffer never claims a line start",
                      can_trust_line_start(True, True, True) is False))
    scenarios.append(("ender ignores the synthetic flag",
                      resolve_capitalization("Test. ", False, False, True) is True))
    scenarios.append(("break ignores the synthetic flag",
                      resolve_capitalization("a\n ", False, False, True) is True))

    # --- reported regression: TAB, DEL, DEL, SPACE --- #
    # TAB accepts a completion -> context invalidated -> neutral synthetic "x".
    shadow, synthetic = "x", True
    shadow = delete_backward(shadow)                   # DEL -> ""
    step1 = resolve_capitalization(shadow, False, False, synthetic)
    shadow = delete_backward(shadow)                   # DEL -> ""
    step2 = resolve_capitalization(shadow, False, False, synthetic)
    shadow = shadow + " "                              # SPACE -> " "
    step3 = resolve_capitalization(shadow, False, False, synthetic)
    scenarios.append(("TAB + DEL stays lowercase", step1 is False and step2 is False))
    scenarios.append(("TAB + DEL + DEL + SPACE stays lowercase", step3 is False))

    # Same laundering attempt with punctuation and several spaces.
    scenarios.append(("synthetic + spaces and quotes stays lowercase",
                      resolve_capitalization("  \u00ab ", False, False, True) is False))

    # And the legitimate path must still capitalize.
    scenarios.append(("confirmed empty field + SPACE capitalizes",
                      resolve_capitalization(" ", True, False, False) is True))

    # Blacklist / target filtering
    scenarios.append(("terminal blacklisted",
                      is_app_blacklisted("com.apple.Terminal") is True))
    scenarios.append(("unknown app allowed",
                      is_app_blacklisted("com.example.notes") is False))
    scenarios.append(("no bundle id is not blacklisted",
                      is_app_blacklisted(None) is False))
    scenarios.append(("text area editable",
                      is_editable_target("AXTextArea", None) is True))
    scenarios.append(("search field excluded",
                      is_editable_target("AXTextField", "AXSearchField") is False))
    scenarios.append(("secure field excluded",
                      is_editable_target("AXTextField", "AXSecureTextField") is False))
    scenarios.append(("button ignored",
                      is_editable_target("AXButton", None) is False))
    scenarios.append(("missing role ignored",
                      is_editable_target(None, None) is False))

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
    pending = resolve_capitalization(shadow, True, False, False)
    for char in text:
        if char.isalpha():
            produced += char.upper() if pending else char
            shadow += char
            pending = False
        else:
            produced += char
            shadow += char
            pending = resolve_capitalization(shadow, True, False, False)
        lagging_read = shadow[:-1]
        if not is_lagging_ax_read(shadow, lagging_read, 1):
            pending = resolve_capitalization(shadow, True, False, False)
    expected = "Plopo. Plopoplpo.      Ploplgfdg dfmglf dgdgfd dgdfg. Gdfgdfgdf.    Dfdffd"
    if produced != expected:
        print(f"FAIL scenario: fast typing -> {produced!r}")
        failures += 1

    for name, ok in scenarios:
        if not ok:
            failures += 1
            print(f"FAIL scenario: {name}")

    total = (len(rule_cases) + len(reason_cases) + len(buffer_cases)
             + len(scenarios) + 1)
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

    try:
        from ApplicationServices import kAXSubroleAttribute
    except Exception:
        kAXSubroleAttribute = "AXSubrole"

    # AXValueGetType is the only safe way to know what an AXValue wraps. Without
    # it, range unwrapping is disabled rather than risking a segfault.
    try:
        from ApplicationServices import AXValueGetType
    except Exception:
        AXValueGetType = None

    _install_crash_diagnostics()

    # ---- permission check with a distinct exit code ---- #
    trusted = False
    try:
        from ApplicationServices import (
            AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt)
        trusted = bool(AXIsProcessTrustedWithOptions(
            {kAXTrustedCheckOptionPrompt: False}))
    except Exception:
        try:
            trusted = bool(AXIsProcessTrusted())
        except Exception:
            trusted = False
    if not trusted:
        print("ERROR: Accessibility permission missing for:", _python_path(),
              file=sys.stderr)
        print("Enable it in System Settings > Privacy & Security > Accessibility.",
              file=sys.stderr)
        sys.exit(EXIT_NO_PERMISSION)

    KEY_RETURN, KEY_KP_ENTER, KEY_LINEFEED = 36, 76, 52
    KEY_TAB, KEY_ESCAPE, KEY_DELETE, KEY_FWD_DELETE = 48, 53, 51, 117
    KEY_Z, KEY_V, KEY_X, KEY_A, KEY_Y = 6, 9, 7, 0, 16
    RETURN_KEYS = {KEY_RETURN, KEY_KP_ENTER, KEY_LINEFEED}
    NAVIGATION = {123, 124, 125, 126, 115, 116, 119, 121}
    # Keys that never produce text and must not be mistaken for a dead key.
    NON_TEXT_KEYS = ({KEY_ESCAPE, KEY_TAB, KEY_DELETE, KEY_FWD_DELETE}
                     | RETURN_KEYS | NAVIGATION
                     | {96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109,
                        111, 113, 114, 118, 120, 122, 160, 177, 179})

    system_element = AXUIElementCreateSystemWide()

    state = {
        "shadow": "",
        "known": True,
        "synthetic": False,      # True when the buffer's left edge is fabricated
        "pending": False,
        "saw_line_break": False,
        "ax_ok": False,
        "ax_trusted": False,
        "ax_print": None,
        "ax_strikes": 0,
        "ax_frozen": False,
        "ax_selection": 0,
        "typed_since_ax": 0,
        "deleted_since_ax": 0,
        "keyboard_only": False,
        "guard_until": 0.0,
        "last_space_at": 0.0,
        "tab_lock": False,
        "retries": 0,
        "pointer_lost": False,
        "last_input": 0.0,
        "followup_at": 0.0,
        "verify_at": 0.0,
        "last_poll_at": 0.0,
        "last_trace": None,
        "unicode_probe": None,
        "composing": False,
        "composing_at": 0.0,
        "enabled": True,          # False inside a blacklisted app
        "editable": False,        # False when the focused element is not editable
        "bundle_id": None,
        "bundle_checked_at": 0.0,
        "tap_checked_at": 0.0,
        "observer_pid": None,
        "observer": None,
        "observer_source": None,
        "ax_dirty": True,
    }

    # ---- rule application ---- #
    def arm_from_shadow():
        """
        Recompute `pending`, applying the trust requirement on the "start of line"
        verdict. A synthetic buffer cannot produce one, so trailing spaces or
        punctuation can no longer launder an unknown context into a capital.
        """
        if state["tab_lock"] or not state["enabled"]:
            state["pending"] = False
            return
        if not state["known"]:
            return
        state["pending"] = resolve_capitalization(
            state["shadow"], state["ax_trusted"], state["saw_line_break"],
            state["synthetic"])

    def set_shadow(text: str, known: bool = True, synthetic=None):
        truncated = text[-SHADOW_SIZE:]
        state["shadow"] = truncated
        state["known"] = known
        if synthetic is not None:
            state["synthetic"] = bool(synthetic)
        if len(text) > SHADOW_SIZE:
            # The real beginning of the text was dropped: the left edge is lost.
            state["synthetic"] = True
        arm_from_shadow()

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
        state["saw_line_break"] = False
        state["ax_dirty"] = True
        now = time.monotonic()
        state["followup_at"] = now + delay
        state["verify_at"] = now + VERIFY_DELAY
        if pointer:
            state["pointer_lost"] = True
            state["keyboard_only"] = False
            state["synthetic"] = True
        reset_ax_tracking()

    def start_new_line():
        state["tab_lock"] = False
        state["retries"] = 0
        state["pointer_lost"] = False
        state["composing"] = False
        reset_ax_tracking()
        state["keyboard_only"] = True
        state["saw_line_break"] = True      # this process saw the Return itself
        set_shadow("", known=True, synthetic=False)
        now = time.monotonic()
        state["followup_at"] = now + FOLLOWUP_DELAY
        state["verify_at"] = now + VERIFY_DELAY

    # ---- AX helpers: timer / observer context ONLY, never inside the tap ---- #
    def ax_attribute(element, attribute):
        if element is None:
            return None
        try:
            error, value = AXUIElementCopyAttributeValue(element, attribute, None)
        except Exception:
            return None
        return value if error == 0 else None

    def frontmost_bundle():
        try:
            from Cocoa import NSWorkspace
            application = NSWorkspace.sharedWorkspace().frontmostApplication()
            if application is None:
                return None, None
            return application.bundleIdentifier(), application.processIdentifier()
        except Exception:
            return None, None

    def focused_element():
        error, element = AXUIElementCopyAttributeValue(
            system_element, kAXFocusedUIElementAttribute, None)
        if element is not None:
            return element
        _, pid = frontmost_bundle()
        if pid is None:
            return None
        try:
            app_element = AXUIElementCreateApplication(pid)
        except Exception:
            return None
        return ax_attribute(app_element, kAXFocusedUIElementAttribute)

    def read_range(element):
        """
        (caret, selection_length) or None when it cannot be determined SAFELY.
        Validated twice before AXValueGetValue: Python-side shape, then
        AXValueGetType() == kAXValueCFRangeType.
        """
        error, range_value = AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute, None)
        if range_value is None or not looks_like_ax_value(range_value):
            return None
        if AXValueGetType is None:
            return None
        try:
            if AXValueGetType(range_value) != kAXValueCFRangeType:
                return None
        except Exception:
            return None
        try:
            ok, cf_range = AXValueGetValue(range_value, kAXValueCFRangeType, None)
        except Exception:
            return None
        if not ok or cf_range is None:
            return None
        try:
            location = int(cf_range.location)
            length = int(cf_range.length)
        except Exception:
            return None
        if location < 0 or length < 0:
            return None
        return location, length

    def ax_read():
        element = focused_element()
        if element is None:
            state["editable"] = False
            return None

        role = ax_attribute(element, kAXRoleAttribute)
        subrole = ax_attribute(element, kAXSubroleAttribute)
        if not is_editable_target(role, subrole):
            state["editable"] = False
            return None
        state["editable"] = True

        value = ax_attribute(element, kAXValueAttribute)
        if not isinstance(value, str):
            count = ax_attribute(element, kAXNumberOfCharactersAttribute)
            if isinstance(count, int) and count == 0:
                state["ax_selection"] = 0
                return "", ax_fingerprint(0, 0, "")
            return None

        if value == "":
            state["ax_selection"] = 0
            return "", ax_fingerprint(0, 0, "")

        found = read_range(element)
        if found is None:
            return None
        caret, selection = found
        state["ax_selection"] = selection
        caret = max(0, min(caret, len(value)))
        before = value[:caret]
        return before, ax_fingerprint(len(value), caret, before)

    def refresh_from_context():
        # Frontmost application gate (cheap, cached for a fifth of a second).
        now = time.monotonic()
        if now - state["bundle_checked_at"] > 0.2:
            state["bundle_checked_at"] = now
            bundle_id, _ = frontmost_bundle()
            if bundle_id != state["bundle_id"]:
                state["bundle_id"] = bundle_id
                state["enabled"] = not is_app_blacklisted(bundle_id)
                if debug:
                    _log_line(f"[autocap] app={bundle_id} "
                              f"enabled={state['enabled']}")
        if not state["enabled"]:
            state["pending"] = False
            state["ax_ok"] = False
            return

        result = ax_read()
        if result is None:
            state["ax_ok"] = False
            if not state["editable"]:
                state["pending"] = False
            return
        before, fingerprint = result

        within_guard = state["known"] and time.monotonic() < state["guard_until"]

        if within_guard and is_lagging_ax_read(state["shadow"], before,
                    state["typed_since_ax"]):
            state["ax_ok"] = False
            if debug:
                _log_line(f"[autocap] lagging AX read ignored: {before[-24:]!r}")
            return

        if within_guard and is_predeletion_ax_read(state["shadow"], before,
                    state["deleted_since_ax"]):
            state["ax_ok"] = False
            if debug:
                _log_line(f"[autocap] pre-deletion AX read ignored: {before[-24:]!r}")
            return

        if is_stale_ax_read(state["ax_print"], fingerprint,
                    state["typed_since_ax"] + state["deleted_since_ax"]):
            state["ax_strikes"] += 1
            if state["ax_strikes"] >= STALE_STRIKES:
                state["ax_frozen"] = True
                state["ax_ok"] = False
                if not state["known"] and not state["pointer_lost"]:
                    state["known"] = True
                    arm_from_shadow()
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
        state["ax_dirty"] = False
        # The AX layer just supplied the whole text before the caret: the left
        # edge is real again.
        set_shadow(before, known=True, synthetic=False)
        if debug:
            trace = (state["shadow"][-24:], state["pending"])
            if trace != state["last_trace"]:
                state["last_trace"] = trace
                _log_line(f"[autocap] before={state['shadow'][-24:]!r} "
                          f"-> capitalize={state['pending']}")

    # ---- AXObserver: event-driven refresh, poll becomes a fallback ---- #
    def attach_observer():
        try:
            from ApplicationServices import (
                AXObserverCreate, AXObserverAddNotification,
                AXObserverGetRunLoopSource,
                kAXValueChangedNotification,
                kAXSelectedTextChangedNotification,
                kAXFocusedUIElementChangedNotification,
            )
        except Exception:
            return
        bundle_id, pid = frontmost_bundle()
        if pid is None or pid == state["observer_pid"]:
            return

        if state["observer_source"] is not None:
            try:
                Quartz.CFRunLoopRemoveSource(Quartz.CFRunLoopGetCurrent(),
                            state["observer_source"],
                            Quartz.kCFRunLoopDefaultMode)
            except Exception:
                pass
        state["observer"] = None
        state["observer_source"] = None
        state["observer_pid"] = pid

        if is_app_blacklisted(bundle_id):
            return

        def observer_callback(observer, element, notification, refcon):
            try:
                state["ax_dirty"] = True
                refresh_from_context()
            except BaseException:
                _log_callback_error("ax observer", debug)

        try:
            error, observer = AXObserverCreate(pid, observer_callback, None)
            if error != 0 or observer is None:
                return
            app_element = AXUIElementCreateApplication(pid)
            for notification in (kAXFocusedUIElementChangedNotification,
                                 kAXValueChangedNotification,
                                 kAXSelectedTextChangedNotification):
                try:
                    AXObserverAddNotification(observer, app_element,
                                notification, None)
                except Exception:
                    pass
            source = AXObserverGetRunLoopSource(observer)
            Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetCurrent(), source,
                        Quartz.kCFRunLoopDefaultMode)
            state["observer"] = observer
            state["observer_source"] = source
            _KEEP_ALIVE.append(observer)
            _KEEP_ALIVE.append(observer_callback)
            if debug:
                _log_line(f"[autocap] AX observer attached to pid {pid}")
        except Exception:
            _log_callback_error("observer setup", debug)

    # ---- keyboard payload ---- #
    def event_chars(event):
        """Unicode produced by a key event, or "" when it cannot be obtained."""
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
                state["saw_line_break"] = True
                state["synthetic"] = False   # an observed Return anchors the edge
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
            # Neutral placeholder: the left edge is invented, hence synthetic.
            set_shadow("x" + current, known=True, synthetic=True)
            state["pointer_lost"] = False
            state["keyboard_only"] = False
        else:
            set_shadow(current, known=not unknown)

    def capitalize_event(event, chars):
        first = chars[0]
        upper = first.upper()
        if upper == first or len(upper) != 1:
            return
        if CAPITALIZE_BY_SHIFT:
            try:
                flags = Quartz.CGEventGetFlags(event)
                Quartz.CGEventSetFlags(
                    event, flags | Quartz.kCGEventFlagMaskShift)
            except Exception:
                pass
            return
        try:
            replacement = upper + chars[1:]
            Quartz.CGEventKeyboardSetUnicodeString(
                event, len(replacement), replacement)
        except Exception:
            pass

    # ---- event tap callback: no AX, no blocking ---- #
    def callback(proxy, event_type, event, refcon):
        try:
            now = time.monotonic()
            state["last_input"] = now

            if event_type in (Quartz.kCGEventTapDisabledByTimeout,
                              Quartz.kCGEventTapDisabledByUserInput):
                Quartz.CGEventTapEnable(tap_holder[0], True)
                return event

            if event_type in (Quartz.kCGEventLeftMouseDown,
                              Quartz.kCGEventRightMouseDown,
                              Quartz.kCGEventOtherMouseDown,
                              Quartz.kCGEventLeftMouseUp,
                              Quartz.kCGEventScrollWheel):
                state["tab_lock"] = False
                state["composing"] = False
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

            if not state["enabled"]:
                state["pending"] = False
                return event

            if keycode in RETURN_KEYS:
                start_new_line()
                return event

            if keycode == KEY_DELETE:
                state["tab_lock"] = False
                state["composing"] = False
                state["last_space_at"] = 0.0
                # A pending selection means the deletion removes the selection,
                # not one character: the shadow cannot model that.
                if state["ax_selection"] > 0:
                    state["ax_selection"] = 0
                    invalidate(FOLLOWUP_DELAY, pointer=True)
                    state["pending"] = False
                    return event
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
                state["composing"] = False
                if state["ax_selection"] > 0:
                    state["ax_selection"] = 0
                    invalidate(FOLLOWUP_DELAY, pointer=True)
                    state["pending"] = False
                    return event
                note_edit(1, deletion=True)
                arm_from_shadow()
                if state["pending"] and not is_buffer_reliable(state["ax_trusted"],
                            state["keyboard_only"]):
                    state["pending"] = False
                return event

            if keycode == KEY_TAB:
                # TAB may indent, move focus, or ACCEPT AN INLINE COMPLETION
                # (Cotypist, IDEs). In the completion case the caret lands in the
                # middle of freshly inserted text, so the buffer is worthless and
                # its left edge is unknown: mark it synthetic (via pointer=True).
                state["tab_lock"] = True
                state["composing"] = False
                state["pending"] = False
                invalidate(FOLLOWUP_DELAY, pointer=True)
                return event

            if command and keycode in (KEY_Z, KEY_Y, KEY_V, KEY_X, KEY_A):
                state["tab_lock"] = False
                state["composing"] = False
                invalidate(FOLLOWUP_DELAY, pointer=True)
                return event

            if command or control:
                state["composing"] = False
                invalidate(FOLLOWUP_DELAY)
                return event

            if keycode == KEY_ESCAPE or keycode in NAVIGATION:
                state["tab_lock"] = False
                state["composing"] = False
                invalidate(FOLLOWUP_DELAY, pointer=True)
                return event

            chars = event_chars(event)

            if not chars:
                # A text-producing key that emits nothing is a dead key or the
                # start of an IME composition (Option-E, pinyin, kana...).
                if keycode not in NON_TEXT_KEYS:
                    state["composing"] = True
                    state["composing_at"] = now
                return event

            if state["composing"]:
                # Rewriting mid-composition corrupts the composed character:
                # accept it as-is and just keep the buffer in sync.
                if (now - state["composing_at"]) > COMPOSITION_TIMEOUT:
                    state["composing"] = False
                else:
                    state["tab_lock"] = False
                    state["composing"] = False
                    shadow_insert(chars, now)
                    state["pending"] = False
                    return event

            first = chars[0]

            if first.isalpha():
                if state["pending"] and not state["tab_lock"]:
                    capitalize_event(event, chars)
                state["tab_lock"] = False
                shadow_insert(chars, now)
                state["pending"] = False
                return event

            state["tab_lock"] = False
            shadow_insert(chars, now)
            return event
        except BaseException:
            # Nothing may cross back into CoreGraphics: an escaping exception
            # becomes an Objective-C exception and aborts the process.
            _log_callback_error("event tap", debug)
            return event

    # ---- tap setup, with a recreation path for the watchdog ---- #
    mask = (Quartz.CGEventMaskBit(Quartz.kCGEventKeyDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventLeftMouseUp)
            | Quartz.CGEventMaskBit(Quartz.kCGEventRightMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventOtherMouseDown)
            | Quartz.CGEventMaskBit(Quartz.kCGEventScrollWheel))

    tap_holder = [None]
    source_holder = [None]

    def create_tap() -> bool:
        new_tap = Quartz.CGEventTapCreate(
            Quartz.kCGSessionEventTap,
            Quartz.kCGHeadInsertEventTap,
            Quartz.kCGEventTapOptionDefault,
            mask,
            callback,
            None,
        )
        if new_tap is None:
            return False
        new_source = Quartz.CFMachPortCreateRunLoopSource(None, new_tap, 0)
        if new_source is None:
            return False
        if source_holder[0] is not None:
            try:
                Quartz.CFRunLoopRemoveSource(Quartz.CFRunLoopGetCurrent(),
                            source_holder[0], Quartz.kCFRunLoopCommonModes)
            except Exception:
                pass
        Quartz.CFRunLoopAddSource(Quartz.CFRunLoopGetCurrent(), new_source,
                    Quartz.kCFRunLoopCommonModes)
        Quartz.CGEventTapEnable(new_tap, True)
        tap_holder[0] = new_tap
        source_holder[0] = new_source
        _KEEP_ALIVE.append(new_tap)
        _KEEP_ALIVE.append(new_source)
        return True

    _KEEP_ALIVE.append(callback)
    if not create_tap():
        print("ERROR: could not create the event tap (missing Accessibility / "
              "Input Monitoring permission).", file=sys.stderr)
        sys.exit(EXIT_NO_TAP)

    # ---- fallback poller + watchdog, outside the tap ---- #
    def timer_callback(*args):
        try:
            now = time.monotonic()

            # Watchdog: macOS silently disables taps under load or on timeout.
            if now - state["tap_checked_at"] >= TAP_CHECK_INTERVAL:
                state["tap_checked_at"] = now
                try:
                    alive = bool(Quartz.CGEventTapIsEnabled(tap_holder[0]))
                except Exception:
                    alive = False
                if not alive:
                    try:
                        Quartz.CGEventTapEnable(tap_holder[0], True)
                        alive = bool(Quartz.CGEventTapIsEnabled(tap_holder[0]))
                    except Exception:
                        alive = False
                    if not alive:
                        if debug:
                            _log_line("[autocap] tap dead, recreating")
                        create_tap()
                attach_observer()

            forced = False
            if 0.0 < state["followup_at"] <= now:
                state["followup_at"] = 0.0
                forced = True
            if 0.0 < state["verify_at"] <= now:
                state["verify_at"] = 0.0
                forced = True
            if state["ax_dirty"]:
                forced = True

            idle = (now - state["last_input"]) > IDLE_AFTER
            if not forced:
                # With the AXObserver in place, routine polling is only a safety
                # net; it slows right down when nothing is happening or when the
                # focus is not on editable text.
                if idle or not state["editable"] or not state["enabled"]:
                    if (now - state["last_poll_at"]) < IDLE_POLL_INTERVAL:
                        return
            state["last_poll_at"] = now

            refresh_from_context()

            if not state["ax_ok"] and not state["known"]:
                if state["retries"] > 0:
                    state["retries"] -= 1
                    return
                if state["pointer_lost"]:
                    state["pointer_lost"] = False
                    state["keyboard_only"] = False
                    # Neutral, non-capitalizing fallback with a fabricated edge.
                    set_shadow("x", known=True, synthetic=True)
                else:
                    state["known"] = True
                    arm_from_shadow()
        except BaseException:
            _log_callback_error("poll", debug)

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
    # This observer is the code path that aborted an earlier build: a Python
    # exception raised here propagates out of the PyObjC closure, is rethrown as
    # an Objective-C exception inside NSNotificationCenter's dispatch, and kills
    # the process. The body is fully guarded and the selector is declared
    # explicitly (v@:@) so PyObjC never has to infer it.
    try:
        import objc
        from Cocoa import NSWorkspace, NSObject

        def _app_changed(self, notification):
            try:
                state["tab_lock"] = False
                state["composing"] = False
                state["bundle_checked_at"] = 0.0
                state["observer_pid"] = None
                invalidate(pointer=True)
            except BaseException:
                _log_callback_error("workspace observer", debug)

        WatcherClass = type(
            "AutocapWorkspaceWatcher",
            (NSObject,),
            {"appChanged_": objc.selector(_app_changed,
                    selector=b"appChanged:", signature=b"v@:@")},
        )
        watcher = WatcherClass.alloc().init()
        _KEEP_ALIVE.append(watcher)          # NSNotificationCenter does not retain

        notification_name = getattr(
            NSWorkspace, "NSWorkspaceDidActivateApplicationNotification", None)
        if notification_name is None:
            try:
                from Cocoa import NSWorkspaceDidActivateApplicationNotification \
                    as notification_name
            except Exception:
                notification_name = "NSWorkspaceDidActivateApplicationNotification"

        NSWorkspace.sharedWorkspace().notificationCenter() \
            .addObserver_selector_name_object_(
                watcher, b"appChanged:", notification_name, None)
    except Exception:
        if debug:
            _log_line("[autocap] workspace observer unavailable "
                      "(app switches detected by polling only).")

    # ---- clean shutdown so launchd's KeepAlive does not fight a zombie ---- #
    def stop(signum, frame):
        try:
            if tap_holder[0] is not None:
                Quartz.CGEventTapEnable(tap_holder[0], False)
        except Exception:
            pass
        try:
            Quartz.CFRunLoopStop(Quartz.CFRunLoopGetCurrent())
        except Exception:
            pass
        os._exit(0)

    for received in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        try:
            signal.signal(received, stop)
        except Exception:
            pass

    try:
        refresh_from_context()
    except Exception:
        pass

    if debug:
        _log_line("[autocap] running — type in any text field.")

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
