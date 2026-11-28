import SwiftUI

struct AppCodeEntry:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let kind:AppCodeKind
    @Binding var value:String
    @State private var showsPassword=false
    var body:some View {
        VStack(spacing:24) {
            if let digits=kind.digits {
                HStack(spacing:16) {
                    ForEach(0..<digits,id:\.self) { index in
                        Circle().fill(index<value.count ? Theme.mint : Theme.panel).frame(width:13,height:13)
                            .overlay(Circle().stroke(index<value.count ? Theme.mint : Theme.line,lineWidth:1))
                    }
                }.frame(maxWidth:.infinity).padding(.vertical,16)
                    .accessibilityElement(children:.ignore).accessibilityLabel("App PIN")
                    .accessibilityValue("\(value.count) of \(digits) digits entered")
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:18),count:3),spacing:14) {
                    ForEach(["1","2","3","4","5","6","7","8","9","","0","delete"],id:\.self) { key in
                        if key.isEmpty {Color.clear.frame(height:72).accessibilityHidden(true)}
                        else {
                            Button {
                                if key=="delete" {if !value.isEmpty {value.removeLast()}}
                                else if value.count<digits {value+=key}
                            } label: {
                                Group {if key=="delete" {Image(systemName:"delete.left").font(.system(size:21,weight:.light))}else{Text(key).font(.system(size:28,weight:.light,design:.rounded))}}
                                    .foregroundStyle(key=="delete" ? Theme.mint : Theme.text)
                                    .frame(width:72,height:72)
                                    .background(Theme.background,in:Circle())
                                    .overlay(Circle().stroke(Theme.mint.opacity(key=="delete" ? 0.5 : 0.28),lineWidth:1.2))
                                    .frame(maxWidth:.infinity)
                            }.buttonStyle(.plain).accessibilityLabel(key=="delete" ? "Delete last digit" : key)
                                .accessibilityIdentifier("appCode.\(key)")
                        }
                    }
                }.frame(maxWidth:310)
            } else {
                HStack(spacing:12) {
                    Group {
                        if showsPassword {TextField("App password",text:$value)}
                        else {SecureField("App password",text:$value)}
                    }
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .privacySensitive().accessibilityIdentifier("appCode.password")
                    Button {showsPassword.toggle()} label: {
                        Image(systemName:showsPassword ? "eye.slash" : "eye")
                            .font(.system(size:18,weight:.light)).foregroundStyle(Theme.mint)
                    }.accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                }.padding(18)
                    .themedCard(18)
                    .themedOutline(18, Theme.line, 1)
            }
        }
    }
}
struct AppLockView:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet:WalletState
    @Environment(\.scenePhase) private var phase
    @State private var code=""
    @State private var working=false
    var body:some View {
        ScrollView {
            VStack(spacing:25) {
                Brand().frame(maxWidth:.infinity,alignment:.leading)
                Image("Brand").resizable().scaledToFit().frame(width:58,height:58).padding(.top,24).accessibilityHidden(true)
                Text("Welcome back.").font(Theme.editorial(34))
                Text(wallet.appCodeKind.map{"Enter your \($0.label.lowercased())."} ?? "Unlock with your device authentication.").font(Theme.subheadline).foregroundStyle(Theme.secondary)
                if let kind=wallet.appCodeKind {AppCodeEntry(kind:kind,value:$code)}
                Button(working ? "Unlocking…" : "Unlock wallet") {
                    working=true;let entered=code;code=""
                    Task {await wallet.unlock(code:entered);working=false}
                }.buttonStyle(MintButtonStyle()).disabled(working || !wallet.appCodeLoaded || wallet.appCodeKind.map{kind in kind.digits.map{code.count != $0} ?? code.isEmpty} == true)
                if wallet.biometricEnabled {
                    Button("Unlock with \(wallet.biometricName)",systemImage:wallet.biometricName == "Face ID" ? "faceid" : "touchid") {
                        working=true;code=""
                        Task {await wallet.unlock(usingBiometrics:true);working=false}
                    }.disabled(working)
                }
                // With an app code set, Face ID is only offered when "Unlock with Face ID" is on.
                // Device authentication (which iOS runs as Face ID first) stays for recovery
                // under "Forgot app code?", and as the unlock when no app code exists.
                if wallet.appCodeKind == nil {
                    Button("Use device authentication") {
                        working=true;code=""
                        Task {await wallet.unlock(usingDevice:true);working=false}
                    }.disabled(working)
                }
                if let notice=wallet.notice {Text(notice).font(Theme.footnote).foregroundStyle(.orange)}
                Button("Forgot app code?") {Task{await wallet.resetAppCode();code=""}}.font(Theme.footnote).disabled(working || wallet.authenticating)
                Text("Your app code unlocks the wallet on this phone. It can’t recover a lost wallet, so keep your recovery key safe.").font(Theme.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            }.padding(28).frame(maxWidth:460).frame(maxWidth:.infinity)
        }.background(AmbientBackground()).disabled(wallet.authenticating)
        .task {await wallet.loadAppCode()}
        .onChange(of:phase){_,value in if value == .background {code=""}}
        .onDisappear {code=""}
    }
}
struct AppCodeSetupView:View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet:WalletState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var kind:AppCodeKind = .six
    @State private var code=""
    @State private var first=""
    @State private var confirming=false
    @State private var working=false
    @State private var error:String?
    var body:some View {
        ScrollView {
            VStack(spacing:24) {
                Brand().frame(maxWidth:.infinity,alignment:.leading)
                Text(confirming ? "Confirm your code." : "Make it personal.").font(Theme.editorial(32)).padding(.top,20)
                Text(confirming ? "Enter the same code again." : "Create an app lock. This is separate from your iPhone passcode.").font(Theme.subheadline).foregroundStyle(Theme.secondary)
                if let error {
                    Label(error,systemImage:"exclamationmark.circle")
                        .font(Theme.subheadline).foregroundStyle(.orange)
                        .frame(maxWidth:.infinity,alignment:.leading)
                        .accessibilityLabel("App lock error: \(error)")
                }
                if !confirming {
                    HStack(spacing:8) {
                        ForEach(AppCodeKind.allCases) { option in
                            Button {kind=option} label: {
                                Text(option.label).font(.caption.weight(.semibold)).lineLimit(1)
                                    .foregroundStyle(kind == option ? Color(hex:0x03100A) : Theme.text)
                                    .frame(maxWidth:.infinity).padding(.vertical,12)
                                    .background(kind == option ? Theme.mint : Theme.panel,in:Capsule())
                                    .overlay(Capsule().stroke(kind == option ? Theme.mint : Theme.line,lineWidth:1))
                            }.buttonStyle(.plain).accessibilityAddTraits(kind == option ? .isSelected : [])
                        }
                    }.accessibilityElement(children:.contain).accessibilityLabel("App lock type")
                    if kind == .four {Text("A 4-digit PIN is easier to guess. Six digits is recommended.").font(Theme.caption).foregroundStyle(Theme.secondary)}
                    if kind == .password {Text("Use 12–128 characters. This is not your wallet master key.").font(Theme.caption).foregroundStyle(Theme.secondary)}
                }
                AppCodeEntry(kind:kind,value:$code)
                Button(working ? "Saving…" : confirming ? "Save app lock" : "Continue") {advance()}.buttonStyle(MintButtonStyle()).disabled(working || code.isEmpty)
                if confirming {Button("Start again"){reset()}.font(Theme.footnote)}
                Text("Local to this device. Device authentication still protects the wallet. Ten incorrect attempts require a device-authenticated app-code reset; funds are never erased.").font(Theme.caption).foregroundStyle(Theme.secondary)
            }.padding(28).frame(maxWidth:460).frame(maxWidth:.infinity)
        }.background(AmbientBackground()).navigationTitle("App lock").navigationBarTitleDisplayMode(.inline).disabled(working)
        .onChange(of:kind){_,_ in reset()}
        .onChange(of:phase){_,value in if value == .background {reset()}}
        .onDisappear {reset()}
    }
    private func reset(){code="";first="";confirming=false;error=nil}
    private func advance() {
        do {
            try kind.validate(code)
            if !confirming {first=code;code="";confirming=true;error=nil;return}
            guard first==code else{code="";throw AppFailure("The codes did not match. Enter the same code again to confirm.")}
            let approved=code;let selected=kind;working=true;code="";first=""
            let firstSetup=wallet.appCodeKind == nil
            Task { @MainActor in
                defer{working=false}
                do{if firstSetup {BiometricOffer.pending=true};try await wallet.setAppCode(approved,kind:selected);if !wallet.locked{dismiss()}}
                catch{
                    if firstSetup {BiometricOffer.pending=false}
                    // Keep the confirmation page visible so a Keychain or app
                    // lock error cannot silently restart PIN setup.
                    confirming=true;first=approved;code=""
                    self.error=error.localizedDescription
                }
            }
        }catch{self.error=error.localizedDescription}
    }
}
