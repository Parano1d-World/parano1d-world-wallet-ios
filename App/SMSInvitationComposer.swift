import SwiftUI
import MessageUI

/// Opens the system composer only after a user tap. The phone number is a
/// delivery route, never a wallet identity, lookup key or recovery factor.
struct SMSInvitationComposer: UIViewControllerRepresentable {
    let recipient: String
    let invitation: String
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = context.coordinator
        if !recipient.isEmpty { composer.recipients = [recipient] }
        composer.body = "My signed Parano1d contact invitation (verify my identity with me separately):\n\(invitation)"
        return composer
    }
    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) { }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            onFinish()
        }
    }
}
