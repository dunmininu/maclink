import MacLinkKit
import SwiftUI

struct MorePane: View {
    @Environment(RemoteSession.self) private var session

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            HostStatusBar()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    presentation
                    desktop
                    screen
                    clipboard
                    settingsLink
                }
                .padding(16)
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: Presentation

    private var presentation: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Presentation")

            HStack(spacing: 12) {
                bigButton("chevron.left", "Previous") {
                    session.send(.keyboard(.key(.special(.left), modifiers: [])))
                }
                bigButton("chevron.right", "Next") {
                    session.send(.keyboard(.key(.special(.right), modifiers: [])))
                }
            }

            HStack(spacing: 10) {
                CommandButton(title: "Black Screen", systemImage: "rectangle.fill") {
                    session.send(.keyboard(.key(.character("b"), modifiers: [])))
                }
                CommandButton(title: "Start", systemImage: "play.rectangle") {
                    session.send(.keyboard(.key(.character("p"), modifiers: [.command, .shift])))
                }
                CommandButton(title: "Exit", systemImage: "escape") {
                    session.send(.keyboard(.key(.special(.escape), modifiers: [])))
                }
            }
        }
    }

    private func bigButton(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 34, weight: .semibold))
                Text(title)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    // MARK: Desktop

    private var desktop: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Desktop")

            LazyVGrid(columns: columns, spacing: 10) {
                CommandButton(title: "Mission Control", systemImage: "square.grid.3x2") {
                    session.send(.system(.missionControl))
                }
                CommandButton(title: "App Windows", systemImage: "macwindow.on.rectangle") {
                    session.send(.system(.applicationWindows))
                }
                CommandButton(title: "Launchpad", systemImage: "square.grid.3x3.fill") {
                    session.send(.system(.launchpad))
                }
                CommandButton(title: "Show Desktop", systemImage: "menubar.dock.rectangle") {
                    session.send(.system(.showDesktop))
                }
                CommandButton(title: "Space Left", systemImage: "arrow.left.square") {
                    session.send(.system(.spaceLeft))
                }
                CommandButton(title: "Space Right", systemImage: "arrow.right.square") {
                    session.send(.system(.spaceRight))
                }
                CommandButton(title: "Switch App", systemImage: "arrow.left.arrow.right.square") {
                    session.send(.system(.switchAppForward))
                }
                CommandButton(title: "Close Window", systemImage: "xmark.square") {
                    session.send(.system(.closeWindow))
                }
                CommandButton(title: "Quit App", systemImage: "power") {
                    session.send(.system(.quitApp))
                }
            }
        }
    }

    // MARK: Screen

    private var screen: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Screen")

            LazyVGrid(columns: columns, spacing: 10) {
                CommandButton(title: "Screenshot", systemImage: "camera.viewfinder") {
                    session.send(.system(.screenshotFull))
                }
                CommandButton(title: "Grab Region", systemImage: "crop") {
                    session.send(.system(.screenshotRegion))
                }
                CommandButton(title: "Lock Screen", systemImage: "lock.fill", tint: .orange, isProminent: true) {
                    session.send(.system(.lockScreen))
                }
                CommandButton(title: "Sleep Display", systemImage: "moon.fill") {
                    session.send(.system(.sleepDisplay))
                }
                CommandButton(title: "Sleep Mac", systemImage: "powersleep", tint: .orange, isProminent: true) {
                    session.send(.system(.sleepSystem))
                }
            }
        }
    }

    // MARK: Clipboard

    private var clipboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Clipboard")

            HStack(spacing: 10) {
                CommandButton(title: "Get from Mac", systemImage: "arrow.down.doc") {
                    session.requestClipboard()
                }
                CommandButton(title: "Send to Mac", systemImage: "arrow.up.doc") {
                    if let text = UIPasteboard.general.string {
                        session.sendClipboard(text)
                    }
                }
            }

            if let text = session.clipboardFromMac {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(.footnote)
                        .lineLimit(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack {
                        Button("Copy on iPhone") {
                            UIPasteboard.general.string = text
                        }
                        .font(.caption.weight(.medium))
                        Spacer()
                        Button("Dismiss") { session.clearClipboardFromMac() }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var settingsLink: some View {
        NavigationLink {
            SettingsPane()
        } label: {
            Label("Settings", systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}
