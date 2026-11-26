import SwiftUI

/// Manual UDID entry for real refresh, shown in the Installation /
/// refresh flow. The user pastes the 40-character UDID once; it is
/// validated (40 hex chars, either case) and kept by `DeviceUDIDStore`
/// so the sign-in flow can register this device with Apple.
///
/// No automatic lookup is offered: iOS has no public API for the UDID,
/// and a free Apple ID cannot carry the Packet Tunnel entitlement an
/// automatic lookup would need (see the research doc, update
/// 2026-11-26). The note under the field says so plainly.
struct DeviceUDIDSection: View {
    @ObservedObject var store: DeviceUDIDStore
    @State private var draft = ""
    @State private var errorMessage: String?

    var body: some View {
        Section(NSLocalizedString("udid.section", comment: "")) {
            if let saved = store.savedUDID {
                HStack {
                    Text(NSLocalizedString("udid.saved", comment: ""))
                    Spacer()
                    Text(saved)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("udid.savedText")
                }
                Button(NSLocalizedString("udid.clear", comment: ""), role: .destructive) {
                    store.clear()
                    draft = ""
                    errorMessage = nil
                }
                .accessibilityIdentifier("udid.clear")
            } else {
                Text(NSLocalizedString("udid.empty", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TextField(NSLocalizedString("udid.placeholder", comment: ""), text: $draft)
                .font(.caption.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .accessibilityIdentifier("udid.field")
            Button(NSLocalizedString("udid.save", comment: "")) {
                do {
                    try store.save(draft)
                    draft = ""
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            .buttonStyle(.bordered)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("udid.save")
            if let error = errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Text(NSLocalizedString("udid.help", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("udid.auto.note", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
