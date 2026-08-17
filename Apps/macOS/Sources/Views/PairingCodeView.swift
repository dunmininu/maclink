import SwiftUI

/// The code the user reads off the Mac and types into their phone.
struct PairingCodeView: View {
    let request: PairingRequest
    let onCancel: () -> Void

    private var groupedCode: String {
        let digits = Array(request.code)
        guard digits.count == 6 else { return request.code }
        return String(digits[0..<3]) + " " + String(digits[3..<6])
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Text(request.device.name)
                    .font(.headline)
                Text("wants to control this Mac")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(groupedCode)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .kerning(4)
                .padding(.vertical, 12)
                .padding(.horizontal, 24)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                .textSelection(.enabled)

            Text("Enter this code on your iPhone to finish pairing.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 360)
    }
}
