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

FIXED IN THIS REVISION (v20)
----
Two field reports, one cause each.

1. "Shift+Return creates a blank line above; typing on it stays lowercase."
   The caret is then at column 0 of a line whose left edge the buffer cannot
   prove, and "start" was accepted only with Accessibility confirmation. When
   that confirmation is missing or was wiped by the arrow key itself — the Up
   key went through the pointer branch, which flags the buffer as synthetic —
   no capital was armed. COLUMN ZERO IS OBSERVABLE, though: it is enough that
   the caret was at a line start (an observed Return, or a caret already at
   column 0) and that only VERTICAL navigation happened since. Vertical movement
   preserves the column, so column 0 stays column 0 whatever line it lands on,
   and the next letter still opens a line. That is the new "anchored" trust,
   independent of the Accessibility API. Horizontal navigation, a click, a
   deletion or any typed character drops the anchor again.

2. "1) or A) should be followed by a capital."
   A line-leading enumerator ("1)", "12)", "A)", "a)") now arms a capital like
   any other sentence opening. The dot form ("1.") is left alone: it is still
   governed by _is_false_sentence_end(), which treats numbered items and
   decimals as false sentence ends.

FIXED IN THIS REVISION (v20.1)
----
Two calls passed `pointer=True` without the required `delay` argument:

    invalidate(pointer=True)        # mouse down/up/scroll
    invalidate(pointer=True)        # application switch

`invalidate` takes `(delay, pointer=False)`, so both raised TypeError inside the
event tap. Every callback here ends in `except BaseException`, which is what keeps
an exception from aborting the process — the price is that the failure was
completely silent: clicks and application switches had stopped invalidating the
context since v19, and nothing said so. Both call sites now pass FOLLOWUP_DELAY.

static_call_problems() closes that class of defect: the selftest re-reads this
file and fails on any call that omits a required argument of a function defined
here, so `setup_all.sh` refuses the install instead of shipping a silently dead
feature. It was validated adversarially — a deliberately broken copy produced
seven findings.

FIXED IN THIS REVISION (v20.2)
----
The accessibility observer was never created, on any application:

    AXObserverCreate(pid, observer_callback, None)
    TypeError: Callable argument is not a PyObjC closure

AXObserverCreate stores the callback and calls it later, for every notification;
PyObjC only accepts a Python callable for such an argument when it has been told
which API the function belongs to. objc.callbackFor(AXObserverCreate) is the
documented declaration, and it was missing. The failure was invisible for the
same reason as the two calls in v20.1 — the surrounding try/except caught it and
only the obs_fail counter moved.

Consequence until now: every refresh came from the per-keystroke follow-up and
the safety poll, never from the observer. Expected gain now visible in --debug:
"AX observer attached to pid N" appears, observers/obs_fail in --stats move.

FIXED IN THIS REVISION (v20.3)
----
Notion (and rich editors in general) produced no capital at all, and the debug
log said nothing about why: a rejected role and an unreadable caret both end as
"no capital". Every failure of the target read now names its reason once, in
--debug:

    target rejected: role=... subrole=...
    target has no text value: role=... count=...
    target caret range unreadable: role=... text_len=...
    target absent

--axprobe was also unusable in practice: started from a terminal, that terminal
is the frontmost application, and its five-second countdown raced the user (two
consecutive runs reported only com.apple.Terminal, with the focused element
erroring out). It now WATCHES for twelve seconds and reports every distinct
frontmost application it sees — switching windows whenever is early enough — with
the role, the subrole, whether a text value and a caret range are readable, and
whether this daemon would accept the element.

static_call_problems() now rejects three classes instead of one — missing
required argument, call to a function defined inside another function, and too
many positional arguments. The second one is not hypothetical: this very
revision first called frontmost_bundle(), which lives inside run(), from the
module-level probe. Each class was validated against a deliberately broken copy
(7, 1 and 1 findings), and a healthy file reports zero.

FIXED IN THIS REVISION (v20.4)
----
The reason lines of v20.3 were debug-only, which forced the user to stop the
service, run --debug in the foreground, reproduce, then restart the service —
four steps for one answer. They are now written to the log file as well, always:
the volume is bounded by the once-per-change rule and the daemon already writes
that file. Answering "why no capital here?" is now: use the app normally, then
read the last target lines of the log.

FIXED IN THIS REVISION (v20.5)
----
The log now carries the three facts needed to explain a missing capital, at
bounded volume — exceptional or once-per-keycode, unlike a per-keystroke trace
which would flood the file:

    Return observed: line opened, next letter armed
    capital inserted before 'M' (raison=ender tape=0 app=…), and the decision
    itself, when the Accessibility read does complete:

        before='Une phrase.' -> capitalize=True tape=0

    `tape` is the provenance of the character before the caret: 1 when it was
    just typed (a glued dot then opens a token, e.g. "Test.com"), 0 when the caret
    arrived there by a deletion or a move (that dot closes a sentence, v20.9).
    key produced no characters: keycode=... (composition or dead key)

Field evidence that motivated them: in Notion the focused element IS an
AXTextArea and its text IS readable (text_len=310), but its caret range is not —
Chromium does not expose the insertion point there — so no rule can tell what
precedes the caret. Whether the capital was still armed (and never used) or never
armed at all was indistinguishable from the log. These three lines separate them.

FIXED IN THIS REVISION (v20.9)
----
"After deleting a sentence, the first letter of the next one is not capitalized
although a sentence end sits right before the caret; typing a space makes the
capital appear."

Two real causes.

1. A sentence end GLUED to the caret (nothing typed or skipped between them)
   armed nothing. That guard is not superfluous: typing "Test.com" or "3.14" goes
   through a moment where the dot sits immediately before the caret, and the next
   character belongs to the same token. But the guard also swallowed the
   legitimate case — a dot the user did NOT type, sitting before a caret that
   arrived there by deleting the text after it, closes a sentence, and the next
   letter opens the next one. PROVENANCE now decides: the state records whether
   the character before the caret was just typed, and only then does the
   separator requirement apply. The dotted-token protection is unchanged.

2. The arm demanded the Accessibility confirmation for EVERY verdict, although
   this file's own rule states that "start" is the only verdict resting on the
   buffer's LEFT EDGE. In Notion the caret range is unreadable, so the read never
   confirms and valid capitals were dropped after a deletion. A sentence end, a
   line break or an enumerator is read INSIDE the buffer the tap itself maintains,
   so they now arm as soon as the session is trustworthy — keyboard-only, or
   AX-confirmed (may_arm_from_shadow). A buffer that justifies nothing clears the
   arm whatever its trust state.

selftest 152 -> 163 cases.

FIXED IN THIS REVISION (v20.8)
----
"Shift+Return, then Up to the end of the sentence above, and the continuation
came out capitalized."

The column-zero anchor (v20) survives a vertical move on the argument that
vertical movement PRESERVES the column: a caret at column 0 lands at column 0 of
the neighbouring line. That holds for a column-preserving text view, and fails in
a block-based editor (Notion, Chromium/Electron): Up from the start of an empty
block puts the caret at the END of the block above. Armed blindly, the capital
then lands in the MIDDLE of an existing sentence — the report above, where that
sentence carried no ending punctuation, so nothing justified a capital.

The two families disagree and this process cannot tell them apart, but it DOES
hold the text of the line above: it was the current line before the break. The
anchor therefore survives an UP move only when that line is KNOWN EMPTY, where
both families land on column 0 and the capital is right. Otherwise the anchor is
dropped, the buffer takes that line's real text, and the ordinary rules decide.

The asymmetry settles it: a missing capital is an annoyance the user fixes by
typing it, whereas a capital inserted mid-sentence corrupts what he wrote.

Dropping the anchor writes one journal line, so "why no capital?" always has an
answer:

    Up from an opened line: the line above carries 21 char -> anchor dropped,
    capital only if that line ends a sentence (app=…)

selftest 147 -> 152 cases.

FIXED IN THIS REVISION (v20.7)
----
A real session's log showed that the two v20.5 traces were still unreachable in
practice, for three separate reasons.

1. The reason line was de-duplicated on its EXTRA field, which carries
   `text_len`. Typing lengthens the text, so a condition that never clears —
   Notion exposes the field and its text but never a caret range — printed one
   "caret range unreadable" line PER CHARACTER. The tail of that log was 25 such
   lines and nothing else; the lines that answer the question were buried. The
   identity of a condition is now (reason, role, subrole, application) and the
   volatile length is only printed, never compared: a persistent condition is
   ONE line, whatever the user types meanwhile.

2. Nothing proved the event tap receives keyboard events at all. "No Return
   observed" meant either "the daemon never saw the key" or "the key was seen and
   armed nothing" — the very ambiguity v20.5 set out to remove, one layer lower.
   The first keydown of each application now writes one line, and the minute
   statistics carry the keydown counter:

       keydown observed: app=notion.id enabled=1

   One line per application, never per keystroke. If typing in an application
   produces no such line, the tap is blind there: that is permission, not rules.

3. A callback that raised was reported only under --debug, so a tap failing on
   EVERY keystroke looked exactly like a daemon receiving none — the same
   silence, in the one place that cannot afford it. Failures are now always
   written, deduplicated on the traceback: one line per distinct failure, not
   one per keystroke.

4. Nothing checked the state dictionary's own names. Every entry is read by
   name, and the entries added here are read inside the tap callback: a typo
   would fail on a keystroke and — now that callback failures are logged rather
   than fatal — would live only in that log. The selftest now rejects any
   state["…"] name run() never initialised, and validates that detector against
   a deliberately broken miniature, exactly like the call guard of v20.1.

FIXED IN THIS REVISION (v20.6)
----
The v20.5 reason lines repeated on every poll instead of once per change: the
"seen" memory was cleared as soon as the element's role was accepted, before the
read that actually fails. It is now cleared only by a read that completes, so a
persistent condition is reported once — which is what makes the log worth reading
(one line per change, not one per 250 ms).

MEMORY (this revision)
----
The daemon used to grow without bound: several hundred megabytes after a few
days of use, on an 8 GB Mac. Three causes, all addressed here.

1. The Accessibility API was read on every 20 ms tick, fifty times a second,
   around the clock, as long as an editable field had the focus. That read
   copies the whole text of the field and allocates one CoreFoundation object
   per attribute, so it was both the heaviest operation and the main source of
   memory churn. Reads are now gated by needs_ax_poll(): every keystroke already
   arms a follow-up 12 ms later and the AX observer reports value changes, so
   the timer is only a slow safety net — a quarter of a second while a field has
   the focus, one second when there is nothing to watch. Measured on the same
   keystroke scenario: 6.8x to 10.4x fewer reads.

2. A replaced AX observer was never torn down. The notifications stayed
   registered on the target process, the run-loop source was never invalidated,
   and the objects stayed referenced forever by _KEEP_ALIVE: one live observer
   and its mach connection leaked per application switch. detach_observer() now
   removes the notifications, invalidates the source and releases the objects
   before attaching the next one.

3. A recreated event tap was never disabled, so every watchdog recreation leaked
   a tap and its mach port. create_tap() now disables and invalidates the
   previous tap before building the new one.

On top of that the daemon measures itself: resident size, AX read count, kept
objects, tap and observer builds, edits — one line per minute in
~/Library/Logs/autocapitalize-stats.log, readable with --stats. If the resident
size stays above MEMORY_CEILING for MEMORY_STRIKES consecutive samples it
restarts itself in place (os.execv: same binary, so the Accessibility grant
survives), and launchd's KeepAlive covers a failed restart.

MEMORY, SECOND PASS (v19)
----
The first version of the gating was measured in the field and it did not hold:
3000 AX calls a minute with the text-read counter frozen, i.e. the 50 Hz poll
still running.

Cause: refresh_from_context() has several exits that bail out before the text
is read at all — no editable field focused being the common one. Those exits
left `ax_dirty` set, and `ax_dirty` is what forces an immediate read, so the
timer considered every 20 ms tick an event and read the API again. The flag is
now consumed on entry to refresh_from_context(), whatever exit is taken.

Measured with the same keystroke/rest scenarios: 3000 -> 60 reads a minute when
nothing is focused, 461 -> 74 with a field focused, 923 -> 110 while typing.

The observer that never attaches (observers=0 in the field log) is now counted
as obs_fail in the stats, so the reason shows up without a debug session.

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
    python3 autocapitalize.py --stats
    python3 autocapitalize.py --axprobe
"""

import os
import sys
import time
import signal
import ast
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

# --- memory diagnostics and recycling --- #
# The daemon reads the Accessibility API for the field text; that read copies
# the whole field and creates CF objects, so it is now gated by needs_ax_poll()
# and its cost is measurable. The stats file is the evidence trail.
STATS_LOG = os.environ.get("HOME", "") + "/Library/Logs/autocapitalize-stats.log"
STATS_INTERVAL = 60.0
STATS_MAX_BYTES = 200000
STATS_KEEP_LINES = 500
MEMORY_CEILING = 220.0     # resident size, in megabytes, that is too high
MEMORY_STRIKES = 3         # consecutive samples over the ceiling before recycling
IDLE_REPOLL = 0.250        # safety poll while an editable field has focus
IDLE_SLOW = 1.000          # safety poll when there is nothing to watch

# False -> rewrite the event's Unicode payload (most reliable).
# True  -> keep the original event and add the Shift modifier (undo-friendly).
CAPITALIZE_BY_SHIFT = False

# CoreFoundation / Objective-C objects referenced by raw pointers on the C side.
# Collecting any of them would make the next callout dereference freed memory.
_KEEP_ALIVE = []


_REPORTED_CALLBACK_ERRORS: set = set()


def _log_line(message: str) -> None:
    try:
        print(message, flush=True)
    except Exception:
        pass


def callback_error_key(where: str, trace: str) -> tuple:
    """
    Identity of a callback failure: same place, same traceback, same line.

    A tap callback that raises runs again on the next keystroke, so reporting
    has to collapse repeats without ever hiding a DIFFERENT failure.
    """
    return (str(where), str(trace).strip()[-600:])


def _log_callback_error(where: str) -> None:
    """
    Last line of defence for callbacks invoked from Objective-C.

    An exception escaping a PyObjC closure is re-raised as an Objective-C
    exception; AppKit's dispatch code does not catch it and the process aborts
    with SIGABRT. Every callback therefore ends in a bare except calling this.

    Written ALWAYS, not only under --debug (v20.7). The daemon runs as a
    service, so a callback raising on every keystroke was indistinguishable from
    a daemon that never received a keystroke: the tap's own failures were the one
    failure the log could not show. Deduplicated on the traceback, so a
    per-keystroke crash costs one line instead of thousands.
    """
    try:
        trace = traceback.format_exc()
    except Exception:
        trace = ""
    signature = callback_error_key(where, trace)
    if signature in _REPORTED_CALLBACK_ERRORS:
        return
    _REPORTED_CALLBACK_ERRORS.add(signature)
    try:
        _log_line(f"[autocap] {where} error (first occurrence; identical "
                  f"repeats are not logged):\n{trace}")
    except Exception:
        pass


def state_key_problems(path: str, source: str = "") -> list:
    """
    state["..."] names that run() never initialised in its state dictionary.

    The state dict is the tap's whole memory, and every entry is read and
    written by name. A typo there is invisible until the exact moment the name
    is used — inside the event-tap callback, that is, on a keystroke — and since
    v20.7 a failing callback is logged instead of fatal, so the mistake would
    live only in a log nobody is reading. Checking the names statically turns it
    into a selftest failure. `source` overrides the file so the check itself can
    be validated against deliberately broken text.
    """
    try:
        text = source if source else open(path).read()
        tree = ast.parse(text)
    except Exception:
        return ["source could not be parsed"]
    declared = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef) or node.name != "run":
            continue
        for inner in ast.walk(node):
            if not isinstance(inner, ast.Assign):
                continue
            if not isinstance(inner.value, ast.Dict):
                continue
            names = [target for target in inner.targets
                     if isinstance(target, ast.Name) and target.id == "state"]
            if not names:
                continue
            for entry in inner.value.keys:
                if isinstance(entry, ast.Constant) and isinstance(entry.value, str):
                    declared.add(entry.value)
    if not declared:
        return ["no state dictionary found in run()"]
    problems = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Subscript):
            continue
        if not isinstance(node.value, ast.Name) or node.value.id != "state":
            continue
        if not isinstance(node.slice, ast.Constant):
            continue
        name = node.slice.value
        if isinstance(name, str) and name not in declared:
            problems.append(f"state[{name!r}] line {node.lineno} is never "
                            f"initialised")
    return problems


def static_call_problems(path: str) -> list:
    """
    Calls that omit a required argument, and calls that reach a name the calling
    scope cannot see.

    Every callback here ends in `except BaseException`: an exception escaping into
    Objective-C aborts the process, so a wrong call is swallowed and the feature
    simply stops working, with no trace unless --debug is on. That is how
    `invalidate(pointer=True)` — missing its `delay` — killed the click and
    application-switch invalidation between v19 and v20.1 without anyone seeing it.

    The second check exists because the first one missed the real defect it was
    written for: `frontmost_bundle()` is defined inside run(), and a module-level
    caller referencing it is a NameError that no arity check can see.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            tree = ast.parse(handle.read())
    except Exception:
        return []

    signatures = {}
    enclosing = {}
    variadic = {}
    positional_count = {}

    def collect(node, parent):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                positional = list(child.args.posonlyargs) + list(child.args.args)
                positional_count[child.name] = len(positional)
                if child.args.defaults:
                    positional = positional[:len(positional) - len(child.args.defaults)]
                signatures[child.name] = [argument.arg for argument in positional]
                variadic[child.name] = (child.args.vararg is not None
                                        or child.args.kwarg is not None)
                enclosing[child.name] = parent
                collect(child, child.name)
            else:
                collect(child, parent)

    collect(tree, None)

    problems = []

    def check_calls(node, chain):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                check_calls(child, chain | {child.name})
                continue
            if isinstance(child, ast.Call) and isinstance(child.func, ast.Name):
                name = child.func.id
                if name in signatures:
                    needed = signatures[name]
                    if needed:
                        supplied = {keyword.arg for keyword in child.keywords
                                    if keyword.arg}
                        for index, parameter in enumerate(needed):
                            if index >= len(child.args) and parameter not in supplied:
                                problems.append(
                                    f"line {child.lineno}: {name}() without "
                                    f"{parameter}")
                    accepts_more = variadic.get(name, False)
                    allowed = positional_count.get(name, 0)
                    if (not accepts_more and len(child.args) > allowed
                            and not any(keyword.arg is None
                                        for keyword in child.keywords)):
                        problems.append(
                            f"line {child.lineno}: {name}() accepts {allowed} "
                            f"positional arguments, {len(child.args)} given")
                    owner = enclosing.get(name)
                    if owner is not None and owner not in chain:
                        problems.append(
                            f"line {child.lineno}: {name}() is defined inside "
                            f"{owner}() and is not visible from here")
            check_calls(child, chain)

    check_calls(tree, frozenset())
    return problems


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


def _line_head(text: str) -> str:
    """Everything on the caret's line, i.e. after the last line break."""
    index = -1
    for position, char in enumerate(text):
        if char in LINE_BREAKS:
            index = position
    return text[index + 1:]


def _is_enumerator_head(head: str) -> bool:
    """True for "1)", "12)", "A)", "a)" — leading and trailing spaces allowed."""
    body = head.strip(" \t")
    if len(body) < 2 or not body.endswith(")"):
        return False
    marker = body[:-1]
    if marker.isdigit():
        return len(marker) <= 3
    return len(marker) == 1 and marker.isalpha()


def enumerator_reason(before_caret: str):
    """
    "enumerator" when the caret sits right after a line-leading list marker.

    Only the head of the caret's line is examined: a "1)" in the middle of a
    sentence is punctuation, not an enumeration. Unlike "start" this verdict
    does not depend on the left edge of the buffer — the marker is short and
    self-delimiting, so a truncated or fabricated edge cannot produce it by
    accident (the cut would have to fall exactly on the marker).
    """
    if _is_enumerator_head(_line_head(before_caret)):
        return "enumerator"
    return None


def step_line_back(text: str) -> str:
    """
    The text before the caret once it moved to column 0 of the previous line.

    The buffer ends with the break that opened the line the caret is leaving, so
    that last break comes off first; what remains is everything up to and
    including the break before the previous line. No break left means the caret
    is now on the first line, with nothing before it.
    """
    end = len(text)
    if end > 0 and text[end - 1] in LINE_BREAKS:
        end -= 1
    index = -1
    for position in range(end):
        if text[position] in LINE_BREAKS:
            index = position
    return text[:index + 1] if index >= 0 else ""


def capitalize_reason(before_caret: str, typed_glued: bool = True):
    """
    Why the next letter should be uppercased, or None.

    `typed_glued` says whether the character immediately before the caret was
    TYPED in this run. It only changes one verdict: a sentence end glued to the
    caret (nothing typed or skipped between them). Just typed, that dot opens a
    token ("Test.com") and must not arm; reached by a deletion or a move, it
    closes a sentence and must arm.

    The default is True: a caller that cannot tell assumes the historic
    behaviour, where the separator requirement applies. The tap's state knows the
    provenance and passes it explicitly.

      "enumerator" a line-leading list marker ("1)", "A)") was found
      "start"      the backwards scan consumed the whole buffer
      "linebreak"  a hard line break was found
      "ender"      a sentence-ending mark was found, with a separator after it

    The distinction matters: "start" is the ONLY reason that depends on the left
    edge of the buffer, so it is the only one that needs external confirmation
    before it may arm a capital.
    """
    if enumerator_reason(before_caret) is not None:
        return "enumerator"

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
        if not (skipped_space or skipped_punctuation) and typed_glued:
            # A sentence end GLUED to the caret whose character was just typed:
            # that dot opens a token, it does not close a sentence ("Test.com",
            # "3.14", "v2.1", "192.168.1.1"). The separator requirement exists for
            # exactly that case and must stay.
            return None
        # The same glued dot must ARM when the caret did not arrive there by
        # typing — text deleted after it, or the caret moved onto it. Measured
        # 2026-09-24: after deleting a sentence, the first letter of the next one
        # was not capitalized although a sentence end sat right before the caret,
        # and typing a space made the capital appear.
        return None if _is_false_sentence_end(before_caret, index) else "ender"
    return None


def should_capitalize(before_caret: str, typed_glued: bool = True) -> bool:
    """True when the next letter typed must be uppercased (rule only)."""
    return capitalize_reason(before_caret, typed_glued) is not None


def can_trust_line_start(ax_trusted: bool, saw_line_break: bool,
            synthetic: bool, anchored: bool = False) -> bool:
    """
    Whether a "start of text/line" verdict may be believed.

    It is the strongest reason to capitalize and therefore the one that must never
    be assumed. A synthetic buffer — one whose left edge was fabricated (the "x"
    fallback after a pointer event or a TAB completion) or lost (truncated at
    SHADOW_SIZE) — can never claim it, no matter how many spaces or punctuation
    marks trail behind the caret. That laundering is exactly what turned
    "TAB, DEL, DEL, SPACE" into a spurious capital.

    `anchored` is a third, independent source: this process knows the caret sits
    at COLUMN ZERO of its line, because it saw the Return that opened the line or
    because only vertical navigation happened since. Column zero is a property of
    the caret, not of the buffer's left edge, so it holds whatever the buffer
    looks like — that is what makes a blank line usable on a web view, where the
    Accessibility API may never confirm anything.
    """
    if anchored:
        return True
    if synthetic:
        return False
    return bool(ax_trusted or saw_line_break)


def anchor_survives_vertical(line_above: str) -> bool:
    """
    Does the column-zero anchor survive an UP move?

    Only when the line above is KNOWN EMPTY, i.e. a second break with nothing
    typed in between: both editor families then put the caret on that line's
    column 0, and the capital is right.

    When the line above carries text, the two families disagree. A
    column-preserving text view lands the caret on that line's FIRST character,
    while a block-based editor (Notion, Electron/Chromium) sends it to the END of
    the previous block. Arming blindly then writes a capital in the MIDDLE of an
    existing sentence — field report of 2026-09-24: a sentence with no ending
    punctuation, Shift+Return, then Up to the end of the line above, and the
    continuation of the sentence came out capitalized.

    The asymmetry decides: a missing capital is a small annoyance the user fixes
    by typing it himself, whereas a capital inserted mid-sentence corrupts the
    text. The anchor therefore only survives the case this process can PROVE.
    """
    return line_above == ""


def resolve_capitalization(before_caret: str, ax_trusted: bool,
            saw_line_break: bool, synthetic: bool,
            anchored: bool = False, typed_glued: bool = True) -> bool:
    """Full decision: rule engine plus the trust requirement on "start"."""
    reason = capitalize_reason(before_caret, typed_glued)
    if reason is None:
        return False
    if reason == "start" and not can_trust_line_start(
            ax_trusted, saw_line_break, synthetic, anchored):
        return False
    return True


def may_arm_from_shadow(reason, known: bool, reliable: bool) -> bool:
    """
    May this verdict arm a capital from the LOCAL buffer?

    "start" is the only verdict that rests on the buffer's LEFT EDGE, so it waits
    for a confirmed buffer (unchanged). A sentence end, a line break or an
    enumerator is read INSIDE the buffer the tap itself maintains, and discarding
    those because the Accessibility read has not confirmed the field — it never
    does in Notion, whose caret range is unreadable — silently dropped valid
    capitals after a deletion (measured 2026-09-24). They are therefore accepted
    as soon as the session is trustworthy: keyboard-only, or AX-confirmed.
    """
    if reason is None:
        return False
    if reason == "start":
        return bool(known)
    return bool(known or reliable)


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


def ax_floor(idle: bool, editable: bool, enabled: bool) -> float:
    """
    Minimum interval between two safety reads.

    A quarter of a second while an editable field holds the focus — the AX
    observer and the per-keystroke follow-up cover real changes anyway — and one
    second when there is nothing to watch: blacklisted app, no editable field,
    or no input for a while.
    """
    if enabled and editable and not idle:
        return IDLE_REPOLL
    return IDLE_SLOW


def target_report_key(reason: str, role, subrole, bundle_id) -> tuple:
    """
    Identity of a persistent target condition, for the once-per-condition rule.

    `extra` (the text length at the moment of the report) is deliberately NOT
    part of it: typing lengthens the text, so comparing it made a condition that
    never clears — a field whose caret range stays unreadable — print one line
    per character typed. The deduplication keys on the condition and the
    application instead, and the length is still printed in the single line.
    """
    return (str(reason), str(role), str(subrole), str(bundle_id))


def keydown_liveness_needed(bundle_id, reported_bundle) -> bool:
    """
    Whether this keydown must produce the "tap is alive here" line.

    One line per application, never per keystroke: it answers the only question
    the keystroke traces cannot — does the event tap receive keyboard events at
    all in this application? — while keeping a readable log. No bundle is known
    yet on the first keydowns: the run-loop refresh fills it in within a fifth
    of a second, and the next keydown reports.
    """
    if not bundle_id:
        return False
    return str(bundle_id) != str(reported_bundle)


def needs_ax_poll(forced: bool, idle: bool, editable: bool, enabled: bool,
        since_last: float) -> bool:
    """
    Whether the fallback timer may read the Accessibility API right now.

    That read is the daemon's heaviest operation: it copies the whole text of
    the field and allocates one CF object per attribute. Polling it at 50 Hz
    around the clock was needless work and the most likely source of the
    resident-size creep, so a read now happens only when something moved:

      * `forced`  a keystroke is being followed up, or the AX observer reported
                  a change — this is what keeps typing instant
      * otherwise a single safety poll per ax_floor() interval
    """
    if forced:
        return True
    return since_last >= ax_floor(idle, editable, enabled)


def needs_recycle(samples_over: int, limit: int = MEMORY_STRIKES) -> bool:
    """True once the resident size stayed over the ceiling for `limit` samples."""
    return samples_over >= limit


def resident() -> float:
    """Resident size of this process, in megabytes (0.0 when unreadable)."""
    try:
        result = subprocess.run(["ps", "-o", "rss=", "-p", str(os.getpid())],
                    capture_output=True, text=True, timeout=2)
        return int(result.stdout.strip() or 0) / 1024.0
    except Exception:
        try:
            import resource
            peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
            return peak / 1048576.0 if sys.platform == "darwin" else peak / 1024.0
        except Exception:
            return 0.0


def append_stats(line: str) -> None:
    """Append one line to the stats file, trimming it when it grows too big."""
    try:
        with open(STATS_LOG, "a") as handle:
            handle.write(line + "\n")
            oversized = handle.tell() > STATS_MAX_BYTES
    except Exception:
        return
    if not oversized:
        return
    try:
        with open(STATS_LOG) as handle:
            tail = handle.readlines()[-STATS_KEEP_LINES:]
        with open(STATS_LOG, "w") as handle:
            handle.writelines(tail)
    except Exception:
        pass


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
    """
    Describe the focused field of every application that comes to the front.

    A probe started from a terminal cannot inspect itself: that terminal is the
    frontmost application at launch, and a countdown races the user. It therefore
    WATCHES for twelve seconds and reports each distinct frontmost application it
    sees — switching to the window to inspect is enough, whenever it happens.

    For each one it prints the role, the subrole, whether a text value and a
    caret range are readable, and whether this daemon would accept the element.
    """
    from ApplicationServices import (
        AXUIElementCreateSystemWide, AXUIElementCopyAttributeValue,
        AXIsProcessTrusted, kAXFocusedUIElementAttribute, kAXRoleAttribute,
        kAXSubroleAttribute, kAXValueAttribute, kAXSelectedTextRangeAttribute,
    )
    print("Trusted:", bool(AXIsProcessTrusted()))
    print("Switch to the window to inspect — watching for 12 seconds.")

    def current_bundle():
        """Frontmost application, read here rather than from the daemon's scope."""
        try:
            from Cocoa import NSWorkspace
            application = NSWorkspace.sharedWorkspace().frontmostApplication()
            return application.bundleIdentifier() if application else None
        except Exception:
            return None

    system_element = AXUIElementCreateSystemWide()
    seen = set()
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        bundle_id = current_bundle()
        if bundle_id and bundle_id not in seen:
            seen.add(bundle_id)
            print(f"\n== {bundle_id}")
            error, element = AXUIElementCopyAttributeValue(
                system_element, kAXFocusedUIElementAttribute, None)
            if error != 0 or element is None:
                print(f"   focused element: error={error} (nothing to read)")
            else:
                _err, role = AXUIElementCopyAttributeValue(
                    element, kAXRoleAttribute, None)
                _err, subrole = AXUIElementCopyAttributeValue(
                    element, kAXSubroleAttribute, None)
                value_error, value = AXUIElementCopyAttributeValue(
                    element, kAXValueAttribute, None)
                range_error, text_range = AXUIElementCopyAttributeValue(
                    element, kAXSelectedTextRangeAttribute, None)
                length = len(value) if isinstance(value, str) else "-"
                print(f"   role={role} subrole={subrole}")
                print(f"   text value : error={value_error} "
                      f"type={type(value).__name__} length={length}")
                print(f"   caret range: error={range_error} "
                      f"type={type(text_range).__name__}")
                print("   accepted by the daemon: "
                      f"{is_editable_target(role, subrole)}")
        time.sleep(0.25)
    if not seen:
        print("No frontmost application detected.")


def stats_report() -> None:
    """Print the memory samples recorded by the running daemon."""
    print(f"Stats file: {STATS_LOG}")
    try:
        with open(STATS_LOG) as handle:
            lines = handle.readlines()
    except Exception:
        print("No samples yet: the daemon writes one line per minute.")
        return
    for line in lines[-40:]:
        print(line.rstrip())


def selftest() -> None:
    import contextlib
    import io

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
        ("1) ", True),
        ("12) ", True),
        ("1)", True),
        ("A) ", True),
        ("a) ", True),
        ("A)", True),
        (" 1) ", True),
        ("1.5) ", False),
        ("1234) ", False),
        ("AB) ", False),
        ("(1) ", False),
        ("Bonjour 1) ", False),
        ("line1\n1) ", True),
        ("line1\nA) ", True),
        ("x1) ", False),
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
        ("1) ", "enumerator"),
        ("A) ", "enumerator"),
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
        (step_line_back, "line1\nline2\n", "line1\n"),
        (step_line_back, "line1\n", ""),
        (step_line_back, "abc", ""),
        (step_line_back, "", ""),
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

    # --- column-zero anchor: the blank line after Shift+Return --- #
    scenarios.append(("anchor alone capitalizes a blank line",
                      resolve_capitalization("", False, False, True, True) is True))
    scenarios.append(("blank line stays lowercase without an anchor",
                      resolve_capitalization("", False, False, True, False) is False))
    scenarios.append(("an anchored caret still capitalizes, whatever the buffer edge",
                      resolve_capitalization(step_line_back("line1\nline2\n"),
                                             False, False, True, True) is True))
    scenarios.append(("anchor survives a synthetic buffer edge",
                      can_trust_line_start(False, False, True, True) is True))
    scenarios.append(("no anchor still refuses a synthetic line start",
                      can_trust_line_start(False, False, True, False) is False))
    scenarios.append(("enumerator ignores the synthetic flag",
                      resolve_capitalization("1) ", False, False, True, False) is True))
    scenarios.append(("enumerator ignores the buffer edge",
                      resolve_capitalization("A) ", False, False, True, True) is True))

    # --- v20.8: the anchor only survives a vertical move it can PROVE --- #
    scenarios.append(("anchor survives an UP move into an empty line above",
                      anchor_survives_vertical("") is True))
    scenarios.append(("anchor falls when the line above carries text",
                      anchor_survives_vertical("une phrase sans point") is False))
    scenarios.append(("no capital after UP into a text line (reported 2026-09-24)",
                      resolve_capitalization("une phrase sans point", False, False, True,
                                             anchor_survives_vertical("une phrase sans point")) is False))
    scenarios.append(("a line above holding only a space is not empty",
                      anchor_survives_vertical(" ") is False))
    scenarios.append(("a sentence end followed by a space still capitalizes after UP",
                      resolve_capitalization("Fin de phrase. ", False, False, True,
                                             anchor_survives_vertical("Fin de phrase. ")) is True))

    # --- v20.9: a sentence end glued to the caret, judged by PROVENANCE --- #
    scenarios.append(("a glued sentence end arms a capital after a deletion",
                      resolve_capitalization("Une phrase.", False, False, True,
                                             False, False) is True))
    scenarios.append(("the same glued dot does NOT arm when it was just typed",
                      resolve_capitalization("Une phrase.", False, False, True,
                                             False, True) is False))
    scenarios.append(("a domain in progress stays lowercase (Test.)",
                      resolve_capitalization("Test.", False, False, True,
                                             False, True) is False))
    scenarios.append(("a number in progress stays lowercase (2.)",
                      resolve_capitalization("2.", False, False, True,
                                             False, True) is False))
    scenarios.append(("an abbreviation glued after a deletion stays lowercase",
                      resolve_capitalization("cf.", False, False, True,
                                             False, False) is False))
    scenarios.append(("a sentence end followed by a space arms either way",
                      resolve_capitalization("Une phrase. ", False, False, True,
                                             False, True) is True))

    # --- v20.9: only "start" waits for the Accessibility confirmation --- #
    scenarios.append(("start waits for a confirmed buffer",
                      may_arm_from_shadow("start", False, True) is False))
    scenarios.append(("start still arms on a confirmed buffer",
                      may_arm_from_shadow("start", True, False) is True))
    scenarios.append(("an ender arms on a keyboard-only session",
                      may_arm_from_shadow("ender", False, True) is True))
    scenarios.append(("an ender does NOT arm on an unconfirmed pointer session",
                      may_arm_from_shadow("ender", False, False) is False))
    scenarios.append(("no verdict never arms",
                      may_arm_from_shadow(None, True, True) is False))

    # --- static guard: a swallowed TypeError is invisible --- #
    problems = static_call_problems(os.path.abspath(__file__))
    if problems:
        for problem in problems:
            print(f"FAIL static {problem}")
    scenarios.append(("no call misses a required argument", not problems))

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

    # --- v20.7: a persistent reason is ONE line, and the tap proves itself --- #
    condition = target_report_key("caret range unreadable", "AXTextArea", None,
                                  "com.example.notes")
    scenarios.append(("a persistent reason keeps one identity while typing",
                      condition == target_report_key("caret range unreadable",
                                                     "AXTextArea", None,
                                                     "com.example.notes")))
    scenarios.append(("the same reason in another application is a new line",
                      condition != target_report_key("caret range unreadable",
                                                     "AXTextArea", None,
                                                     "com.example.mail")))
    scenarios.append(("another reason is a new line",
                      condition != target_report_key("target rejected",
                                                     "AXButton", None,
                                                     "com.example.notes")))
    scenarios.append(("a repeated callback failure stays on one line",
                      (callback_error_key("event tap", "Traceback\n  a\n")
                       == callback_error_key("event tap", "Traceback\n  a\n"))))
    scenarios.append(("a different callback failure is still reported",
                      (callback_error_key("event tap", "Traceback\n  a\n")
                       != callback_error_key("event tap", "Traceback\n  b\n"))))
    scenarios.append(("the tap proves itself once per application",
                      (keydown_liveness_needed("com.example.notes", None) is True
                       and keydown_liveness_needed("com.example.notes",
                                                   "com.example.notes") is False)))
    scenarios.append(("no known application, no liveness line",
                      keydown_liveness_needed(None, None) is False))

    # The failure reporter must WORK when it is called, not merely compile: it
    # is the last line of defence, so a broken one would only be discovered
    # during the crash it was meant to explain. Written twice on purpose — the
    # second call must be silent.
    quiet = io.StringIO()
    try:
        raise RuntimeError("selftest: deliberate failure for the reporter check")
    except RuntimeError:
        with contextlib.redirect_stdout(quiet):
            _log_callback_error("selftest")
            _log_callback_error("selftest")
    scenarios.append(("a callback failure is written once",
                      quiet.getvalue().count("error (first occurrence") == 1))

    # --- static guard: an uninitialised state name fails only on a keystroke --- #
    own_path = os.path.abspath(__file__)
    with open(own_path) as handle:
        own_source = handle.read()
    state_problems = state_key_problems(own_path)
    if state_problems:
        for problem in state_problems:
            print(f"FAIL state {problem}")
    scenarios.append(("every state name is initialised", not state_problems))
    # Validated on a deliberately broken miniature, like the call guard above:
    # one declared name used correctly, one used without being declared. The
    # miniature is self-contained on purpose — any needle taken from this file
    # would also appear in this very test and lose its uniqueness.
    broken_source = ('def run():\n'
                     '    state = {"seen": 0}\n'
                     '    state["seen"] += 1\n'
                     '    state["nevver"] = 1\n')
    scenarios.append(("the state guard catches a typo",
                      len(state_key_problems(own_path, broken_source)) == 1))
    scenarios.append(("the state guard clears a correct dictionary",
                      state_key_problems(
                          own_path,
                          broken_source.replace('state["nevver"]',
                                                'state["seen"]')) == []))

    # --- memory: the AX read is gated behind events --- #
    scenarios.append(("no AX read while nothing happens",
                      needs_ax_poll(False, False, True, True, 0.05) is False))
    scenarios.append(("focused field polls at the quarter-second floor",
                      needs_ax_poll(False, False, True, True, IDLE_REPOLL) is True))
    scenarios.append(("nothing focused polls at the slow floor",
                      (needs_ax_poll(False, False, False, True, IDLE_REPOLL) is False
                       and needs_ax_poll(False, False, False, True, IDLE_SLOW) is True)))
    scenarios.append(("blacklisted app polls at the slow floor",
                      needs_ax_poll(False, False, True, False, IDLE_REPOLL) is False))
    scenarios.append(("a keystroke follow-up forces a read",
                      needs_ax_poll(True, True, False, False, 0.0) is True))
    scenarios.append(("recycling needs consecutive samples",
                      needs_recycle(MEMORY_STRIKES - 1) is False
                      and needs_recycle(MEMORY_STRIKES) is True))

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
    # Up/Down preserve the caret's column, so a caret known to be at column 0
    # stays at column 0: that is what keeps a blank line capitalizable.
    KEY_UP, KEY_DOWN = 126, 125
    VERTICAL_NAVIGATION = {KEY_UP, KEY_DOWN}
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
        "anchored": False,       # caret known to sit at column 0 of its line
        "line_before": "",       # text of the line the last observed break left
        "typed_at_caret": False, # the char before the caret was just TYPED
        "target_report": None,   # last reported reason the target was unusable
        "charless_keys": set(),  # keycodes already reported as producing no text
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
        "observer_element": None,
        "ax_dirty": True,
        "edit_count": 0,
        "stats_at": 0.0,
        "ax_calls": 0,
        "value_reads": 0,
        "tap_builds": 0,
        "keydowns": 0,           # keydowns the tap itself has seen
        "keys_app": None,        # application already reported as "tap alive"
        "observer_builds": 0,
        "observer_fail": 0,
        "over_ceiling": 0,
    }

    # ---- rule application ---- #
    def arm_from_shadow():
        """
        Recompute `pending`, applying the trust requirement on the "start of line"
        verdict. A synthetic buffer cannot produce one, so trailing spaces or
        punctuation can no longer launder an unknown context into a capital.

        A buffer that justifies nothing clears the arm whatever its trust state,
        and the other verdicts (sentence end, line break, enumerator) do not wait
        for the Accessibility confirmation: see may_arm_from_shadow().
        """
        if state["tab_lock"] or not state["enabled"]:
            state["pending"] = False
            return
        reason = capitalize_reason(state["shadow"], state["typed_at_caret"])
        if reason is None:
            state["pending"] = False
            return
        if not may_arm_from_shadow(reason, state["known"],
                                   is_buffer_reliable(state["ax_trusted"],
                                                      state["keyboard_only"])):
            return
        state["pending"] = resolve_capitalization(
            state["shadow"], state["ax_trusted"], state["saw_line_break"],
            state["synthetic"], state["anchored"], state["typed_at_caret"])

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
        state["edit_count"] += 1
        if deletion:
            state["deleted_since_ax"] += amount
        else:
            state["typed_since_ax"] += amount
        state["guard_until"] = time.monotonic() + EDIT_GUARD

    def invalidate(delay: float, pointer: bool = False):
        state["known"] = False
        state["retries"] = FOCUS_RETRIES
        state["saw_line_break"] = False
        state["anchored"] = False
        state["typed_at_caret"] = False     # a click or a move: pre-existing text
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
        state["anchored"] = True            # the caret opens the new line
        state["typed_at_caret"] = False     # the caret rests after a break, not a glyph
        state["line_before"] = state["shadow"]   # kept: the Up key needs it (v20.8)
        set_shadow("", known=True, synthetic=False)
        _log_line(f"[autocap] Return observed: line opened, next letter armed "
                  f"(app={state['bundle_id']})")
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

    def report_target(reason: str, role=None, subrole=None, extra: str = ""):
        """
        One line whenever the focused target stops being usable, reasons included.

        Silence is what made the Notion case guesswork: a rejected role and an
        unreadable caret both end in the same "no capital", and neither said why.
        Reported once per distinct CONDITION — reason, role, subrole and
        application — never per message: the text length is printed but is not
        part of the identity, or a condition that never clears would print one
        line per character typed. Reported ALWAYS — not only in --debug: the
        daemon runs as a service, so requiring a foreground debug run to see the
        reason makes the user restart modes just to get an answer. The volume is
        bounded by the once-per-condition rule, and the line lands in
        ~/Library/Logs/autocapitalize.log like everything else.
        """
        # Identity of the CONDITION, never of the message: `extra` carries
        # text_len, which grows with every keystroke, so comparing it turned a
        # persistent condition into one line per character (v20.7).
        signature = target_report_key(reason, role, subrole, state["bundle_id"])
        if signature == state["target_report"]:
            return
        state["target_report"] = signature
        _log_line(f"[autocap] target {reason}: "
                  f"role={role} subrole={subrole} {extra}".rstrip())
        # v20.4: always written to the log file, no --debug needed.

    def ax_read():
        state["ax_calls"] += 1
        element = focused_element()
        if element is None:
            state["editable"] = False
            report_target("absent")
            return None

        role = ax_attribute(element, kAXRoleAttribute)
        subrole = ax_attribute(element, kAXSubroleAttribute)
        if not is_editable_target(role, subrole):
            state["editable"] = False
            report_target("rejected", role, subrole)
            return None
        state["editable"] = True
        # target_report is cleared only by a read that COMPLETES. Clearing it here,
        # as soon as the role is accepted, made every poll print the same reason
        # again — the field's caret range stays unreadable, so the "once per
        # change" promise was broken by the very line that was supposed to keep it.

        value = ax_attribute(element, kAXValueAttribute)
        state["value_reads"] += 1
        if not isinstance(value, str):
            count = ax_attribute(element, kAXNumberOfCharactersAttribute)
            report_target("has no text value", role, subrole,
                          f"count={count}")
            if isinstance(count, int) and count == 0:
                state["ax_selection"] = 0
                state["target_report"] = None
                return "", ax_fingerprint(0, 0, "")
            return None

        if value == "":
            state["ax_selection"] = 0
            state["target_report"] = None
            return "", ax_fingerprint(0, 0, "")

        found = read_range(element)
        if found is None:
            report_target("caret range unreadable", role, subrole,
                          f"text_len={len(value)}")
            return None
        caret, selection = found
        state["ax_selection"] = selection
        caret = max(0, min(caret, len(value)))
        before = value[:caret]
        state["target_report"] = None
        return before, ax_fingerprint(len(value), caret, before)

    def refresh_from_context():
        # Consume the "an event happened" flag FIRST. This read serves it, and
        # several of the exits below bail out before the text is read at all
        # (no editable field focused, blacklisted app, lagging read). Leaving the
        # flag set made needs_ax_poll() see a forced read on every 20 ms tick, so
        # the daemon kept calling the Accessibility API 50 times a second for
        # nothing — measured in the field: 3000 AX calls a minute while the text
        # read counter never moved.
        state["ax_dirty"] = False
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
            trace = (state["shadow"][-24:], state["pending"],
                     state["typed_at_caret"])
            if trace != state["last_trace"]:
                state["last_trace"] = trace
                _log_line(f"[autocap] before={state['shadow'][-24:]!r} "
                          f"-> capitalize={state['pending']} "
                          f"tape={int(state['typed_at_caret'])}")

    # ---- AXObserver: event-driven refresh, poll becomes a fallback ---- #
    def detach_observer():
        """
        Tear the current AX observer down before replacing it.

        The previous build only dropped its references: the notifications stayed
        registered on the target process, the run-loop source was never
        invalidated, and the objects were kept alive forever by _KEEP_ALIVE. One
        live observer and its mach connection leaked on every application
        switch, which is exactly the kind of slow, monotonic growth reported.
        """
        observer = state["observer"]
        source = state["observer_source"]
        element = state["observer_element"]
        if observer is None and source is None:
            return
        if observer is not None and element is not None:
            try:
                from ApplicationServices import (
                    AXObserverRemoveNotification,
                    kAXValueChangedNotification,
                    kAXSelectedTextChangedNotification,
                    kAXFocusedUIElementChangedNotification,
                )
                for notification in (kAXFocusedUIElementChangedNotification,
                                     kAXValueChangedNotification,
                                     kAXSelectedTextChangedNotification):
                    try:
                        AXObserverRemoveNotification(observer, element,
                                    notification)
                    except Exception:
                        pass
            except Exception:
                pass
        if source is not None:
            try:
                Quartz.CFRunLoopRemoveSource(Quartz.CFRunLoopGetCurrent(), source,
                            Quartz.kCFRunLoopDefaultMode)
            except Exception:
                pass
        # Dropping the last reference is what releases the CF object; invalidate
        # the source first so the run loop cannot call into freed memory.
        try:
            if source is not None:
                invalidate = getattr(Quartz, "CFRunLoopSourceInvalidate", None)
                if invalidate is not None:
                    invalidate(source)
        except Exception:
            pass
        for dead in (observer, source, element):
            if dead is None:
                continue
            for index in range(len(_KEEP_ALIVE) - 1, -1, -1):
                if _KEEP_ALIVE[index] is dead:
                    del _KEEP_ALIVE[index]
        state["observer"] = None
        state["observer_source"] = None
        state["observer_element"] = None

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
            # Counted, not logged: this runs once per second, and a missing
            # observer only costs the event-driven refresh (the timer covers it).
            state["observer_fail"] += 1
            return
        bundle_id, pid = frontmost_bundle()
        if pid is None or pid == state["observer_pid"]:
            return

        detach_observer()
        state["observer_pid"] = pid

        if is_app_blacklisted(bundle_id):
            return

        def observer_callback(observer, element, notification, refcon):
            try:
                state["ax_dirty"] = True
                refresh_from_context()
            except BaseException:
                _log_callback_error("ax observer")

        try:
            # AXObserverCreate KEEPS the callback and calls it later for every
            # notification, so PyObjC must be told that this function is that
            # callback: without the declaration the bridge rejects the callable
            # ("Callable argument is not a PyObjC closure") and no observer is
            # ever created — silently, which is what the obs_fail counter was
            # reporting. objc.callbackFor() is the documented form for an API
            # that stores the reference.
            try:
                import objc
                registered_callback = objc.callbackFor(AXObserverCreate)(
                    observer_callback)
            except Exception:
                registered_callback = observer_callback
            error, observer = AXObserverCreate(pid, registered_callback, None)
            if error != 0 or observer is None:
                state["observer_fail"] += 1
                if debug:
                    _log_line(f"[autocap] AXObserverCreate failed: error={error}")
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
            state["observer_element"] = app_element
            state["observer_builds"] += 1
            _KEEP_ALIVE.append(observer)
            _KEEP_ALIVE.append(observer_callback)
            _KEEP_ALIVE.append(registered_callback)
            if debug:
                _log_line(f"[autocap] AX observer attached to pid {pid}")
        except Exception:
            _log_callback_error("observer setup")

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
                state["line_before"] = current   # the line being left (v20.8)
                state["typed_at_caret"] = True    # a break was just typed
                current = ""
                unknown = False
                state["keyboard_only"] = True
                state["saw_line_break"] = True
                state["synthetic"] = False   # an observed Return anchors the edge
                state["anchored"] = True     # ... and puts the caret at column 0
                state["last_space_at"] = 0.0
            elif char == " ":
                current = current + char
                state["anchored"] = False
                if (now - state["last_space_at"]) <= DOUBLE_SPACE_WINDOW:
                    substituted = apply_double_space_period(current)
                    if substituted != current:
                        current = substituted
                        state["last_space_at"] = 0.0
                        continue
                state["last_space_at"] = now
            else:
                current = current + char
                state["anchored"] = False
                state["last_space_at"] = 0.0
        state["typed_at_caret"] = True      # the caret sits right after typing
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
                invalidate(FOLLOWUP_DELAY, pointer=True)
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

            # Liveness trace, BEFORE the blacklist gate: the log has to show
            # that the tap itself receives keyboard events in this application.
            # One line per application — a per-keystroke trace would flood a file
            # that exists to be read, and this single line already separates
            # "the tap is blind here" from "the rules decided nothing". No AX
            # call: the bundle comes from the run-loop refresh.
            state["keydowns"] += 1
            if keydown_liveness_needed(state["bundle_id"], state["keys_app"]):
                state["keys_app"] = str(state["bundle_id"])
                _log_line(f"[autocap] keydown observed: "
                          f"app={state['bundle_id']} "
                          f"enabled={int(state['enabled'])}")

            if not state["enabled"]:
                state["pending"] = False
                return event

            if keycode in RETURN_KEYS:
                start_new_line()
                return event

            if keycode == KEY_DELETE:
                state["tab_lock"] = False
                state["composing"] = False
                state["anchored"] = False
                state["last_space_at"] = 0.0
                # A pending selection means the deletion removes the selection,
                # not one character: the shadow cannot model that.
                if state["ax_selection"] > 0:
                    state["ax_selection"] = 0
                    invalidate(FOLLOWUP_DELAY, pointer=True)
                    state["typed_at_caret"] = False
                    state["pending"] = False
                    return event
                previous = state["shadow"]
                if command:
                    updated = delete_line_backward(previous)
                elif option:
                    updated = delete_word_backward(previous)
                else:
                    updated = delete_backward(previous)
                state["typed_at_caret"] = False   # the caret now touches old text
                note_edit(max(1, len(previous) - len(updated)), deletion=True)
                set_shadow(updated, state["known"])
                if state["pending"] and not is_buffer_reliable(state["ax_trusted"],
                            state["keyboard_only"]):
                    state["pending"] = False
                return event

            if keycode == KEY_FWD_DELETE:
                state["tab_lock"] = False
                state["composing"] = False
                state["anchored"] = False
                if state["ax_selection"] > 0:
                    state["ax_selection"] = 0
                    invalidate(FOLLOWUP_DELAY, pointer=True)
                    state["typed_at_caret"] = False
                    state["pending"] = False
                    return event
                state["typed_at_caret"] = False   # the caret now touches old text
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

            if keycode in VERTICAL_NAVIGATION and state["anchored"]:
                # Vertical movement preserves the column, and the caret is known
                # to sit at column 0: it lands at column 0 of another line, which
                # still opens a line and must be capitalized. Everything else
                # about the buffer changes, hence the shadow bookkeeping.
                state["tab_lock"] = False
                state["composing"] = False
                state["saw_line_break"] = False
                state["pointer_lost"] = False
                state["keyboard_only"] = True
                state["anchored"] = True
                if keycode == KEY_UP and not anchor_survives_vertical(state["line_before"]):
                    # The line above carries text, so where the caret lands is not
                    # knowable: first character (column-preserving text view) or
                    # last one (block editor). We DO hold that line's text — it was
                    # the current line before the break — so the anchor is dropped
                    # and the normal rules decide instead of a blind capital.
                    state["anchored"] = False
                    set_shadow(state["line_before"], known=True)
                    _log_line(f"[autocap] Up from an opened line: the line above carries "
                              f"{len(state['line_before'])} char -> anchor dropped, capital "
                              f"only if that line ends a sentence "
                              f"(app={state['bundle_id']})")
                    return event
                if keycode == KEY_UP:
                    set_shadow(step_line_back(state["shadow"]),
                               known=state["known"])
                else:
                    # The line below the caret is not in the buffer: its text is
                    # unknowable until the Accessibility API or an edit says so.
                    state["known"] = False
                    state["retries"] = FOCUS_RETRIES
                    state["ax_dirty"] = True
                state["pending"] = True
                state["followup_at"] = now + FOLLOWUP_DELAY
                state["verify_at"] = now + VERIFY_DELAY
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
                # Reported once per keycode: a text field that delivers every
                # letter this way (some web editors do) would otherwise look
                # like "the daemon ignores me" with no trace anywhere.
                if keycode not in NON_TEXT_KEYS:
                    state["composing"] = True
                    state["composing_at"] = now
                    if keycode not in state["charless_keys"]:
                        state["charless_keys"].add(keycode)
                        _log_line(f"[autocap] key produced no characters: "
                                  f"keycode={keycode} (composition or dead key)")
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
                    # The reason AND the provenance, on the ONE line that always
                    # gets written: in Chromium/Arc the Accessibility read never
                    # gives the caret range, so the decision trace of the AX path
                    # is unreachable exactly where the user needs it.
                    _log_line(f"[autocap] capital inserted before {chars!r} "
                              f"(raison="
                              f"{capitalize_reason(state['shadow'], state['typed_at_caret'])} "
                              f"tape={int(state['typed_at_caret'])} "
                              f"app={state['bundle_id']})")
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
            _log_callback_error("event tap")
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
        # Retire the previous tap before building a new one. Disabling the tap
        # and invalidating its source is what actually frees the window-server
        # side resources: the old build only replaced the references, so each
        # watchdog recreation leaked a tap and a mach port for good.
        old_tap = tap_holder[0]
        old_source = source_holder[0]
        if old_source is not None:
            try:
                Quartz.CFRunLoopRemoveSource(Quartz.CFRunLoopGetCurrent(),
                            old_source, Quartz.kCFRunLoopCommonModes)
            except Exception:
                pass
        if old_tap is not None:
            try:
                Quartz.CGEventTapEnable(old_tap, False)
            except Exception:
                pass
        for dead in (old_tap, old_source):
            if dead is None:
                continue
            for index in range(len(_KEEP_ALIVE) - 1, -1, -1):
                if _KEEP_ALIVE[index] is dead:
                    del _KEEP_ALIVE[index]
        try:
            if old_source is not None:
                invalidate = getattr(Quartz, "CFRunLoopSourceInvalidate", None)
                if invalidate is not None:
                    invalidate(old_source)
        except Exception:
            pass
        state["tap_builds"] += 1
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

    # ---- memory diagnostics, and recycling as the hard ceiling ---- #
    def recycle() -> None:
        """
        Restart in place. execv keeps the same executable and pid, so the
        Accessibility grant (bound to the python binary) stays valid; if the
        restart itself fails, exiting lets launchd's KeepAlive bring a clean
        process back immediately.
        """
        _log_line("[autocap] memory ceiling reached, restarting")
        try:
            os.execv(sys.executable, [sys.executable] + sys.argv)
        except Exception:
            os._exit(0)

    def report_stats() -> None:
        size = resident()
        if size <= 0.0:
            return
        state["over_ceiling"] = (state["over_ceiling"] + 1
                                 if size > MEMORY_CEILING else 0)
        append_stats(
            f"{time.strftime('%Y-%m-%d %H:%M:%S')} resident={size:.0f}Mo "
            f"ax_calls={state['ax_calls']} texts_read={state['value_reads']} "
            f"kept={len(_KEEP_ALIVE)} taps={state['tap_builds']} "
            f"observers={state['observer_builds']} obs_fail={state['observer_fail']} "
            f"edits={state['edit_count']} keys={state['keydowns']} "
            f"pending={int(state['pending'])} known={int(state['known'])}")
        if needs_recycle(state["over_ceiling"]):
            recycle()

    # ---- fallback poller + watchdog, outside the tap ---- #
    def timer_callback(*args):
        try:
            now = time.monotonic()

            if state["stats_at"] == 0.0 or now - state["stats_at"] >= STATS_INTERVAL:
                state["stats_at"] = now
                report_stats()

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

            # The AX read is the heavy operation: it copies the whole field and
            # allocates one CF object per attribute. Reading it at 50 Hz around
            # the clock was pure waste — every keystroke already arms a follow-up
            # 12 ms later and the AX observer reports value changes — so the
            # timer is now only a slow safety net (see needs_ax_poll).
            if not needs_ax_poll(
                    forced,
                    (now - state["last_input"]) > IDLE_AFTER,
                    state["editable"],
                    state["enabled"],
                    now - state["last_poll_at"]):
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
            _log_callback_error("poll")

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
                invalidate(FOLLOWUP_DELAY, pointer=True)
            except BaseException:
                _log_callback_error("workspace observer")

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
    elif argument == "--stats":
        stats_report()
    elif argument == "--axprobe":
        axprobe()
    elif argument == "--debug":
        run(debug=True)
    elif argument == "--run":
        run()
    else:
        print(__doc__)
        sys.exit(2)
