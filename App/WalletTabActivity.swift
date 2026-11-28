import SwiftUI
private struct WalletTabActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var walletTabActive: Bool {
        get { self[WalletTabActiveKey.self] }
        set { self[WalletTabActiveKey.self] = newValue }
    }
}
