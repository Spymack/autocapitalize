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
