import AppKit
import SwiftUI

@main
struct MacLinkHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(coordinator: delegate.coordinator)
        } label: {
            Image(systemName: delegate.coordinator.connectedDevices.isEmpty
                  ? "cursorarrow.motionlines"
                  : "cursorarrow.motionlines.click")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(coordinator: delegate.coordinator)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = HostCoordinator()
    private var pairingWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.onPairingChange = { [weak self] request in
            self?.presentPairing(request)
        }
        coordinator.onShowWelcome = { [weak self] in
            self?.showWelcome()
        }
        coordinator.start()

        // Show setup on first run, and on any later launch where the app still cannot do its job.
        // A menu bar app that silently does nothing is the worst possible first impression.
        if !coordinator.hasSeenWelcome || !coordinator.accessibilityGranted {
            showWelcome()
        }
    }

    func showWelcome() {
        coordinator.hasSeenWelcome = true

        let window = welcomeWindow ?? makeWindow(title: "Welcome to MacLink", floating: false)
        window.contentView = NSHostingView(rootView: WelcomeView(
            coordinator: coordinator,
            onDismiss: { [weak self] in
                self?.welcomeWindow?.close()
                self?.welcomeWindow = nil
            }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        welcomeWindow = window

        if !coordinator.accessibilityGranted {
            // Fires the system prompt alongside our own explanation of what it is for.
            coordinator.requestAccessibilityPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    private func presentPairing(_ request: PairingRequest?) {
        guard let request else {
            pairingWindow?.close()
            pairingWindow = nil
            return
        }

        let window = pairingWindow ?? makeWindow(title: "Pair iPhone", floating: true)
        window.contentView = NSHostingView(rootView: PairingCodeView(
            request: request,
            onCancel: { [weak self] in self?.coordinator.cancelPendingPairing() }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pairingWindow = window
    }

    private func makeWindow(title: String, floating: Bool) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // The pairing code has to be readable over whatever is in front; the welcome window does not.
        if floating { window.level = .floating }
        window.isReleasedWhenClosed = false
        return window
    }
}
