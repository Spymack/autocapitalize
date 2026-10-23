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
