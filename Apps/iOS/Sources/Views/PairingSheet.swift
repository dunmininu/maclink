import SwiftUI

/// Where the user types the 6-digit code their Mac is displaying.
struct PairingSheet: View {
    @Environment(RemoteSession.self) private var session
    @State private var code = ""
    @FocusState private var isFocused: Bool

    private var digits: [Character] {
        Array(code.prefix(6))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 26) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.tint)
                    .padding(.top, 24)

                VStack(spacing: 6) {
                    Text("Enter the pairing code")
                        .font(.title3.weight(.semibold))
                    Text("\(session.pairingHostName ?? "Your Mac") is showing a 6-digit code. Type it here to finish pairing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                codeBoxes
                    .onTapGesture { isFocused = true }

                // The real input, kept off-screen so the boxes above can be styled freely.
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .focused($isFocused)
                    .opacity(0.01)
                    .frame(height: 1)
                    .onChange(of: code) { _, newValue in
                        let filtered = String(newValue.filter(\.isNumber).prefix(6))
                        if filtered != newValue { code = filtered }
                        if filtered.count == 6 { session.submitPairingCode(filtered) }
                    }

                Spacer()
            }
            .padding(.horizontal, 28)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.cancelPairing()
                    }
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium])
    }

    private var codeBoxes: some View {
        HStack(spacing: 10) {
            ForEach(0..<6, id: \.self) { index in
                let character = index < digits.count ? String(digits[index]) : ""
                Text(character)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .frame(width: 44, height: 56)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(index == digits.count ? Color.accentColor : .clear, lineWidth: 2)
                    }
            }
        }
    }
}
