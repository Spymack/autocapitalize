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
    // Anything that may ask for a password: a capital inserted into a password is
    // a failed login. Measured: the login window received one.
    "com.apple.loginwindow",
    "com.apple.securityagent",
    "com.apple.authorizationhost",
    "com.apple.UserNotificationCenter",
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
            let answer = read(element: under.0,
                              route: "pointer(\(Int(pointer.x)),\(Int(pointer.y))) > \(under.1)")
            // AN EMPTY ANSWER IS NOT AN ANSWER. The element under the pointer can be
            // a different editable — measured in Zen: an AXTextArea with 0 char and
            // no selection, while the field being typed in holds text. Adopting it
            // would wipe the model on the strength of the wrong element, so the
            // pointer route is kept only when it actually reads something.
            if let snapshot = answer.snapshot, snapshot.text?.isEmpty ?? true, snapshot.caret == nil {
                return focused
            }
            return answer
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
