import SwiftUI
import MessageUI

/// Only public evidence selected by the user enters this report. No wallet or archive access.
struct PublicChatReport: Identifiable {
    let id = UUID()
    let target: String
    let messageID: String
    let senderID: String
    let displayName: String
    let message: String
    let created: Date
    var room: String = "#parano1d"
    private var isPrivate: Bool { room != "#parano1d" }
    static let recipient = "support@koajent.com"
    static let reasons = ["Harassment or threats", "Scam or impersonation", "Hateful or sexual content", "Spam", "Other"]
    var subject: String { (isPrivate ? "Parano1d private chat — report " : "Parano1d public chat — report ") + target }
    func body(reason: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: created)
        return """
        \(isPrivate ? "Private chat report" : "Public chat report")
        Room: \(room)
        Target: \(target)
        Reason: \(reason)
        Message ID: \(messageID)
        Sender identity: \(senderID)
        Display name (unverified): \(displayName)
        Message timestamp: \(timestamp)

        Selected message shared by the reporter (user-provided evidence; independently verify):
        --- BEGIN MESSAGE ---
        \(message)
        --- END MESSAGE ---

        Please review this report. It is not proof of misconduct.
        """
    }
}

struct PublicChatReportView: View {
    let report: PublicChatReport
    let onBlock: () -> Bool
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var wallet: WalletState
    @State private var reason = PublicChatReport.reasons[0]
    @State private var compose = false
    @State private var outcome: String?
    @State private var blocked = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Report " + report.target) {
                    Picker("Reason", selection: $reason) {
                        ForEach(PublicChatReport.reasons, id: \.self) { Text($0).tag($0) }
                    }
                    Text("To: " + PublicChatReport.recipient).textSelection(.enabled)
                    Text("You choose whether to send in Mail. Your email account identifies you to support. Only the message shown below is added by this app; no other conversation, wallet key or unrelated history is attached.").font(Theme.footnote)
                }.themedRow()
                Section("Review email") {
                    Text(report.subject).font(Theme.headline)
                    Text(report.body(reason: reason)).textSelection(.enabled).font(Theme.footnote)
                }.themedRow()
                Section {
                    if MFMailComposeViewController.canSendMail() {
                        Button("Continue to email") { outcome = nil; compose = true }
                            .disabled(wallet.locked)
                    } else {
                        Text("Mail is not configured on this device. Copy the report and send it to support@koajent.com using your email app. Copying does not submit a report.")
                    }
                    Button("Copy email address") {
                        UIPasteboard.general.setItems([["public.utf8-plain-text": PublicChatReport.recipient]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                        outcome = "Email address copied. No report was sent."
                    }
                    Button("Copy report") {
                        let text = report.subject + "\n\n" + report.body(reason: reason)
                        UIPasteboard.general.setItems([["public.utf8-plain-text": text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                        outcome = "Report copied. Send it using your email app; it has not been submitted."
                    }
                    if let outcome { Text(outcome).font(Theme.footnote).accessibilityAddTraits(.updatesFrequently) }
                }.themedRow()
                Section("Local protection") {
                    Button(blocked ? "User blocked on this device" : "Block this user", role: .destructive) {
                        blocked = onBlock()
                        outcome = blocked ? "User blocked on this device. You can unblock them in Chat settings. No report was sent by blocking." : "Could not block this identity. Your blocked list may be full."
                    }.disabled(blocked)
                    Text("Reporting does not automatically remove a post or block its author. Support must review it; independent network clients may still display public posts.").font(Theme.footnote)
                }.themedRow()
            }
            .scrollContentBackground(.hidden).background(AmbientBackground())
            .navigationTitle("Report public chat").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $compose) {
                PublicReportMailComposer(subject: report.subject, body: report.body(reason: reason)) { result in
                    compose = false
                    outcome = result
                }
            }
            .onChange(of: wallet.locked) { _, locked in if locked { compose = false; dismiss() } }
        }
    }
}

private struct PublicReportMailComposer: UIViewControllerRepresentable {
    let subject: String
    let body: String
    let onFinish: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([PublicChatReport.recipient])
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        return controller
    }
    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}
    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (String) -> Void
        init(onFinish: @escaping (String) -> Void) { self.onFinish = onFinish }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            guard error == nil else { onFinish("Mail reported an error. Delivery was not confirmed; try again or copy the report."); return }
            switch result {
            case .sent: onFinish("Mail accepted your email for sending. Delivery and moderator receipt are not confirmed.")
            case .saved: onFinish("Saved as an email draft. The report has not been sent.")
            case .cancelled: onFinish("Email cancelled. No report was sent.")
            case .failed: onFinish("Mail could not send the report. Try again or copy it to your email app.")
            @unknown default: onFinish("Email delivery was not confirmed.")
            }
        }
    }
}
