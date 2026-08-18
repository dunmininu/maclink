import MacLinkKit
import SwiftUI
import UIKit

struct KeyboardPane: View {
    @Environment(RemoteSession.self) private var session
    @State private var modifiers: KeyModifiers = []
    @State private var isFieldFocused = true

    var body: some View {
        VStack(spacing: 0) {
            HostStatusBar()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    typingField
                    modifierRow
                    navigationKeys
                    shortcutGrid
                }
                .padding(16)
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: Typing

    private var typingField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type on your Mac")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            RemoteKeyboardField(isFocused: $isFieldFocused) { event in
                send(event)
            }
            .frame(height: 46)
            .padding(.horizontal, 12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

            Text("Everything you type here goes straight to the Mac. Nothing is stored on the phone. Use the ⌨︎ button above the keyboard to put it away.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Modifiers

    private var modifierRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hold for the next key")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                modifierChip("⌘", .command)
                modifierChip("⇧", .shift)
                modifierChip("⌥", .option)
                modifierChip("⌃", .control)
                modifierChip("fn", .function)
            }
        }
    }

    private func modifierChip(_ label: String, _ modifier: KeyModifiers) -> some View {
        let isOn = modifiers.contains(modifier)
        return Button {
            if isOn { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
        } label: {
            Text(label)
                .font(.system(size: 17, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(
                    isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                .foregroundStyle(isOn ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Navigation keys

    private var navigationKeys: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keys")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                keyButton("esc", .special(.escape))
                keyButton("tab", .special(.tab))
                keyButton("⌫", .special(.delete))
                keyButton("⌦", .special(.forwardDelete))
                keyButton("↩", .special(.returnKey))
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    keyButton("▲", .special(.up)).frame(width: 64)
                    HStack(spacing: 8) {
                        keyButton("◀", .special(.left)).frame(width: 64)
                        keyButton("▼", .special(.down)).frame(width: 64)
                        keyButton("▶", .special(.right)).frame(width: 64)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                keyButton("home", .special(.home))
                keyButton("end", .special(.end))
                keyButton("pg↑", .special(.pageUp))
                keyButton("pg↓", .special(.pageDown))
            }
        }
    }

    private func keyButton(_ label: String, _ key: KeyCode) -> some View {
        Button {
            send(.key(key, modifiers: modifiers))
        } label: {
            Text(label)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Shortcuts

    private struct Shortcut: Identifiable {
        var id: String { title }
        var title: String
        var key: KeyCode
        var modifiers: KeyModifiers
    }

    private let shortcuts: [Shortcut] = [
        Shortcut(title: "⌘C", key: .character("c"), modifiers: [.command]),
        Shortcut(title: "⌘V", key: .character("v"), modifiers: [.command]),
        Shortcut(title: "⌘X", key: .character("x"), modifiers: [.command]),
        Shortcut(title: "⌘A", key: .character("a"), modifiers: [.command]),
        Shortcut(title: "⌘Z", key: .character("z"), modifiers: [.command]),
        Shortcut(title: "⇧⌘Z", key: .character("z"), modifiers: [.command, .shift]),
        Shortcut(title: "⌘S", key: .character("s"), modifiers: [.command]),
        Shortcut(title: "⌘F", key: .character("f"), modifiers: [.command]),
        Shortcut(title: "⌘T", key: .character("t"), modifiers: [.command]),
        Shortcut(title: "⌘W", key: .character("w"), modifiers: [.command]),
        Shortcut(title: "⌘Q", key: .character("q"), modifiers: [.command]),
        Shortcut(title: "⌘Space", key: .special(.space), modifiers: [.command]),
    ]

    private var shortcutGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(shortcuts) { shortcut in
                    Button {
                        // Shortcut buttons carry their own modifiers, so any sticky ones combine.
                        send(.key(shortcut.key, modifiers: shortcut.modifiers.union(modifiers)))
                    } label: {
                        Text(shortcut.title)
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Sending

    private func send(_ event: KeyboardEvent) {
        session.send(.keyboard(event))
        // Modifiers behave like a Mac's sticky keys: they apply to one keystroke, then clear.
        if case .key = event, !modifiers.isEmpty {
            modifiers = []
        }
    }
}

/// A `UITextField` used purely as a keystroke source.
///
/// SwiftUI's `TextField` gives you the resulting string, not the edits, which makes backspace on an
/// empty field invisible. Intercepting `shouldChangeCharactersIn` lets every keystroke — including
/// delete and return — be forwarded the moment it happens, and nothing is ever retained locally.
struct RemoteKeyboardField: UIViewRepresentable {
    @Binding var isFocused: Bool
    let onEvent: (KeyboardEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    /// A bar above the keyboard with the only reliable way off it.
    ///
    /// This field swallows Return and forwards it to the Mac, so the usual "return dismisses"
    /// habit cannot work here, and a bare text field on a full-height pane leaves no empty space
    /// to tap. Without this the keyboard could be raised and never lowered.
    private func makeAccessoryBar(for field: UITextField, coordinator: Coordinator) -> UIToolbar {
        let bar = UIToolbar()
        bar.sizeToFit()
        let hide = UIBarButtonItem(
            image: UIImage(systemName: "keyboard.chevron.compact.down"),
            style: .done,
            target: coordinator,
            action: #selector(Coordinator.hideKeyboard)
        )
        hide.accessibilityLabel = "Hide keyboard"
        bar.items = [
            UIBarButtonItem(systemItem: .flexibleSpace),
            hide,
        ]
        return bar
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.placeholder = "Tap here, then type"
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        // Smart quotes and dashes would silently rewrite anything typed into a terminal or editor.
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .default
        field.borderStyle = .none
        field.text = Coordinator.sentinel
        field.inputAccessoryView = makeAccessoryBar(for: field, coordinator: context.coordinator)
        context.coordinator.field = field
        if isFocused { field.becomeFirstResponder() }
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.onEvent = onEvent
        // Let the binding drive the keyboard in both directions. Previously this was write-only, so
        // setting it to false had no effect and the keyboard stayed up.
        let binding = $isFocused
        context.coordinator.setFocus = { binding.wrappedValue = $0 }
        if isFocused, !field.isFirstResponder {
            field.becomeFirstResponder()
        } else if !isFocused, field.isFirstResponder {
            field.resignFirstResponder()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        /// A single space keeps the field non-empty so iOS keeps reporting backspaces.
        static let sentinel = " "
        var onEvent: (KeyboardEvent) -> Void
        /// Reports focus back to SwiftUI so the binding matches reality after the user dismisses.
        var setFocus: ((Bool) -> Void)?
        weak var field: UITextField?

        init(onEvent: @escaping (KeyboardEvent) -> Void) {
            self.onEvent = onEvent
        }

        @objc func hideKeyboard() {
            field?.resignFirstResponder()
        }

        func textField(
            _ textField: UITextField,
            shouldChangeCharactersIn range: NSRange,
            replacementString string: String
        ) -> Bool {
            if string.isEmpty {
                onEvent(.key(.special(.delete), modifiers: []))
            } else if string == "\n" {
                onEvent(.key(.special(.returnKey), modifiers: []))
            } else {
                onEvent(.text(string))
            }
            // Never let the field's own content change: it stays at the sentinel forever.
            textField.text = Self.sentinel
            return false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onEvent(.key(.special(.returnKey), modifiers: []))
            return false
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            textField.text = Self.sentinel
            setFocus?(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            setFocus?(false)
        }
    }
}
