import SwiftUI

/// Home always shows the on-device wallet. Its account picker is in WalletHome.
struct HomeWalletSlot:View {
    @Binding var settings:Bool
    var body:some View {WalletHome(settings:$settings)}
}
