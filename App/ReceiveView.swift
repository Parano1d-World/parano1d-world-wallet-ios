import SwiftUI
import CoreImage.CIFilterBuiltins
import UIKit

struct ReceiveView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet: WalletState
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    private var allowed: Bool { !wallet.locked && AddressValidator.valid(wallet.address) && (wallet.localWallet == nil || wallet.localWallet?.recoveryVerified == true) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Your receiving address").font(Theme.editorial(30))
                    Text("Parano1d network · NOID").font(Theme.subheadline).foregroundStyle(Theme.secondary)
                    if allowed {
                        if let qr = Self.qr(wallet.address) {
                            Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 240).padding(20).background(.white, in: RoundedRectangle(cornerRadius: 20)).accessibilityLabel("QR code for your public Parano1d address")
                        }
                        Text(wallet.address).font(.system(size: 14, design: .monospaced)).multilineTextAlignment(.center).textSelection(.enabled)
                        HStack(spacing: 12) {
                            Button {
                                UIPasteboard.general.setItems([["public.utf8-plain-text": wallet.address]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                                copied = true
                            } label: { Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(MintButtonStyle()).accessibilityLabel(copied ? "Address copied" : "Copy full receiving address")
                            ShareLink(item: wallet.address) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(MintButtonStyle()).accessibilityLabel("Share receiving address").accessibilityHint("Opens sharing options including Messages, Mail and AirDrop when available")
                        }
                        Text("Share by Messages, Mail, AirDrop or another available app.").font(Theme.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                        if wallet.localWallet == nil { Text("Watch-only address. This app does not hold its recovery secret.").font(Theme.footnote).foregroundStyle(.orange) }
                    } else { Text("Unlock and verify your recovery backup before viewing a receiving address.") }
                    Text("Receive on Parano1d mainnet. Verify the full address before sharing. Test with a small amount until device sending and recovery have been checked.").font(Theme.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                    Text("Only your public address is shared here. Your master key stays on this device. Looking up this address can reveal it to the wallet-data service.").font(Theme.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth:560).frame(maxWidth:.infinity)
            }.background(AmbientBackground()).navigationTitle("Receive").navigationBarTitleDisplayMode(.inline).toolbar { Button("Done") { dismiss() } }
        }.onChange(of: wallet.locked) { _, locked in if locked { dismiss() } }
    }
    static func qr(_ address: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(address.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
