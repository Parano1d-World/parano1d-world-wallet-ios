import SwiftUI
import UIKit

/// Every approval inside the app (send, settings, mining, chat…) uses this app-designed sheet:
/// the same PIN pad or password field as the lock screen, plus the biometric option the person
/// turned on in this app. It presents above the current sheet, so a confirmation never ends up
/// hidden behind Send, Settings or an embedded browser. (Only Face ID's own scan animation is
/// drawn by iOS; nothing here shows the iPhone's passcode screen.)
@MainActor enum AuthenticationChoice {
    enum Selection { case code(String), biometric, device }
    private static var completion: ((Result<Selection,Error>) -> Void)?
    private static weak var controller: UIViewController?
    static func request(reason: String, kind: AppCodeKind, biometricName: String?) async throws -> Selection {
        guard completion == nil else { throw AppFailure("Authentication is already in progress.") }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { throw AppFailure("Return to the app to authenticate.") }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed else { throw AppFailure("Wait for the current screen to close, then try again.") }
        return try await withCheckedThrowingContinuation { continuation in
            completion = { continuation.resume(with: $0) }
            let view = AppApprovalView(reason: reason, kind: kind, biometricName: biometricName) { finish($0) }
            let host = UIHostingController(rootView: view)
            host.modalPresentationStyle = .pageSheet
            host.isModalInPresentation = true
            if let sheet = host.sheetPresentationController {
                sheet.detents = [.large()]
                sheet.prefersGrabberVisible = false
            }
            host.overrideUserInterfaceStyle = AppApprovalView.interfaceStyle
            controller = host
            presenter.present(host, animated: true)
        }
    }
    private static func finish(_ result: Result<Selection,Error>) {
        let done = completion; completion = nil
        let shown = controller; controller = nil
        if let shown, shown.presentingViewController != nil {
            shown.dismiss(animated: true) { done?(result) }
        } else { done?(result) }
    }
    static func cancel() {
        controller?.dismiss(animated: false)
        controller = nil
        let done = completion; completion = nil
        done?(.failure(AppFailure("Authentication cancelled.")))
    }
}

/// The approval sheet: what is being approved, then the app code, then the biometric option.
struct AppApprovalView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle = "system"
    let reason: String
    let kind: AppCodeKind
    let biometricName: String?
    let finish: (Result<AuthenticationChoice.Selection, Error>) -> Void
    @State private var code = ""
    @State private var done = false

    static var interfaceStyle: UIUserInterfaceStyle {
        switch DisplayStyle.read(UserDefaults.standard.string(forKey: DisplayStyle.storageKey) ?? "system") {
        case .system: return .unspecified
        case .light: return .light
        default: return .dark
        }
    }
    private var complete: Bool {
        kind.digits.map { code.utf8.count == $0 && code.utf8.allSatisfy { (48...57).contains($0) } } ?? (code.count >= 12 && code.count <= 128 && code.utf8.count <= 512)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image("Brand").resizable().scaledToFit().frame(width: 46, height: 46).padding(.top, 28).accessibilityHidden(true)
                Text(reason).font(Theme.editorial(26)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Enter your app \(kind == .password ? "password" : "PIN")\(biometricName.map { " or use " + $0 } ?? "").")
                    .font(Theme.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                AppCodeEntry(kind: kind, value: $code)
                if kind.digits == nil {
                    Button("Continue") { submit() }.buttonStyle(MintButtonStyle()).disabled(!complete)
                }
                if let biometricName {
                    Button { send(.success(.biometric)) } label: {
                        Label("Use \(biometricName)", systemImage: biometricName == "Face ID" ? "faceid" : "touchid")
                    }.font(Theme.subheadline.weight(.semibold)).foregroundStyle(Theme.mint)
                }
                Button("Cancel", role: .cancel) { send(.failure(AppFailure("Authentication cancelled."))) }
                    .font(Theme.subheadline).foregroundStyle(Theme.secondary).padding(.top, 4)
            }.padding(28).frame(maxWidth: 460).frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .tint(Theme.mint)
        // A full PIN continues by itself, like the lock screen's pad.
        .onChange(of: code) { _, _ in if kind.digits != nil && complete { submit() } }
        .onDisappear { code = ""; if !done { done = true; finish(.failure(AppFailure("Authentication cancelled."))) } }
    }
    private func submit() { guard complete else { return }; let entered = code; code = ""; send(.success(.code(entered))) }
    private func send(_ result: Result<AuthenticationChoice.Selection, Error>) {
        guard !done else { return }
        done = true; finish(result)
    }
}
