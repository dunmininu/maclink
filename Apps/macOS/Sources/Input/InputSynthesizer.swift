import AppKit
import CoreGraphics
import MacLinkKit

/// Turns protocol events into real macOS input.
///
/// Everything here needs the app to be trusted in System Settings › Privacy & Security ›
/// Accessibility. Without it, `CGEvent.post` silently does nothing.
@MainActor
final class InputSynthesizer {

    private let source: CGEventSource?
    private var heldButtons: Set<MouseButton> = []

    /// Tracks rapid clicks so the Mac sees a genuine double- or triple-click rather than N singles.
    private var lastClickTime: TimeInterval = 0
    private var lastClickPosition: CGPoint = .zero
    private var clickStreak = 0

    init() {
        source = CGEventSource(stateID: .combinedSessionState)
        // Without this, macOS suppresses local trackpad/keyboard input for a moment after each
        // synthetic event, which makes the Mac feel frozen when both are used together.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateRemoteMouseDrag
        )
    }

    // MARK: - Trust

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Pointer

    private var cursorPosition: CGPoint {
        // The event tap's idea of the cursor, which is what we need to offset from. NSEvent's
        // `mouseLocation` uses a flipped, bottom-left origin and would invert vertical motion.
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Union of every active display, in the same top-left origin space `CGEvent.location` uses.
    ///
    /// `CGDisplayBounds` is already in that space, so there is no flip to get wrong — unlike
    /// `NSScreen.frame`, which is bottom-left origin and would invert vertical clamping on a
    /// multi-display setup.
    private var displayBounds: CGRect {
        let fallback = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return fallback }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return fallback }

        var bounds = CGRect.null
        for display in displays.prefix(Int(count)) {
            bounds = bounds.union(CGDisplayBounds(display))
        }
        return bounds.isNull ? fallback : bounds
    }

    func move(dx: Double, dy: Double) {
        let current = cursorPosition
        let bounds = displayBounds
        let target = CGPoint(
            x: min(max(current.x + dx, bounds.minX), bounds.maxX - 1),
            y: min(max(current.y + dy, bounds.minY), bounds.maxY - 1)
        )

        // A move while a button is down has to be posted as a drag, or macOS will not extend
        // selections or carry a dragged item along.
        let type: CGEventType
        let button: CGMouseButton
        if heldButtons.contains(.left) {
            (type, button) = (.leftMouseDragged, .left)
        } else if heldButtons.contains(.right) {
            (type, button) = (.rightMouseDragged, .right)
        } else if heldButtons.contains(.middle) {
            (type, button) = (.otherMouseDragged, .center)
        } else {
            (type, button) = (.mouseMoved, .left)
        }

        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: button)
        event?.setDoubleValueField(.mouseEventDeltaX, value: target.x - current.x)
        event?.setDoubleValueField(.mouseEventDeltaY, value: target.y - current.y)
        event?.post(tap: .cghidEventTap)
    }

    func button(_ button: MouseButton, action: ButtonAction, clickCount: Int) {
        let position = cursorPosition
        let cgButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType

        switch button {
        case .left:
            (cgButton, downType, upType) = (.left, .leftMouseDown, .leftMouseUp)
        case .right:
            (cgButton, downType, upType) = (.right, .rightMouseDown, .rightMouseUp)
        case .middle:
            (cgButton, downType, upType) = (.center, .otherMouseDown, .otherMouseUp)
        }

        let isDown = action == .down
        if isDown {
            heldButtons.insert(button)
        } else {
            heldButtons.remove(button)
        }

        let resolvedCount = isDown ? resolveClickStreak(at: position, requested: clickCount) : max(clickStreak, 1)
        let event = CGEvent(
            mouseEventSource: source,
            mouseType: isDown ? downType : upType,
            mouseCursorPosition: position,
            mouseButton: cgButton
        )
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(resolvedCount))
        event?.post(tap: .cghidEventTap)
    }

    private func resolveClickStreak(at position: CGPoint, requested: Int) -> Int {
        if requested > 1 {
            clickStreak = requested
            lastClickTime = ProcessInfo.processInfo.systemUptime
            lastClickPosition = position
            return requested
        }

        let now = ProcessInfo.processInfo.systemUptime
        let interval = NSEvent.doubleClickInterval
        let moved = hypot(position.x - lastClickPosition.x, position.y - lastClickPosition.y)
        if now - lastClickTime <= interval, moved < 8 {
            clickStreak = min(clickStreak + 1, 3)
        } else {
            clickStreak = 1
        }
        lastClickTime = now
        lastClickPosition = position
        return clickStreak
    }

    /// Releases anything still held, e.g. when the phone disconnects mid-drag.
    func releaseHeldButtons() {
        for button in heldButtons {
            self.button(button, action: .up, clickCount: 1)
        }
        heldButtons.removeAll()
    }

    func scroll(dx: Double, dy: Double, phase: GesturePhase) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(dy.rounded())),
            wheel2: Int32(clamping: Int(dx.rounded())),
            wheel3: 0
        ) else { return }

        // Reporting a phase is what lets Safari and friends rubber-band and animate the way they do
        // for a real trackpad, instead of jumping in discrete notches.
        let phaseValue: Int64
        switch phase {
        case .began: phaseValue = 1
        case .changed: phaseValue = 2
        case .ended: phaseValue = 4
        case .cancelled: phaseValue = 8
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phaseValue)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    /// Pinch-to-zoom, expressed as ⌘-scroll.
    ///
    /// True `NSEventTypeMagnify` events cannot be synthesised through public API, but ⌘-scroll is the
    /// zoom gesture every Mac app already understands, so this works in Safari, Maps, Preview, Finder
    /// and Xcode alike.
    func zoom(magnification: Double, phase: GesturePhase) {
        guard abs(magnification) > 0.0001 else { return }
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(clamping: Int((magnification * 120).rounded())),
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.flags = .maskCommand
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    func type(text: String) {
        // Chunked because `keyboardSetUnicodeString` is a fixed-size buffer in practice, and posting
        // one event per grapheme would be needlessly slow for a pasted paragraph.
        for chunk in text.chunked(into: 20) {
            let utf16 = Array(chunk.utf16)
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event.post(tap: .cghidEventTap)
            }
        }
    }

    func press(_ key: KeyCode, modifiers: KeyModifiers) {
        let keyCode: CGKeyCode?
        switch key {
        case .special(let special):
            keyCode = VirtualKeys.code(for: special)
        case .character(let character):
            keyCode = VirtualKeys.code(forCharacter: character)
        }

        guard let keyCode else {
            // No ANSI position for this character (e.g. an emoji): if there are no modifiers we can
            // still type it as text.
            if case .character(let character) = key, modifiers.isEmpty {
                type(text: character)
            }
            return
        }

        let flags = VirtualKeys.flags(for: modifiers)
        let modifierKeys = VirtualKeys.modifierKeyCodes(for: modifiers)

        // Press the modifiers as real keys, not just as flags on the keystroke.
        //
        // Ordinary apps are happy with flags alone, but the system's own shortcuts — Mission
        // Control, App Exposé, Spaces — are dispatched by the symbolic-hotkey machinery, which
        // watches for genuine modifier key events. Without these, ⌃↑ silently does nothing.
        var accumulated: CGEventFlags = []
        for modifierKey in modifierKeys {
            accumulated.insert(modifierKey.flag)
            if let event = CGEvent(keyboardEventSource: source, virtualKey: modifierKey.code, keyDown: true) {
                event.flags = accumulated
                event.post(tap: .cghidEventTap)
            }
        }

        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }

        // Release in reverse, clearing each flag as its key comes up.
        for modifierKey in modifierKeys.reversed() {
            accumulated.remove(modifierKey.flag)
            if let event = CGEvent(keyboardEventSource: source, virtualKey: modifierKey.code, keyDown: false) {
                event.flags = accumulated
                event.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: - Media & system keys

    func postMediaKey(_ key: MediaKey) {
        for isDown in [true, false] {
            let state: Int = isDown ? 0xA : 0xB
            let data1 = Int((key.rawValue << 16)) | (state << 8)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(isDown ? 0xA00 : 0xB00)),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

private extension String {
    func chunked(into size: Int) -> [String] {
        guard count > size else { return isEmpty ? [] : [self] }
        var result: [String] = []
        var current = ""
        for character in self {
            current.append(character)
            if current.count >= size {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
