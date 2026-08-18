import AppKit
import Foundation

/// Drives macOS's own system shortcuts: Mission Control, Spaces, App Exposé and friends.
///
/// These are not ordinary key equivalents. They are dispatched by the symbolic-hotkey machinery,
/// and on macOS 26 that machinery ignores synthetic events completely — `⌃↑` posted through
/// `CGEvent.post` does nothing at any tap, with or without genuine modifier key events alongside
/// it, whether or not the keystroke is spaced out in time. All three were measured on 26.5.
///
/// Asking System Events to type the keystroke does work, because the event arrives through Apple
/// Events rather than being injected at the HID layer. The cost is a second permission — Automation
/// — on top of Accessibility, and a round trip per keystroke, so this is only used for the handful
/// of commands that genuinely need it. Ordinary shortcuts stay on the much cheaper `CGEvent` path.
final class SystemEventsBridge: @unchecked Sendable {

    enum Modifier: String {
        case command = "command down"
        case shift = "shift down"
        case option = "option down"
        case control = "control down"
    }

    /// Apple Events are synchronous and can take ~100ms, which is far too long to hold the main
    /// thread for a gesture. A serial queue keeps them off it while preserving ordering, so two
    /// quick swipes still arrive in the order they were made.
    private let queue = DispatchQueue(label: "africa.myladder.maclink.systemevents")
    /// Only ever touched on `queue`: `NSAppleScript` is not thread-safe.
    private var compiled: [String: NSAppleScript] = [:]

    private static let systemEventsBundleID = "com.apple.systemevents"

    /// Called with a human-readable reason when a keystroke could not be delivered.
    var onFailure: ((String) -> Void)?

    // MARK: Sending

    func send(keyCode: Int, modifiers: [Modifier] = []) {
        let source: String
        if modifiers.isEmpty {
            source = "tell application \"System Events\" to key code \(keyCode)"
        } else {
            let list = modifiers.map(\.rawValue).joined(separator: ", ")
            let using = modifiers.count == 1 ? list : "{\(list)}"
            source = "tell application \"System Events\" to key code \(keyCode) using \(using)"
        }
        run(source)
    }

    private func run(_ source: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let script: NSAppleScript
            if let cached = compiled[source] {
                script = cached
            } else {
                guard let fresh = NSAppleScript(source: source) else {
                    report("could not compile a system shortcut")
                    return
                }
                compiled[source] = fresh
                script = fresh
            }

            var error: NSDictionary?
            script.executeAndReturnError(&error)
            guard let error else { return }

            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743 is the user having refused, or never been asked for, Automation access.
            if code == -1743 {
                report("MacLink Host needs Automation permission for System Events — "
                       + "System Settings › Privacy & Security › Automation")
            } else {
                let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown error"
                report("system shortcut failed (\(code)): \(message)")
            }
        }
    }

    private func report(_ message: String) {
        NSLog("MacLink: %@", message)
        guard let onFailure else { return }
        DispatchQueue.main.async { onFailure(message) }
    }

    // MARK: Permission

    /// Current Automation state, without prompting.
    var isAuthorized: Bool {
        permissionStatus(askUserIfNeeded: false) == noErr
    }

    /// Prompts for Automation access if it has not been decided yet.
    ///
    /// This blocks until the user answers, so it must not be called on the main thread. It is done
    /// once at startup rather than on the first swipe, so the dialog appears while the user is
    /// still sitting at the Mac instead of in the middle of a gesture.
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let granted = permissionStatus(askUserIfNeeded: true) == noErr
            DispatchQueue.main.async { completion(granted) }
        }
    }

    private func permissionStatus(askUserIfNeeded: Bool) -> OSStatus {
        var status = OSStatus(errAEEventNotPermitted)
        Self.systemEventsBundleID.withCString { cString in
            var target = AEDesc()
            // AECreateDesc reports OSErr (Int16); everything else here speaks OSStatus (Int32).
            let created = OSStatus(AECreateDesc(
                DescType(typeApplicationBundleID), cString, strlen(cString), &target
            ))
            guard created == noErr else { status = created; return }
            status = AEDeterminePermissionToAutomateTarget(
                &target, DescType(typeWildCard), DescType(typeWildCard), askUserIfNeeded
            )
            AEDisposeDesc(&target)
        }
        return status
    }
}
