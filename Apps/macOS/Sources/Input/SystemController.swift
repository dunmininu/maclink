import AppKit
// The virtual main volume selector lives in AudioToolbox's AudioHardwareService, not CoreAudio.
import AudioToolbox
import CoreAudio
import Foundation
import IOKit.ps
import MacLinkKit

/// Reads and drives the bits of the Mac that are not raw input events: volume, battery, clipboard,
/// and the handful of shell-level actions like locking the screen.
@MainActor
final class SystemController {

    private let input: InputSynthesizer

    init(input: InputSynthesizer) {
        self.input = input
    }

    // MARK: - Media

    func handle(_ command: MediaCommand) {
        switch command {
        case .playPause: input.postMediaKey(.play)
        case .nextTrack: input.postMediaKey(.next)
        case .previousTrack: input.postMediaKey(.previous)
        case .volumeUp: input.postMediaKey(.soundUp)
        case .volumeDown: input.postMediaKey(.soundDown)
        case .mute: input.postMediaKey(.mute)
        case .brightnessUp: input.postMediaKey(.brightnessUp)
        case .brightnessDown: input.postMediaKey(.brightnessDown)
        case .keyboardBrightnessUp: input.postMediaKey(.illuminationUp)
        case .keyboardBrightnessDown: input.postMediaKey(.illuminationDown)
        }
    }

    // MARK: - System commands

    func handle(_ command: SystemCommand) {
        switch command {
        // These mirror the stock macOS shortcuts, so they follow whatever the user has configured
        // in Keyboard settings rather than fighting it.
        case .missionControl: input.press(.special(.up), modifiers: [.control])
        case .applicationWindows: input.press(.special(.down), modifiers: [.control])
        case .spaceLeft: input.press(.special(.left), modifiers: [.control])
        case .spaceRight: input.press(.special(.right), modifiers: [.control])
        case .showDesktop: input.press(.special(.f11), modifiers: [.function])
        case .launchpad: input.press(.special(.f4), modifiers: [.function])
        case .screenshotFull: input.press(.character("3"), modifiers: [.command, .shift])
        case .screenshotRegion: input.press(.character("4"), modifiers: [.command, .shift])
        case .quitApp: input.press(.character("q"), modifiers: [.command])
        case .closeWindow: input.press(.character("w"), modifiers: [.command])
        case .switchAppForward: input.press(.special(.tab), modifiers: [.command])
        case .switchAppBackward: input.press(.special(.tab), modifiers: [.command, .shift])
        case .lockScreen: input.press(.character("q"), modifiers: [.command, .control])
        case .sleepDisplay: runTool("/usr/bin/pmset", ["displaysleepnow"])
        case .sleepSystem: runTool("/usr/bin/osascript", ["-e", "tell application \"System Events\" to sleep"])
        }
    }

    @discardableResult
    private func runTool(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        do {
            try process.run()
            return true
        } catch {
            NSLog("MacLink: failed to run %@: %@", path, error.localizedDescription)
            return false
        }
    }

    // MARK: - Clipboard

    func readClipboard() -> String? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        guard text.utf8.count <= LinkProtocol.maxClipboardBytes else { return nil }
        return text
    }

    func writeClipboard(_ text: String) {
        guard text.utf8.count <= LinkProtocol.maxClipboardBytes else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Status

    func currentStatus(hostName: String) -> HostStatus {
        HostStatus(
            hostName: hostName,
            accessibilityGranted: InputSynthesizer.isTrusted,
            volume: outputVolume(),
            muted: isMuted(),
            batteryLevel: batteryLevel(),
            isCharging: isCharging(),
            frontmostApp: NSWorkspace.shared.frontmostApplication?.localizedName,
            displayWidth: desktopSize.width,
            displayHeight: desktopSize.height
        )
    }

    /// Union of every active display, matching the space `InputSynthesizer` moves the cursor in.
    private var desktopSize: CGSize {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return .zero }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return .zero }

        var bounds = CGRect.null
        for display in displays.prefix(Int(count)) {
            bounds = bounds.union(CGDisplayBounds(display))
        }
        return bounds.isNull ? .zero : bounds.size
    }

    // MARK: Volume (CoreAudio)

    private var defaultOutputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    func outputVolume() -> Double? {
        guard let device = defaultOutputDevice else { return nil }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }

        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? Double(volume) : nil
    }

    func setOutputVolume(_ value: Double) {
        guard let device = defaultOutputDevice else { return }
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return }

        var settable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { return }

        var volume = Float32(min(max(value, 0), 1))
        AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume
        )
    }

    func isMuted() -> Bool {
        guard let device = defaultOutputDevice else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }

        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return status == noErr && muted == 1
    }

    // MARK: Battery (IOKit)

    private func powerSourceDescription() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return description
        }
        return nil
    }

    func batteryLevel() -> Double? {
        guard let description = powerSourceDescription(),
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int,
              max > 0
        else { return nil }
        return Double(current) / Double(max)
    }

    func isCharging() -> Bool {
        guard let description = powerSourceDescription() else { return false }
        if let charging = description[kIOPSIsChargingKey] as? Bool { return charging }
        return description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
    }
}
