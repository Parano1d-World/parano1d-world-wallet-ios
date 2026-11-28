import SwiftUI
import UIKit
import LocalAuthentication

enum WalletSetupMode: String, Identifiable { case create, createAdditional, recover, importAdditional, manage; var id: String { rawValue } }
enum WalletSetupStep { case introduction, writeDown, verify, importKey, complete }
/// The displayed master key is removed before the verification screen is entered.
/// No recovery secret is sent to a gateway, website, clipboard or persistence layer.
struct WalletSetupView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    var mode: WalletSetupMode = .manage
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var wallet: WalletState
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var textSize
    private var keyColumns: [GridItem] { textSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())] }
    @State private var step: WalletSetupStep = .introduction
    @State private var revealedKey = ""
    @State private var keySections = Array(repeating: "", count: 16)
    @State private var walletName = ""
    @State private var warningAccepted = false
    @State private var writtenDown = false
    @State private var working = false
    @State private var message: String?
    @State private var revealUntil: Date?
    @State private var entryRevealUntil: Date?
    @State private var confirmPrint = false
    @State private var captured = UIScreen.main.isCaptured
    @State private var operationID = UUID()
    @FocusState private var focusedKeySection: Int?
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var canReveal: Bool { !captured && phase == .active && !wallet.locked }
    private var keyHex: String { keySections.joined() }
    private var entryVisible: Bool { entryRevealUntil.map { Date() < $0 } == true && canReveal }
    private var title: String {
        switch step {
        case .introduction: return mode == .createAdditional ? "Create another wallet." : mode == .importAdditional ? "Add another wallet." : mode == .recover ? "Bring your wallet back." : wallet.localWallet != nil ? "Your recovery backup." : "Secure from the start."
        case .writeDown: return "Write down your key."
        case .verify: return "Check your backup."
        case .importKey: return mode == .importAdditional ? "Enter its master key." : "Restore your wallet."
        case .complete: return "Your wallet is ready."
        }
    }
    private var number: Int { step == .writeDown ? 2 : step == .verify ? 3 : step == .complete ? 4 : 1 }
    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Color.clear.frame(height: 1).id("top")
                    if mode != .recover && mode != .importAdditional {
                        HStack(spacing: 5) { ForEach(1...3, id: \.self) { index in Capsule().fill(index <= number ? Theme.mint : Theme.line).frame(height: 2) } }.accessibilityLabel("Setup step \(min(number, 3)) of 3")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(title).font(Theme.editorial(34)).fixedSize(horizontal: false, vertical: true)
                        Text(subtitle).font(Theme.subheadline).foregroundStyle(Theme.secondary).lineSpacing(4)
                    }
                    if let message { Label(message, systemImage: "exclamationmark.circle").font(Theme.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("setup.message") }
                    switch step {
                    case .introduction: introduction
                    case .writeDown: writeDown
                    case .verify: verificationEntry
                    case .importKey: masterKeyEntry
                    case .complete: completion
                    }
                    if !NativeCore.available { Text("The native wallet engine is not linked. Wallet creation and recovery are unavailable.").font(Theme.footnote).foregroundStyle(.orange) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }.scrollDismissesKeyboard(.interactively)
                .onChange(of: step) { _, _ in focusedKeySection = nil; scroll.scrollTo("top", anchor: .top) }
        }
        .background(AmbientBackground()).foregroundStyle(Theme.text)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(working)
        .toolbar {
            ToolbarItem(placement: .principal) { Brand() }
            ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { clearSecrets(); dismiss() }.disabled(working) }
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { focusedKeySection = nil } }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay { if phase != .active || wallet.locked { Theme.background.ignoresSafeArea().overlay(Brand()) } }
        .onReceive(clock) { _ in
            if let until = revealUntil, Date() >= until { conceal(); wallet.touch() }
            if let until = entryRevealUntil, Date() >= until {
                let keep = focusedKeySection
                entryRevealUntil = nil
                if let keep { DispatchQueue.main.async { focusedKeySection = keep } } // keep the keyboard up
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
            captured = UIScreen.main.isCaptured
            if captured { clearSecrets(); message = "Stop screen recording before entering or viewing your master key." }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            clearSecrets(); message = "A screenshot may contain your master key. Remove it from Photos and Recently Deleted. Anyone with that key can restore the wallet."
        }
        .onChange(of: phase) { _, new in if new != .active { conceal(); entryRevealUntil = nil }; if new == .background { clearSecrets(); operationID = UUID() } }
        .onChange(of: wallet.locked) { _, locked in if locked { clearSecrets(); operationID = UUID() } }
        .onDisappear { clearSecrets(); operationID = UUID() }
    }
    private var subtitle: String {
        switch step {
        case .introduction: return "Your recovery secret controls your wallet. Only you should know it."
        case .writeDown: return "Write all 16 groups of your master key in order. Each group has four hexadecimal characters. Store it offline."
        case .verify: return "Enter all 16 groups from your written backup. The previous screen's key is now hidden."
        case .importKey: return wallet.localWallet == nil ? "Restore the 64-character hexadecimal master key exported by the official Parano1d wallet." : "Import a key as another wallet. Existing wallets stay saved and selectable."
        case .complete: return mode == .importAdditional ? "This separate wallet has been imported on this device. Keep its own master key safe." : mode == .recover ? "Your master key restored your wallet address on this device." : "Your saved backup matches this wallet. Keep it offline and never share it."
        }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 22) {
            guidance("Keep the key private", detail: "Anyone with this 64-character key can restore and control your wallet, even on another device.", icon: "eye.slash")
            guidance("Keep an offline backup", detail: "Use paper or another durable offline backup. Avoid photos, email and cloud notes.", icon: "square.and.pencil")
            guidance("There is no password reset", detail: "If you lose the device and your master key, we cannot recover the wallet.", icon: "lock.shield")
            if mode == .create && wallet.localWallet == nil {
                guidance("Two locks, different jobs", detail: "First, iOS asks for your iPhone passcode to protect the wallet secret. After you verify your master key, you'll create a Parano1d app PIN or password.", icon: "lock.iphone")
            }
            if mode == .recover && wallet.localWallet != nil {
                guidance("Your current wallet stays saved", detail: "A different key will be added to your wallet list. You can switch and rename wallets later.", icon: "square.stack")
            }
            Toggle("I understand and am in a private place", isOn: $warningAccepted).font(Theme.subheadline).tint(Theme.mint)
            if wallet.recoveryRequired { Text("This device has a wallet identity but its protected secret is missing. Only recovery of that original wallet is allowed.").font(Theme.footnote).foregroundStyle(.orange) }
        }
    }
    private var writeDown: some View {
        VStack(alignment: .leading, spacing: 20) {
            if revealedKey.count == 64 && canReveal {
                let characters = Array(revealedKey)
                let values = stride(from: 0, to: 64, by: 4).map { start in String(characters[start..<(start + 4)]) }
                LazyVGrid(columns: keyColumns, spacing: 10) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, group in
                        HStack(spacing: 10) {
                            Text(String(index + 1)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary).frame(width: 22, alignment: .trailing)
                            Text(group).font(.body.monospaced()).minimumScaleFactor(0.7).lineLimit(1)
                            Spacer(minLength: 0)
                        }.padding(.vertical, 12).padding(.horizontal, 8).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.privacySensitive().accessibilityIdentifier("setup.recoveryKey")
                HStack(spacing: 18) {
                    Button("Print a paper copy", systemImage: "printer") { confirmPrint = true }.font(Theme.footnote).disabled(captured)
                    Button("Hide key now") { conceal() }.font(Theme.footnote)
                }
                .confirmationDialog("Print your master key?", isPresented: $confirmPrint, titleVisibility: .visible) {
                    Button("Print") { MasterKeyPrint.print(key: revealedKey, address: wallet.address); wallet.touch() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Use a printer you trust, at home. Don't save it as a PDF or send it anywhere. Anyone with this paper can take your funds; store it like cash.")
                }
            } else {
                Panel {
                    Label("Master key hidden", systemImage: "eye.slash").font(Theme.headline)
                    Text(captured ? "Stop recording to reveal it." : "Authenticate to view your key again.").font(Theme.subheadline).foregroundStyle(Theme.secondary)
                    Button("Reveal master key") { revealKey() }.buttonStyle(MintButtonStyle()).disabled(working || !canReveal)
                }
            }
            Text("The key hides automatically after 15 minutes. You can hide it sooner or authenticate to reveal it again. Screenshots cannot be reliably blocked on iOS.").font(Theme.caption).foregroundStyle(Theme.secondary)
            Toggle("I wrote down all 16 groups in order", isOn: $writtenDown).font(Theme.subheadline)
        }
    }
    private var verificationEntry: some View {
        VStack(alignment: .leading, spacing: 18) {
            masterKeyEntry
            Button("Review my master key") { keySections = Array(repeating: "", count: 16); writtenDown = false; step = .writeDown; revealKey() }
                .font(Theme.footnote).disabled(working || !canReveal)
        }
    }
    private var masterKeyEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            if captured { Label("Stop screen recording to enter your master key.", systemImage: "eye.slash").foregroundStyle(.orange) }
            Panel {
                    Text("Parano1d master key").font(Theme.headline)
                    Text("16 groups of 4 hex characters. Paste the full 64-character key into the first box to fill all groups. Tap Edit beside any group to correct it.").font(Theme.caption).foregroundStyle(Theme.secondary)
                    Button(entryVisible ? "Hide entered key" : "Show entered key for 15 seconds", systemImage: entryVisible ? "eye.slash" : "eye") {
                        focusedKeySection = nil
                        entryRevealUntil = entryVisible ? nil : Date().addingTimeInterval(15)
                    }.font(Theme.footnote).disabled(working || captured || keyHex.isEmpty)
                    // Not lazy: a lazy grid can unload a focused group when the keyboard scrolls the page, which hides the keyboard.
                    let perRow = textSize.isAccessibilitySize ? 2 : 4
                    Grid(horizontalSpacing: 8, verticalSpacing: 10) {
                      ForEach(0..<(16 / perRow), id: \.self) { row in
                       GridRow {
                        ForEach((row * perRow)..<(row * perRow + perRow), id: \.self) { index in
                            VStack(spacing: 4) {
                                Text(String(index + 1)).font(.caption2.monospacedDigit()).foregroundStyle(Theme.secondary)
                                Group {
                                    if entryVisible { TextField("••••", text: keyBinding(index)) }
                                    else { SecureField("••••", text: keyBinding(index)) }
                                }
                                .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.none)
                                .keyboardType(.asciiCapable).focused($focusedKeySection, equals: index)
                                .accessibilityLabel("Master key group \(index + 1)")
                                Button("Edit") { keySections[index] = ""; focusedKeySection = index; wallet.touch() }
                                    .font(Theme.caption2).foregroundStyle(Theme.mint)
                                    .accessibilityLabel("Clear and re-enter master key group \(index + 1)")
                            }.padding(8).frame(maxWidth: .infinity).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(focusedKeySection == index ? Theme.mint : Theme.line, lineWidth: 0.7))
                        }
                       }
                      }
                    }.privacySensitive().disabled(working || captured).accessibilityIdentifier("setup.masterKey")
                    Text("\(keyHex.count) of 64 characters · Letters A–F and digits 0–9").font(Theme.caption).foregroundStyle(Theme.secondary)
                    Text("Compare the restored address with your desktop wallet before receiving or sending funds. Your key stays on this device.").font(Theme.caption).foregroundStyle(Theme.secondary)
            }
            if step == .importKey {
                Panel {
                    Text("Wallet name (optional)").font(Theme.headline)
                    TextField("For example, Personal", text: $walletName)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                        .textContentType(.none).accessibilityIdentifier("setup.walletName")
                    Text("Saved only on this device. Up to 40 characters; you can change it later.")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            }
        }
    }
    private func keyBinding(_ index: Int) -> Binding<String> {
        Binding(get: { keySections[index] }, set: { input in
            let cleaned = String(decoding: input.lowercased().utf8.filter { $0 >= 48 && $0 <= 57 || $0 >= 97 && $0 <= 102 }, as: UTF8.self)
            if index == 0 && cleaned.count == 64 {
                let characters = Array(cleaned)
                keySections = stride(from: 0, to: 64, by: 4).map { start in String(characters[start..<(start + 4)]) }
                focusedKeySection = nil
            } else {
                keySections[index] = String(cleaned.prefix(4))
                if keySections[index].count == 4 { focusedKeySection = index == 15 ? nil : index + 1 }
            }
            wallet.touch()
        })
    }
    private var completion: some View {
        VStack(spacing: 22) {
            Image(systemName: "checkmark.shield").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(Theme.mint).frame(maxWidth: .infinity).padding(.vertical, 22)
            Panel {
                Text("Your Parano1d address").font(Theme.caption).foregroundStyle(Theme.secondary)
                Text(wallet.address).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                Label(mode == .recover || mode == .importAdditional ? "Recovery secret imported" : "Recovery backup verified", systemImage: "checkmark.circle").font(Theme.caption).foregroundStyle(Theme.mint)
            }
            if mode == .recover {
                NavigationLink { AccountsView() } label: { ThemedLabel("Find previously used wallets", systemImage: "magnifyingglass") }.buttonStyle(MintButtonStyle())
                Text("Discovery checks public addresses and places accounts with observed use first. Historical coverage may be incomplete; scan additional ranges if needed.").font(Theme.footnote).foregroundStyle(Theme.secondary)
            }
            Text("Verify this address against your independent backup. Test sends with a disposable wallet after device validation.").font(Theme.footnote).foregroundStyle(Theme.secondary)
        }
    }
    private var footer: some View {
        VStack(spacing: 10) {
            if working { ProgressView("Working securely on this device…").font(Theme.caption) }
            Button(buttonTitle) { advance() }.buttonStyle(MintButtonStyle()).disabled(!canContinue).accessibilityIdentifier("setup.continue")
            if step != .complete {
                Button("Cancel and return to wallet choices") { clearSecrets(); dismiss() }
                    .font(Theme.subheadline).foregroundStyle(Theme.secondary).frame(minHeight: 44).disabled(working)
                if mode == .create && wallet.localWallet != nil {
                    Text("This wallet was already created. Its identity is retained. You may finish its backup or import a different key as another wallet.")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 14).background(Theme.background)
    }
    private var buttonTitle: String {
        switch step {
        case .introduction: return mode == .createAdditional ? "Create separate wallet" : mode == .importAdditional ? "Enter separate master key" : mode == .recover || wallet.recoveryRequired ? "Enter master key" : wallet.localWallet == nil ? "Create wallet" : "View master key"
        case .writeDown: return "Next · verify backup"
        case .verify: return "Verify backup"
        case .importKey: return mode == .importAdditional ? "Import wallet" : "Restore wallet"
        case .complete: return "Open wallet"
        }
    }
    private var canContinue: Bool {
        guard !working, !wallet.locked, NativeCore.available else { return false }
        switch step {
        case .introduction: return warningAccepted && !captured
        case .writeDown: return writtenDown && !captured
        case .verify, .importKey:
            let name = walletName.trimmingCharacters(in: .whitespacesAndNewlines)
            return !captured && (name.isEmpty || StoredWallet.validName(name)) && keyHex.utf8.count == 64 && keyHex.utf8.allSatisfy { $0 >= 48 && $0 <= 57 || $0 >= 97 && $0 <= 102 }
        case .complete: return true
        }
    }
    private func advance() {
        message = nil; focusedKeySection = nil
        switch step {
        case .introduction:
            if mode == .recover || mode == .importAdditional || wallet.recoveryRequired { step = .importKey }
            else if mode != .createAdditional && wallet.localWallet != nil { step = .writeDown; revealKey() }
            else { perform { token in
                let context = try await wallet.requireAuthentication("Create a wallet on this device")
                guard valid(token) else { return }
                let summary = try await (mode == .createAdditional ? WalletVault.shared.createAdditional(context: context) : WalletVault.shared.create(context: context))
                guard valid(token) else { return }
                wallet.apply(summary); step = .writeDown
                let result = try await WalletVault.shared.revealKey(context: context)
                guard valid(token), canReveal else { return }
                showRecoveryKey(result)
            } }
        case .writeDown:
            conceal(); keySections = Array(repeating: "", count: 16); step = .verify
        case .verify, .importKey:
            let importing = step == .importKey
            perform { token in
                let context: LAContext
                if importing { context = try await wallet.requireAuthentication(mode == .importAdditional ? "Import a separate wallet" : "Restore your wallet") }
                else { context = try await wallet.backupVerificationContext() }
                guard valid(token) else { return }
                let summary: WalletSummary
                if mode == .importAdditional { summary = try await WalletVault.shared.importAdditional(keyHex: keyHex, name: walletName, context: context) }
                else if importing { summary = try await WalletVault.shared.recover(keyHex: keyHex, name: walletName, context: context) }
                else { summary = try await WalletVault.shared.verify(keyHex: keyHex, context: context) }
                guard valid(token) else { return }
                clearSecrets(); wallet.apply(summary)
                // An imported key is already your backup: go straight to the wallet. Finding
                // previously used accounts and adding wallets stay available under Your wallets.
                if importing && summary.recoveryVerified { dismiss(); return }
                step = summary.recoveryVerified ? .complete : .writeDown
            }
        case .complete: clearSecrets(); dismiss()
        }
    }
    private func guidance(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: icon).font(.system(size: 21, weight: .light)).foregroundStyle(Theme.mint).frame(width: 26)
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 16, weight: .medium)); Text(detail).font(Theme.subheadline).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func revealKey() {
        perform { token in
            let context = try await wallet.requireAuthentication("Reveal your master key",fresh:true)
            guard valid(token) else { return }
            let result = try await WalletVault.shared.revealKey(context: context)
            guard valid(token), canReveal else { return }
            showRecoveryKey(result)
        }
    }
    private func valid(_ token: UUID) -> Bool { token == operationID && !wallet.locked }
    private func showRecoveryKey(_ key: String) {
        revealedKey = key
        revealUntil = Date().addingTimeInterval(900)
        wallet.setRecoveryKeyVisible(true)
    }
    private func conceal() {
        revealedKey = ""; revealUntil = nil
        wallet.setRecoveryKeyVisible(false)
    }
    private func clearSecrets() { conceal(); entryRevealUntil = nil; keySections = Array(repeating: "", count: 16); focusedKeySection = nil }
    private func perform(_ action: @escaping (UUID) async throws -> Void) {
        guard !working, !wallet.locked else { return }
        working = true; message = nil; wallet.touch()
        let token = UUID(); operationID = token
        Task {
            defer { working = false }
            do { try await action(token) } catch { if valid(token) { message = error.localizedDescription } }
        }
    }
}

/// Paper backup of the master key through AirPrint. Nothing is saved, shared or sent anywhere else by the app;
/// the page goes only to the printer the person picks.
enum MasterKeyPrint {
    @MainActor static func print(key: String, address: String) {
        guard key.count == 64, UIPrintInteractionController.isPrintingAvailable else { return }
        let chars = Array(key)
        let groups = stride(from: 0, to: 64, by: 4).enumerated().map { index, start in
            "<td><span class=n>\(index + 1)</span> \(String(chars[start..<(start + 4)]))</td>"
        }
        let rows = stride(from: 0, to: 16, by: 4).map { "<tr>" + groups[$0..<($0 + 4)].joined() + "</tr>" }.joined()
        let safeAddress = address.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let html = """
        <html><body style="font-family:-apple-system,Helvetica;color:#000">
        <h2 style="margin:0 0 4px">Parano1d World Wallet · master key backup</h2>
        <p style="margin:0 0 18px;font-size:11pt">Keep this paper offline and private. Anyone who has it can take your funds. There is no password reset.</p>
        <table style="border-collapse:separate;border-spacing:10px;font-family:Menlo,Courier;font-size:18pt">\(rows)</table>
        <p style="font-size:10pt;margin-top:18px">Wallet address: <span style="font-family:Menlo,Courier">\(safeAddress)</span></p>
        <p style="font-size:10pt">Written on: ____________________ &nbsp; Stored at: ____________________</p>
        <style>.n{font-size:9pt;color:#666;font-family:-apple-system,Helvetica}</style>
        </body></html>
        """
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .grayscale
        info.jobName = "Parano1d backup"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.showsNumberOfCopies = true
        controller.printFormatter = UIMarkupTextPrintFormatter(markupText: html)
        controller.present(animated: true) { _, _, _ in controller.printFormatter = nil }
    }
}
