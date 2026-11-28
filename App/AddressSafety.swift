import SwiftUI

/// Address poisoning: scammers send dust from an address that starts and ends like one
/// you use, hoping you copy it from history. A recipient that matches a known address's
/// start and end but is not identical is refused before anything is signed.
enum AddressSafety {
    static func lookalike(of recipient: String, known: [String]) -> String? {
        guard recipient.count > 16 else { return nil }
        return known.first { other in
            other != recipient && other.count == recipient.count
                && other.prefix(7) == recipient.prefix(7) && other.suffix(5) == recipient.suffix(5)
        }
    }
    /// Contacts, saved addresses and this wallet's own accounts.
    @MainActor static func knownAddresses(wallet: WalletState) async -> [String] {
        var known = wallet.accounts.map(\.address)
        if let contacts = try? await ContactBook.shared.load() { known += contacts.map(\.address) }
        if let root = wallet.accounts.first(where: { $0.index == 0 })?.address,
           let saved = try? await WalletAddressBook.shared.load(root: root) { known += saved.map(\.address) }
        return Array(Set(known))
    }
    /// Recipients the person confirmed this session by retyping the last 5 characters.
    @MainActor static var confirmed: Set<String> = []
    struct Lookalike: Error, LocalizedError, Identifiable {
        let recipient: String
        let similar: String
        let retry: @MainActor () -> Void
        var id: String { recipient }
        var errorDescription: String? { "This address looks like one you know but is different." }
    }
    @MainActor static func check(_ recipient: String, wallet: WalletState, retry: @escaping @MainActor () -> Void = {}) async throws {
        guard !confirmed.contains(recipient) else { return }
        if let similar = lookalike(of: recipient, known: await knownAddresses(wallet: wallet)) {
            throw Lookalike(recipient: recipient, similar: similar, retry: retry)
        }
    }
}

/// Blocked by default. Sending anyway needs the person to compare both addresses and
/// retype the last 5 characters of the new one: a deliberate step, not a single tap.
struct LookalikeConfirmView: View {
    let alert: AddressSafety.Lookalike
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    private var matches: Bool { typed.trimmingCharacters(in: .whitespaces).lowercased() == String(alert.recipient.suffix(5)).lowercased() }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Lookalike address", systemImage: "exclamationmark.triangle.fill").font(Theme.headline).foregroundStyle(.orange)
                    Text("The address you're sending to starts and ends like one you already know, but the middle is different. Scammers create addresses like this so a payment goes to them instead. Nothing has been signed.")
                        .font(Theme.subheadline)
                }.themedRow()
                Section("Address you know") { HighlightedAddress(address: alert.similar) }.themedRow()
                Section("Address you're sending to") { HighlightedAddress(address: alert.recipient) }.themedRow()
                Section {
                    Text("Only continue if you confirmed this exact address with the person directly (in person, by call, or in an encrypted chat with them).").font(Theme.caption).foregroundStyle(Theme.secondary)
                    TextField("Type its last 5 characters", text: Binding(get: { typed }, set: { typed = String($0.prefix(5)) }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                    Button("I confirmed it with them. Continue") {
                        AddressSafety.confirmed.insert(alert.recipient)
                        dismiss()
                        alert.retry()
                    }.disabled(!matches).foregroundStyle(matches ? Theme.mint : Theme.secondary)
                } footer: {
                    Text("You'll still review the payment before anything is signed.")
                }.themedRow()
            }
            .navigationTitle("Check this address").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Don't send") { dismiss() } } }
        }
    }

}

/// Shows an address with its first and last characters emphasized, so a swapped
/// address (clipboard malware, poisoning) is easy to spot.
struct HighlightedAddress: View {
    let address: String
    var body: some View {
        let head = String(address.prefix(7)), tail = String(address.suffix(5))
        let middle = address.count > 12 ? String(address.dropFirst(7).dropLast(5)) : ""
        (Text(head).foregroundStyle(Theme.mint).fontWeight(.bold)
         + Text(middle).foregroundStyle(Theme.secondary)
         + Text(tail).foregroundStyle(Theme.mint).fontWeight(.bold))
            .font(.footnote.monospaced()).textSelection(.enabled)
            .accessibilityLabel("Address starting \(head), ending \(tail)")
    }
}
