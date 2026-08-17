import Foundation
import Observation
import UIKit

/// User-tunable behaviour, persisted in `UserDefaults`.
@MainActor
@Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    var sensitivity: Double { didSet { defaults.set(sensitivity, forKey: Keys.sensitivity) } }
    var scrollSpeed: Double { didSet { defaults.set(scrollSpeed, forKey: Keys.scrollSpeed) } }
    var naturalScrolling: Bool { didSet { defaults.set(naturalScrolling, forKey: Keys.naturalScrolling) } }
    var tapToClick: Bool { didSet { defaults.set(tapToClick, forKey: Keys.tapToClick) } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Keys.haptics) } }
    var keepScreenAwake: Bool {
        didSet {
            defaults.set(keepScreenAwake, forKey: Keys.keepAwake)
            applyIdleTimer()
        }
    }

    /// Pushes `keepScreenAwake` onto `UIApplication`. Called from `onAppear` rather than `init`,
    /// because the app object is built before the application finishes launching.
    func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
    }

    var deviceName: String {
        didSet {
            let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { deviceName = oldValue; return }
            defaults.set(trimmed, forKey: Keys.deviceName)
        }
    }

    /// Host id of the Mac to reconnect to without asking.
    var lastHostID: String? {
        didSet { defaults.set(lastHostID, forKey: Keys.lastHostID) }
    }

    /// Once the first Mac is paired the wizard never shows again.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.onboarded) }
    }

    private enum Keys {
        static let sensitivity = "sensitivity"
        static let scrollSpeed = "scrollSpeed"
        static let naturalScrolling = "naturalScrolling"
        static let tapToClick = "tapToClick"
        static let haptics = "haptics"
        static let keepAwake = "keepScreenAwake"
        static let deviceName = "deviceName"
        static let lastHostID = "lastHostID"
        static let onboarded = "hasCompletedOnboarding"
    }

    init() {
        sensitivity = defaults.object(forKey: Keys.sensitivity) as? Double ?? 1.0
        scrollSpeed = defaults.object(forKey: Keys.scrollSpeed) as? Double ?? 1.0
        naturalScrolling = defaults.object(forKey: Keys.naturalScrolling) as? Bool ?? true
        tapToClick = defaults.object(forKey: Keys.tapToClick) as? Bool ?? true
        hapticsEnabled = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        keepScreenAwake = defaults.object(forKey: Keys.keepAwake) as? Bool ?? true
        deviceName = defaults.string(forKey: Keys.deviceName) ?? UIDevice.current.name
        lastHostID = defaults.string(forKey: Keys.lastHostID)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarded)
    }
}
