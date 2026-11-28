import SwiftUI
import WebKit

@MainActor final class WebsiteDisplay: ObservableObject {
    @Published var expanded = false
}

@main struct ParanoidApp: App {
    @UIApplicationDelegateAdaptor(WalletRelayLifecycle.self) private var relayLifecycle
    @StateObject private var wallet = WalletState()
    @StateObject private var live = LiveData()
    @StateObject private var node = DeviceNode()
    @StateObject private var quotes = PriceFeed()
    @StateObject private var nearby = WalletRelayLifecycle.transport
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(ParanoidLook.key) private var paranoidStyle = false
    @Environment(\.scenePhase) private var scenePhase
    init() {
        // Migrate the earlier separate style preference once, preserving the
        // user's explicit Cyber choice and existing System/Light/Dark choices.
        if UserDefaults.standard.string(forKey:"displayStyle") == "cyber" {
            UserDefaults.standard.set("cyber",forKey:DisplayStyle.storageKey)
        }
        UserDefaults.standard.removeObject(forKey:"displayStyle")
        CrashReports.shared.start()
        BackgroundNodeSync.register()
        MiningAlerts.register()
        PixelFont.register()
        ThemeChrome.apply()
        // Build 162 switched public chat off whenever Paranoid mode (now "Peers") was on.
        // The wallet route no longer changes chat, so undo that once for those users.
        let defaults=UserDefaults.standard
        if !defaults.bool(forKey:"migration.peersChat.v163") {
            if defaults.bool(forKey:NodeEndpoints.paranoidKey) && defaults.bool(forKey:ChatPrivacy.storageKey) {
                defaults.set(false,forKey:ChatPrivacy.storageKey)
            }
            defaults.set(true,forKey:"migration.peersChat.v163")
        }
    }
    var body: some Scene {
        WindowGroup {
            RootView().task { BackgroundNodeSync.attach(node); WatchBridge.shared.attach(wallet: wallet, node: node, nearby: nearby, live: live, quotes: quotes) }.environmentObject(wallet).environmentObject(live).environmentObject(node).environmentObject(quotes).environmentObject(nearby).preferredColorScheme(DisplayStyle.read(appearance) == .system ? nil : DisplayStyle.read(appearance) == .light ? .light : .dark).tint(Theme.mint).font(Theme.body).fontDesign(DisplayStyle.read(appearance).mono ? nil : .default)
                .onReceive(NotificationCenter.default.publisher(for:UIApplication.didReceiveMemoryWarningNotification)) { _ in Task { await AssetMedia.shared.trimMemory() } }
                .onChange(of: appearance) { _, _ in WatchBridge.shared.republish(); ThemeChrome.apply() }
                .onChange(of: paranoidStyle) { _, _ in WatchBridge.shared.republish(); ThemeChrome.apply() }
                // Every look: lists show the style's background, with each row as its own framed card or bar.
                .scrollContentBackground(.hidden)
                .listRowSpacing(6)
                .background(AmbientBackground())
                .onChange(of: scenePhase) { _, phase in if phase != .active { wallet.setRecoveryKeyVisible(false) }; if phase == .background { wallet.cancelAuthentication(); if wallet.autoLockSeconds == 0 { wallet.lock() } else { wallet.tick() }; if !AppSidebar.enabled { live.stop(); quotes.stop(); node.pause() }; BackgroundNodeSync.schedule(); MiningAlerts.schedule() }
                    else if phase == .active { wallet.tick() } }
        }
        .commands { WalletCommands(wallet: wallet, node: node, live: live) }
    }
}
struct RootView: View {
    @ObservedObject private var keyboard = KeyboardState.shared
    @AppStorage(ParanoidLook.key) private var paranoid=false
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @StateObject private var websiteDisplay = WebsiteDisplay()
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var live: LiveData
    @EnvironmentObject private var node: DeviceNode
    @EnvironmentObject private var quotes: PriceFeed
    @EnvironmentObject private var nearby: NearbyTransport
    @AppStorage("meshRelayEnabled") private var meshRelayEnabled=true
    @AppStorage("livePrices") private var livePrices = true
    @AppStorage("externalMedia") private var externalMedia = true
    @AppStorage(TabLayout.storageKey) private var rawTabs = TabLayout.encoded(TabLayout.defaults)
    @State private var settings = false
    @State private var pendingContactInvitation=""
    @State private var showContactInvitation=false
    @State private var showMiningSheet=false
    @State private var notificationConversation=""
    @State private var showNotificationConversation=false
    @State private var watchHandoff: WatchHandoffRequest?
    /// A payment link (paramo1d://pay) that arrived while the wallet was locked; opened after unlock.
    @State private var pendingPayLink: WatchHandoffRequest?
    @State private var watchEntry = false
    @State private var selectedTab = 0
    @State private var visitedTabs: Set<Int> = [0]
    @State private var storedWallet = true
    @State private var identityLoaded = false
    @State private var setupMode: WalletSetupMode?
    @State private var showOnboardingError = false
    private var needsWelcome: Bool {
        (!storedWallet && wallet.address.isEmpty) || (!wallet.locked && (wallet.recoveryRequired || wallet.address.isEmpty ||
            (wallet.localWallet?.recoveryVerified == false && (wallet.localWallet?.profiles.count ?? 0) <= 1)))
    }
    private func beginSetup(_ mode: WalletSetupMode) {
        Task {
            if wallet.locked { await wallet.unlock() }
            guard !wallet.locked else { showOnboardingError = true; return }
            setupMode = mode
        }
    }
    private func beginWatch() {
        Task {
            if wallet.locked { await wallet.unlock() }
            guard !wallet.locked else { showOnboardingError = true; return }
            watchEntry = true
        }
    }
    private func openNotifiedConversation() async {
        guard identityLoaded,!wallet.locked,let id=WalletRelayLifecycle.pendingChatContactID else{return}
        guard let saved=try? await ContactBook.shared.load(),
              let contact=saved.first(where:{$0.id==id}),
              let root=wallet.accounts.first(where:{$0.index==0})?.address,
              let ownInvitation=try? await MessagingProfileStore.shared.invitation(for:root),
              let own=try? await ConnectedContact.inspect(ownInvitation),own.address==root else{return}
        WalletRelayLifecycle.pendingChatContactID=nil
        notificationConversation=contact.invitation
        showNotificationConversation=true
    }
    private func discardUnfinished() {
        Task {
            do {
                guard let current = wallet.localWallet, !current.recoveryVerified,
                      current.profiles.count == 1 else { throw AppFailure("Only a single unfinished wallet can be removed here.") }
                let context = try await wallet.requireAuthentication("Remove the unfinished wallet from this device", fresh: true)
                _ = try await WalletVault.shared.removeWallet(current.selectedRoot, context: context)
                wallet.clearLocalWallet()
                storedWallet = false
            } catch { wallet.notice = error.localizedDescription }
        }
    }
    @Environment(\.scenePhase) private var scenePhase
    @State private var biometricOffer = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var rootLayout: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if !identityLoaded {
                ProgressView().tint(Theme.mint)
            } else if needsWelcome {
                WalletWelcome(create: { beginSetup(.create) }, recover: { beginSetup(.recover) }, backup: { beginSetup(.manage) }, watch: { beginWatch() }, discard: discardUnfinished)
            } else if wallet.locked {
                AppLockView()
            } else if wallet.localWallet?.recoveryVerified == true && wallet.appCodeLoaded && wallet.appCodeKind == nil {
                NavigationStack { AppCodeSetupView() }
            } else {
                // Mac: navigation in a left sidebar. iPhone and iPad: the bottom tab bar.
                let layout = AppSidebar.enabled ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                layout {
                    if AppSidebar.enabled && !websiteDisplay.expanded { AppSidebar(selected: $selectedTab) }
                    ZStack {
                    ForEach(0..<4,id: \.self) { index in
                    if visitedTabs.contains(index) {
                    NavigationStack {
                        Group {
                            if index == 0 { HomeWalletSlot(settings: $settings) }
                            else {
                                switch TabLayout.read(rawTabs)[index - 1] {
                                case .nfts: CollectionsView()
                                case .chat: ChatLandingView()
                                case .ecosystem: PublicEcosystemView()
                                case .mining: MiningView()
                                default: PublicEcosystemView()
                                }
                            }
                        }
                    }
                        .environment(\.walletTabActive, selectedTab == index)
                        .opacity(selectedTab == index ? 1 : 0)
                        .allowsHitTesting(selectedTab == index)
                        .accessibilityHidden(selectedTab != index)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    }
                    }.id(rawTabs + "|" + wallet.address)
                    if !AppSidebar.enabled && !websiteDisplay.expanded && !keyboard.visible { AppTabBar(selected: $selectedTab) }
                }

            }
        }
    }
    private var monitoredRoot: some View {
        rootLayout
        // Right after a new or restored wallet gets its app code, offer Face ID / Touch ID once.
        .onChange(of: wallet.appCodeKind) { _, kind in
            if kind != nil, BiometricOffer.pending, !wallet.biometricEnabled, wallet.biometricsAvailable { biometricOffer = true }
            else if kind != nil, !wallet.biometricsAvailable || wallet.biometricEnabled { BiometricOffer.pending = false }
        }
        .alert("Unlock with \(wallet.biometricName)?", isPresented: $biometricOffer) {
            Button("Use \(wallet.biometricName)") { BiometricOffer.pending = false; Task { await wallet.setBiometricUnlock(true) } }
            Button("Not now", role: .cancel) { BiometricOffer.pending = false }
        } message: {
            Text("Open your wallet with \(wallet.biometricName) instead of typing your app code. You can change this anytime in Settings → Wallet.")
        }
        .overlay { if scenePhase != .active { Theme.background.ignoresSafeArea().overlay(Brand()) } }
        .task(id:"display-\(wallet.address)-\(wallet.locked)") {
            if !wallet.locked {await live.restoreDisplay(owner:wallet.address)}
        }
        .onReceive(clock) { date in
            wallet.tick()
            if !wallet.address.isEmpty {WalletRelayLifecycle.enrollWallet()}
            WalletRelayLifecycle.configure()
            if scenePhase == .active && !wallet.locked && !wallet.offlineMode && livePrices { quotes.refresh() }
            if scenePhase == .active { node.synchronize(unlocked:!wallet.locked,offline:wallet.offlineMode,owner:wallet.address); node.pollProgress() }
            if scenePhase == .active && !wallet.locked { MiningAlerts.foregroundTick(offline: wallet.offlineMode) }
            if scenePhase == .active && !wallet.locked && !wallet.offlineMode,
               let root=wallet.accounts.first(where:{$0.index==0})?.address {
                Task { await PaymentReconciliation.refreshPending(root:root,node:node) }
            }
            if scenePhase == .active && !wallet.locked && !wallet.offlineMode && !wallet.address.isEmpty && (live.updated.map { date.timeIntervalSince($0) > 10 } ?? true) { live.refresh(owner: wallet.address, offline: wallet.offlineMode) }
        }
        .onChange(of:meshRelayEnabled) {_,_ in WalletRelayLifecycle.configure()}
        .onChange(of:selectedTab) { _, index in visitedTabs.insert(index); websiteDisplay.expanded=false }
        .onChange(of:rawTabs) { _, _ in selectedTab=0;visitedTabs=[0] }
    }
    private var rootLifecycle: some View {
        monitoredRoot
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !wallet.locked && !wallet.offlineMode && !node.transactionFlowActive {
                // Immediate check on return, unless a failure backoff is still
                // running: app switching must not restart a failing (possibly
                // full-history) download every time. The periodic tick and
                // "Verify now" still apply.
                let backoffActive = node.retryAt.map { Date() < $0 } ?? false
                node.synchronize(unlocked:true,offline:false,force:!backoffActive,owner:wallet.address)
            }
        }
        .onChange(of: wallet.offlineMode) { _, offline in if offline { live.stop(); quotes.stop(); node.pause(); Task { await AssetMedia.shared.cancelLoads() } } }
        .onChange(of: node.nativeStateHash) { _, hash in
            if hash != nil && scenePhase == .active && !wallet.locked && !wallet.offlineMode && AddressValidator.valid(wallet.address) {
                live.refresh(owner: wallet.address, offline: false, force: true)
            }
        }
        .onChange(of: node.verifiedHeight) { _, _ in
            if scenePhase == .active && !wallet.locked && !wallet.offlineMode,
               let root=wallet.accounts.first(where:{$0.index==0})?.address {
                Task {await PaymentReconciliation.refreshPending(root:root,node:node)}
            }
        }
        .onChange(of: node.balanceHeight) { _, height in
            if let height,let amount=node.balanceMicronoid,node.balance(for:wallet.address) != nil {
                WalletActivityNotifications.observeVerifiedBalance(owner:wallet.address,micronoid:amount,height:height)
                WatchBridge.shared.observeVerifiedBalance(owner:wallet.address,micronoid:amount,height:height)
            }
        }
        .onChange(of: live.holdingsHash) { _, hash in
            if hash != nil,live.holdingsVerifiedLocally,let height=live.holdingsHeight {
                WalletActivityNotifications.observeVerifiedAssets(owner:wallet.address,holdings:live.holdings,height:height)
            }
        }
        .onChange(of: externalMedia) { _,enabled in if !enabled { Task { await AssetMedia.shared.cancelLoads() } } }
        .onChange(of: livePrices) { _, enabled in if !enabled { quotes.stop() } }
        .onChange(of: wallet.address) { _, address in
            live.clear();node.resetWallet();PhoneWidgetData.clearBalance()
            if !wallet.locked { Task { try? await LastBalanceStore.shared.setCurrent(AddressValidator.valid(address) ? address : nil) } }
            if AddressValidator.valid(address) {
                Task {
                    let snapshot=try? await LastBalanceStore.shared.load(for:address)
                    guard wallet.address==address,!wallet.locked else{return}
                    node.restoreLastBalance(snapshot,owner:address)
                }
            }
        }
        .onChange(of: wallet.locked) { _, locked in if !locked { let owner = wallet.address; Task { try? await LastBalanceStore.shared.setCurrent(AddressValidator.valid(owner) ? owner : nil) } } }
        .onChange(of: wallet.locked) { _, locked in if locked { Task { await AssetMedia.shared.cancelLoads() }; websiteDisplay.expanded = false; live.clear(); node.pause(); setupMode = nil; settings = false; watchEntry = false; selectedTab = 0; visitedTabs=[0] } }
    }
    /// Saves Bluetooth messages addressed to this wallet as soon as they arrive, which also
    /// posts the private-message notification. Without a chat profile nothing is imported.
    private func importNearbyMessages() async {
        guard let root=wallet.accounts.first(where:{$0.index==0})?.address,
              let invitation=try? await MessagingProfileStore.shared.invitation(for:root),
              let own=try? await ConnectedContact.inspect(invitation),own.address==root else {return}
        try? await MessageArchive.shared.importNearby(nearby.packets,identity:own.id)
    }
    /// Opens the iPhone Send review for a payment handed off from the Apple Watch.
    private func openWatchHandoff() {
        guard !wallet.locked, let pending=WatchBridge.pendingHandoff, AddressValidator.valid(pending.address) else {return}
        WatchBridge.pendingHandoff=nil
        watchHandoff=WatchHandoffRequest(address:pending.address,amount:pending.amount)
    }
    /// Apple Watch hand-off and nearby-message import, kept apart from the main chain
    /// so the compiler type-checks each part quickly.
    private var rootIntegrations: some View {
        rootLifecycle
        .sheet(item:$watchHandoff) { request in
            NavigationStack {SendView(initialRecipient:request.address,initialAmount:request.amount)}
        }
        .onReceive(NotificationCenter.default.publisher(for:WatchBridge.handoffOpened)) {_ in openWatchHandoff()}
        .onReceive(NotificationCenter.default.publisher(for:NearbyTransport.packetArrived)) {_ in Task {await importNearbyMessages()}}
        .onChange(of:wallet.locked) {_,locked in if !locked {openWatchHandoff(); if let link=pendingPayLink {pendingPayLink=nil;watchHandoff=link}}}
    }
    /// A tapped mining alert opens Mining: its tab when it's in the tab bar, otherwise a sheet (after unlock).
    private func openMiningFromAlert() {
        MiningAlerts.pendingOpen = true
        guard !wallet.locked else { return }
        MiningAlerts.pendingOpen = false
        if let slot=TabLayout.read(rawTabs).firstIndex(of:.mining) { selectedTab=slot+1; visitedTabs.insert(slot+1) }
        else { showMiningSheet=true }
    }
    /// Hands a pairing code to the Mining screen: its tab when Mining is in the tab bar, otherwise a sheet.
    private func openMiningPairing(_ code:String) {
        RigPairRequest.shared.code=code
        guard !wallet.locked else { return }   // shown after unlock (see onChange below)
        if let slot=TabLayout.read(rawTabs).firstIndex(of:.mining) { selectedTab=slot+1; visitedTabs.insert(slot+1) }
        else { showMiningSheet=true }
    }
    var body: some View {
        rootIntegrations
        .onOpenURL { url in
            // Payment link: paramo1d://pay?to=<o1 address>&amount=<NOID>. It only fills in Send;
            // the person still reviews and approves, with the usual address checks.
            if let request=PayLink.parse(url) {
                if wallet.locked {pendingPayLink=request} else {watchHandoff=request}
                return
            }
            // Mining pairing link: paramo1d://mining/pair/CODE (or the website QR, below).
            if url.scheme?.lowercased()=="paramo1d",url.host?.lowercased()=="mining",let code=RigPairCode.parse(url.absoluteString) {
                openMiningPairing(code); return
            }
            guard url.scheme?.lowercased()=="paramo1d",url.host?.lowercased()=="contact",
                  let uri=ScannedContactInvitation.parse(url.absoluteString) else{return}
            pendingContactInvitation=uri
            if !wallet.locked {showContactInvitation=true}
        }
        // The rig dashboard's pairing QR (https://parano1dworld.com/mining/pair/CODE or /#Mining/pair/CODE)
        // opens here from the Camera app when the website's app-link file lists this app.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url=activity.webpageURL,let code=RigPairCode.parse(url.absoluteString) { openMiningPairing(code) }
            else if let url=activity.webpageURL { UIApplication.shared.open(url) }
        }
        .onChange(of:wallet.locked) {_,locked in if !locked,let code=RigPairRequest.shared.code {openMiningPairing(code)}}
        .onChange(of:wallet.locked) {_,locked in if !locked && MiningAlerts.pendingOpen {openMiningFromAlert()}}
        .onReceive(NotificationCenter.default.publisher(for:MiningAlerts.opened)) {_ in openMiningFromAlert()}
        .onChange(of:wallet.locked) {_,locked in if locked {showMiningSheet=false}}
        .sheet(isPresented:$showMiningSheet) {
            NavigationStack {MiningView(standalone: true).toolbar{ToolbarItem(placement:.cancellationAction){Button("Done"){showMiningSheet=false}}}}
        }
        .onReceive(NotificationCenter.default.publisher(for:WalletRelayLifecycle.notificationOpened)) {_ in Task {await openNotifiedConversation()}}
        .onChange(of:wallet.locked) {_,locked in if !locked && !pendingContactInvitation.isEmpty {showContactInvitation=true}}
        .onChange(of:wallet.locked) {_,locked in if !locked {Task {await openNotifiedConversation()}}}
        .sheet(isPresented:$showContactInvitation,onDismiss:{pendingContactInvitation=""}) {
            NavigationStack {MessagingView(initialInvitation:pendingContactInvitation)}
        }
        .sheet(isPresented:$showNotificationConversation,onDismiss:{notificationConversation=""}) {
            NavigationStack {MessagingView(initialInvitation:notificationConversation)}
        }
        .onChange(of: wallet.localWallet?.recoveryVerified) { _, verified in if verified == true { storedWallet = true } }
        .task { storedWallet = await WalletVault.shared.hasRecordedIdentity; if storedWallet || !wallet.address.isEmpty {WalletRelayLifecycle.enrollWallet()}; await wallet.loadAppCode(); identityLoaded = true; await openNotifiedConversation() }
        .fullScreenCover(item: $setupMode) { mode in NavigationStack { WalletSetupView(mode: mode) }.interactiveDismissDisabled(wallet.localWallet?.recoveryVerified == false) }
        .background(WindowActivityObserver { wallet.touch() }.frame(width: 0, height: 0))
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(isPresented: $watchEntry) { NavigationStack { WatchAddressEntryView() } }
        .alert("Unable to open wallet", isPresented: $showOnboardingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(wallet.notice ?? "Check device authentication and try again.")
        }
        .environmentObject(websiteDisplay)
    }
}
struct WatchAddressEntryView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet: WalletState
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                TextField("o1…", text: $address)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.none)
                    .accessibilityIdentifier("watch.address")
                if let error { Text(error).font(Theme.footnote).foregroundStyle(.orange) }
            } header: { Text("Public Parano1d address") }
            footer: { Text("Watch an address without importing its master key. This device cannot spend from a watch-only wallet.") }.themedRow()
            Section {
                Button("Start watching") {
                    do { try wallet.saveAddress(address); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.themedRow()
        }
        .navigationTitle("Watch an address")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
    }
}
struct WalletWelcome: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet: WalletState
    @State private var resetRequested = false
    @State private var discardRequested = false
    let create: () -> Void
    let recover: () -> Void
    let backup: () -> Void
    let watch: () -> Void
    let discard: () -> Void
    private var unfinished: Bool { wallet.localWallet?.recoveryVerified == false }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Brand().padding(.top, 16)
                    Spacer(minLength: 28)
                    Image("BrandWordmark").resizable().scaledToFit()
                        .frame(width:min(geometry.size.width - 44,310),height:230)
                        .frame(maxWidth:.infinity)
                        .accessibilityLabel("Parano1d World")
                    VStack(spacing: 14) {
                        Text(unfinished ? "Make it yours.\nKeep it safe." : wallet.recoveryRequired ? "Welcome back.\nRecover your wallet." : "Your world.\nYour wallet.")
                            .font(Theme.editorial(43)).fixedSize(horizontal: false, vertical: true)
                        Text(unfinished ? "Save and verify your master key to finish setting up your wallet." : "Create your Parano1d wallet or bring back an existing one. Your master key stays on this device.")
                            .font(.system(size: 15)).foregroundStyle(Theme.secondary).lineSpacing(5)
                    }.multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    Spacer(minLength: 16)
                    VStack(spacing: 12) {
                        if unfinished {
                            Button("Finish recovery backup", action: backup).buttonStyle(MintButtonStyle())
                            Button("Import an existing wallet", action: recover)
                                .font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 15)
                                .foregroundStyle(Theme.text).background(Theme.panel, in: Capsule()).overlay(Capsule().stroke(Theme.line))
                            Text("The unfinished wallet stays saved when you import another key. To start a different new wallet, remove this unfinished one first.")
                                .font(Theme.caption).foregroundStyle(Theme.secondary)
                            Button("Start a different new wallet") { discardRequested = true }
                                .font(Theme.footnote).foregroundStyle(.orange).frame(minHeight: 44)
                        } else {
                            if !wallet.recoveryRequired { Button("Create a new wallet", action: create).buttonStyle(MintButtonStyle()) }
                            Button("Import an existing wallet", action: recover)
                                .font(.system(size: 15, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 15)
                                .foregroundStyle(Theme.text).background(Theme.panel, in: Capsule()).overlay(Capsule().stroke(Theme.line))
                            if !wallet.recoveryRequired { Button("Watch an address", action: watch).font(Theme.footnote).foregroundStyle(Theme.secondary).frame(minHeight: 44) }
                        }
                        if wallet.recoveryRequired {
                            Button("Start over on this device") { resetRequested = true }
                                .font(Theme.footnote).foregroundStyle(.orange).frame(minHeight: 44)
                        }
                        if let notice = wallet.notice { Text(notice).font(Theme.caption).foregroundStyle(.orange) }
                        Text("Never share your master key. We cannot restore it for you.").font(.system(size: 11)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    }.disabled(wallet.authenticating)
                }.padding(.horizontal, 28).padding(.bottom, 20).frame(minHeight: geometry.size.height)
            }.background(AmbientBackground()).foregroundStyle(Theme.text)
        }.confirmationDialog("Reset missing wallet record?", isPresented: $resetRequested, titleVisibility: .visible) {
            Button("Clear missing device record", role: .destructive) { Task { await wallet.resetMissingIdentity() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Only use this if the original wallet key is unavailable and you intend to set up a different wallet. This cannot recover the previous wallet or its funds. Any saved wallet or pending payment blocks reset.")
        }
        .confirmationDialog("Start over with a new wallet?", isPresented: $discardRequested, titleVisibility: .visible) {
            Button("Remove local wallet", role: .destructive, action: discard)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This deletes the local key and address for this unfinished wallet. It does not move funds or remove any backup. Continue setup if this wallet has received assets or you want to keep it.")
        }
    }
}
struct WalletHome: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    @EnvironmentObject private var wallet: WalletState
    @EnvironmentObject private var live: LiveData
    @EnvironmentObject private var quotes: PriceFeed
    @EnvironmentObject private var node:DeviceNode
    @Environment(\.dynamicTypeSize) private var textSize
    private var selectedWalletName: String {
        guard let local = wallet.localWallet else { return "Watch-only address" }
        return local.profiles.first(where: { $0.address == local.selectedRoot })?.name ?? "Wallet"
    }
    private var verifiedBalance:String? {node.balance(for:wallet.address)}
    private var unverifiedEstimate:String? {
        guard !node.enabled,!wallet.offlineMode,live.error==nil,
              let updated=live.updated,Date().timeIntervalSince(updated)>=0,
              Date().timeIntervalSince(updated)<30 else{return nil}
        return live.balance
    }
    private var savedBalance:String? {
        guard let saved=node.lastBalance,saved.valid(for:wallet.address) else{return nil}
        return Amounts.format(saved.micronoid)
    }
    /// Public-explorer balance shown only until this device has a verified or saved balance.
    /// It is labelled as an estimate; sending still waits for the device node's verified State.
    /// Never used in Parano1d mode (peers only) or with the App VPN on: asking the explorer
    /// would break those promises, so they keep "Waiting for verification" instead.
    @State private var explorerEstimate:(address:String,value:String,at:Date)?
    @AppStorage("protection.appVPN.enabled.v1") private var appVPNOn = false
    private var estimateAllowed:Bool {!wallet.offlineMode && !wallet.locked && !homeParanoidLook && !appVPNOn}
    private var networkEstimate:String? {
        guard verifiedBalance==nil,savedBalance==nil,unverifiedEstimate==nil,estimateAllowed,
              let estimate=explorerEstimate,estimate.address==wallet.address,
              Date().timeIntervalSince(estimate.at)>=0,Date().timeIntervalSince(estimate.at)<600 else{return nil}
        return estimate.value
    }
    private func loadExplorerEstimate() async {
        let address=wallet.address
        guard verifiedBalance==nil,savedBalance==nil,estimateAllowed,AddressValidator.valid(address) else{return}
        if let estimate=explorerEstimate,estimate.address==address,Date().timeIntervalSince(estimate.at)<60 {return}
        guard let result=try? await ExplorerClient.shared.address(address),
              let raw=result["balance_micronoid"] as? String,let value=Amounts.format(raw),
              wallet.address==address,estimateAllowed else{return}
        explorerEstimate=(address,value,Date())
    }
    private var displayedBalance:String? {verifiedBalance ?? savedBalance ?? unverifiedEstimate ?? networkEstimate}
    private var estimateKey:String {"\(wallet.address)|\(verifiedBalance == nil && savedBalance == nil)|\(wallet.offlineMode)|\(wallet.locked)|\(homeParanoidLook)|\(appVPNOn)"}
    private var watchStatus: String {
        if verifiedBalance != nil, let height = node.balanceHeight { return "Verified · block \(height)" }
        if savedBalance != nil, let saved = node.lastBalance { return "Last verified · block \(saved.height)" }
        return "Waiting for verification"
    }
    private var watchSnapshotKey: String { [wallet.address, selectedWalletName, displayedBalance ?? "", watchStatus, String(wallet.hideBalances), String(wallet.locked)].joined(separator: "|") }
    @AppStorage("livePrices") private var livePrices = true
    @AppStorage("externalMedia") private var externalMedia = true
    @AppStorage(DisplayStyle.storageKey) private var homeStyle = "system"
    @AppStorage(ParanoidLook.key) private var homeParanoidLook = false
    @Binding var settings: Bool
    @State private var showReceive = false
    @State private var showMore = false
    @State private var showGallery = false
    @State private var tokenNames: [String: String] = [:]
    @AppStorage("asset.tokenNames.v1") private var rawTokenNames = Data()
    @AppStorage("nft.collectionNames.v1") private var rawCollectionNames = Data()
    @AppStorage("home.tokens.expanded") private var tokensExpanded = true
    @AppStorage("home.nfts.expanded") private var nftsExpanded = true
    @AppStorage("home.nfts.grid") private var homeNFTGrid = false
    @AppStorage("home.nfts.columns") private var homeNFTColumns = 2
    @State private var collapsedCollections:Set<String> = []
    /// NFTs a pending token/NFT transaction is using (shown greyed out and locked).
    @State private var pendingNFTKeys:Set<String> = []
    private func loadPendingNFTs() async {
        guard !wallet.locked,let root=wallet.accounts.first(where:{$0.index==0})?.address,
              let result=try? await NativeCore.shared.call(["op":"payment_pending","journal_directory":PaymentStorage.directory(root:root).path]) else {pendingNFTKeys=[];return}
        pendingNFTKeys=PendingLedger.pendingNFTs(result)
    }
    private var collectionNames:[String:String] {(try? JSONDecoder().decode([String:String].self,from:rawCollectionNames)) ?? [:]}
    /// Held NFTs plus this wallet's own listed NFTs (view-only, badged "Listed").
    private var ownedNFTs:[NativeItem] {
        var result:[String:NativeItem]=[:]
        for item in live.holdings where item.type == "nft" && item.text("owner") == wallet.address && !item.collection.isEmpty {result[item.nftDisplayID]=item}
        for item in live.listings where item.isListed(by:wallet.address) && !item.collection.isEmpty {result[item.nftDisplayID]=item}
        return Array(result.values)
    }
    private var ownedCollections:[String] {Set(ownedNFTs.map(\.collection)).sorted()}
    private func collectionName(_ id:String)->String {CollectionPresentation.name(id:id,collections:live.collections,names:collectionNames)}
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if wallet.localWallet == nil {
                    Panel {
                        Text("Watch-only address").font(Theme.headline)
                        Text("This address is not a local wallet. Add a master key to create a spend-capable wallet on this device.")
                            .font(Theme.caption).foregroundStyle(Theme.secondary)
                        NavigationLink("Import a wallet") { WalletSetupView(mode: .recover) }
                            .buttonStyle(MintButtonStyle())
                        NavigationLink("Create a new wallet") { WalletSetupView(mode: .create) }
                            .font(Theme.subheadline).foregroundStyle(Theme.mint)
                    }
                }
                if wallet.localWallet?.recoveryVerified == false {
                    Panel {
                        Text("Backup required").font(Theme.headline)
                        Text("Finish verifying this wallet's master key before sending funds or creating another wallet. Your other wallets remain saved.")
                            .font(Theme.caption).foregroundStyle(Theme.secondary)
                        NavigationLink("Finish recovery backup") { WalletSetupView(mode: .manage) }
                            .buttonStyle(MintButtonStyle())
                    }
                }
                HStack(spacing: 10) {
                    NavigationLink { AccountsView() } label: {
                        HStack(spacing: 5) {
                            PersonalAvatar(root: wallet.accounts.first(where: {$0.index == 0})?.address ?? wallet.address, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(selectedWalletName).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                                if wallet.localWallet != nil {
                                    Text(wallet.accounts.first(where: { $0.index == wallet.selectedIndex })?.name ?? "Account 1")
                                        .font(Theme.caption).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                                }
                            }
                            Image(systemName: "chevron.down").font(Theme.caption2)
                        }
                    }.disabled(wallet.localWallet == nil)
                    Spacer(minLength: 4)
                    NodeStatusBadge()
                }
                if DisplayStyle.read(homeStyle) == .world { worldHero } else if DisplayStyle.read(homeStyle).mono { pixelHero } else {
                if livePrices && !wallet.offlineMode, let price = quotes.currentPrice {
                    Text("NOID $" + String(NSDecimalNumber(decimal: price).stringValue.prefix(7))).font(.system(size: 12, weight: .semibold)).tracking(1.2)
                        .foregroundStyle(Theme.mint).padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Theme.panel, in: Capsule()).overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                        .frame(maxWidth: .infinity).padding(.top, 6).accessibilityLabel("NOID price")
                }
                VStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Text(wallet.localWallet == nil ? "WATCH-ONLY" : verifiedBalance != nil ? "VERIFIED NOID" : savedBalance != nil ? "LAST VERIFIED NOID" : unverifiedEstimate != nil ? "UNVERIFIED ESTIMATE" : networkEstimate != nil ? "ESTIMATE · VERIFYING" : "BALANCE UNAVAILABLE").font(.system(size: 10, weight: .medium)).tracking(2)
                        Button { wallet.hideBalances.toggle() } label: { Image(systemName: wallet.hideBalances ? "eye.slash" : "eye").font(.system(size: 13)).frame(width: 44, height: 44) }
                            .accessibilityLabel(wallet.hideBalances ? "Show balances" : "Hide balances")
                    }.foregroundStyle(Theme.secondary)
                    Text(wallet.amount(displayedBalance ?? "—")).font(Theme.editorial(48)).minimumScaleFactor(0.5).lineLimit(1).privacySensitive()
                    Text(livePrices && !wallet.offlineMode ? wallet.amount(quotes.usd(displayedBalance).map { "≈ " + $0 + " USD" } ?? (displayedBalance == nil ? "USD after the balance check" : "USD value unavailable")) : "USD estimate off").font(Theme.subheadline).foregroundStyle(Theme.secondary).privacySensitive()
                    if verifiedBalance != nil,let height=node.balanceHeight {
                        Text("Verified block \(height)").font(Theme.caption).foregroundStyle(Theme.secondary)
                    } else if savedBalance != nil,let saved=node.lastBalance {
                        Text("Last verified block \(saved.height) · \(saved.verifiedAt.formatted(date:.abbreviated,time:.shortened))").font(Theme.caption).foregroundStyle(Theme.secondary)
                        if node.phase == "Error" {
                            Text("Current verification failed. This saved balance may have changed. Open Device node for the cause and retry.")
                                .font(Theme.caption).foregroundStyle(.orange)
                        }
                    } else if networkEstimate != nil {
                        Text("From the public explorer while this device verifies the chain. Sending waits for the verified balance.").font(Theme.caption).foregroundStyle(Theme.secondary)
                    } else if node.enabled {
                        Text("Waiting for current, verified account data. An empty discovery is not a zero balance.").font(Theme.caption).foregroundStyle(Theme.secondary)
                    } else if GatewayConfiguration.saved != nil {FreshnessView().padding(.top,12)}
                    else {Text(node.error ?? node.phase).font(Theme.caption).foregroundStyle(Theme.secondary)}
                }.frame(maxWidth: .infinity).padding(.top, 10).padding(.bottom, 8)
                HStack(alignment: .top, spacing: 0) {
                    NavigationLink { SendView() } label: { action("Send",icon:"arrow.up.right") }.disabled(wallet.localWallet?.recoveryVerified != true)
                    Button { showReceive = true } label: { action("Receive", icon: "arrow.down") }
                    Button { showGallery = true } label: { action("NFT gallery", icon: "square.stack") }
                    Button { showMore = true } label: { action("More", icon: "ellipsis") }
                }.buttonStyle(.plain)
                }
                if !DisplayStyle.read(homeStyle).mono {
                NavigationLink {ReceiptLookupView(scope:.all)} label: {
                    HStack(spacing:14) {
                        Image(systemName:"checkmark.shield.fill")
                            .font(.system(size:23,weight:.medium))
                            .foregroundStyle(Theme.mint)
                            .frame(width:48,height:48)
                            .background(Theme.soft,in:RoundedRectangle(cornerRadius:16))
                        VStack(alignment:.leading,spacing:3) {
                            Text("Receipts").font(Theme.headline).foregroundStyle(Theme.mint)
                            Text("Saved payments · verify a receipt").font(Theme.caption).foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength:4)
                        Image(systemName:"arrow.right")
                            .font(Theme.subheadline.weight(.semibold)).foregroundStyle(Color(hex:0x03100A))
                            .frame(width:36,height:36).background(Theme.mint,in:Circle())
                    }.padding(15)
                        .themedCard(22)
                        .themedOutline(22, Theme.mint.opacity(0.45), 1)
                }.buttonStyle(.plain).accessibilityLabel("Receipts and payment verification")
                }
                NavigationLink { WalletSetupView() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: wallet.localWallet == nil ? "eye" : "checkmark.shield")
                        Text(wallet.localWallet == nil ? "Watching a public address" : wallet.localWallet?.recoveryVerified == true ? "Recovery backup verified" : "Recovery backup required").font(.system(size: 12))
                        Spacer(); Image(systemName: "chevron.right").font(Theme.caption2)
                    }.foregroundStyle(Theme.secondary).padding(.vertical, 12)
                }.overlay(alignment: .bottom) { Divider() }
                ActivityView(embedded:true).padding(.vertical, Theme.world ? 24 : 12).padding(.horizontal, Theme.world ? 24 : 0).background { if Theme.world { WorldFrame(kind: .auto) } }
                Divider()
                HStack {
                    SectionHeading(title:"Your assets")
                    Spacer()
                    Button {node.synchronize(unlocked:!wallet.locked,offline:wallet.offlineMode,force:true,owner:wallet.address)} label:{Image(systemName:"arrow.clockwise")}
                        .accessibilityLabel("Refresh verified assets")
                        .disabled(wallet.locked || wallet.offlineMode || node.running || !node.enabled)
                }
                if node.running {Text("Checking chain and asset State…").font(Theme.caption).foregroundStyle(Theme.secondary)}
                else if let chain=node.verifiedHeight,let state=node.nativeStateHeight,state < chain {
                    Text("Asset State at block \(state); chain at \(chain). New tokens and NFTs appear after State catches up and ownership verifies.")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                if let issue=node.nativeStateIssue {Text("Asset State update: \(issue)").font(Theme.caption).foregroundStyle(.orange)}
                NavigationLink {AssetActionsView()} label: {
                    HStack(spacing:12) {
                        Image("NOIDCoin").resizable().scaledToFit().frame(width:48,height:48)
                        VStack(alignment:.leading,spacing:4) {
                            Text("NOID").font(Theme.editorial(20))
                            Text("Native coin").font(Theme.caption).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        VStack(alignment:.trailing,spacing:4) {
                            Text(wallet.amount(displayedBalance ?? "—")).monospacedDigit().privacySensitive()
                            if livePrices && !wallet.offlineMode {
                                Text(wallet.amount(quotes.usd(displayedBalance) ?? "USD unavailable")).font(Theme.caption).foregroundStyle(Theme.secondary).privacySensitive()
                            }
                        }
                    }.padding(.vertical,10)
                }.buttonStyle(.plain)
                if let saved=live.savedSnapshotDate {
                    Text("Last saved token and NFT inventory · block \(live.savedHoldingsHeight.map { String($0) } ?? "—") · \(saved.formatted(date:.abbreviated,time:.shortened)). Refresh holdings before sending.")
                        .font(Theme.caption).foregroundStyle(Theme.secondary)
                }
                homeTokenSection
                homeNFTSection
                    .task(id:"\(wallet.address)-\(live.holdings.count)-\(wallet.locked)") {await loadPendingNFTs()}
                    .onReceive(NotificationCenter.default.publisher(for:PaymentReconciliation.changed)) {_ in Task {await loadPendingNFTs()}}
                if live.updated == nil && live.savedSnapshotDate == nil {
                    NavigationLink { DeviceNodeView() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.stack.3d.up")
                            Text("Synchronize native token and NFT holdings")
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                        }.font(Theme.caption).foregroundStyle(Theme.secondary).padding(.vertical, 10)
                    }
                } else if let error=live.error {
                    Text("Native holdings could not refresh: \(error)").font(Theme.caption).foregroundStyle(.orange)
                }
            }.id("\(homeStyle)-\(homeParanoidLook)").padding(.horizontal, 22).padding(.bottom, 160).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background(AmbientBackground()).foregroundStyle(Theme.text).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { Brand() }
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarLeading) { ParanoidModeButton() }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { lockButton }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { settingsButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) { ParanoidModeButton() }
                ToolbarItem(placement: .topBarTrailing) { lockButton }
                ToolbarItem(placement: .topBarTrailing) { settingsButton }
            }
        }
        .refreshable { node.synchronize(unlocked:!wallet.locked,offline:wallet.offlineMode,force:true,owner:wallet.address); let owner=wallet.address, offline=wallet.offlineMode; Task { await live.refreshAndWait(owner: owner, offline: offline) }; try? await Task.sleep(nanoseconds: 400_000_000) }
        .task(id: estimateKey) { await loadExplorerEstimate() }
        .task(id: watchSnapshotKey) {
            guard !wallet.locked, AddressValidator.valid(wallet.address) else { return }
            WatchBridge.shared.publish(address: wallet.address, walletName: selectedWalletName, balance: displayedBalance,
                                     status: watchStatus, hidden: wallet.hideBalances)
        }
        .sheet(isPresented: $showReceive) { ReceiveView() }
        .navigationDestination(isPresented: $showGallery) { CollectionsView() }
        .onChange(of:wallet.address) {_,_ in collapsedCollections=[]}
        .fullScreenCover(isPresented: $showMore) { NavigationStack { MoreView() } }
        .task(id:"\(externalMedia)-\(live.holdings.map(\.id).joined())") {
            let saved=(try? JSONDecoder().decode([String:String].self,from:rawTokenNames)) ?? [:]
            tokenNames=Dictionary(uniqueKeysWithValues:tokenPositions.compactMap { item in
                saved[item.text("metadata_hash")].map {(item.asset,$0)}
            })
            guard externalMedia && !wallet.offlineMode && !wallet.locked else{return}
            for item in tokenPositions {
                guard !Task.isCancelled else {return}
                if let display=try? await AssetMedia.shared.load(hash:item.text("metadata_hash")), !Task.isCancelled {
                    tokenNames[item.asset]=display.name
                    var names=(try? JSONDecoder().decode([String:String].self,from:rawTokenNames)) ?? [:]
                    names[item.text("metadata_hash")]=display.name
                    if names.count<=512,let bytes=try? JSONEncoder().encode(names) {rawTokenNames=bytes}
                }
            }
        }
        .task(id:"\(externalMedia)-\(live.collections.map { $0.text("metadata_hash") }.joined())") {
            guard externalMedia && !wallet.offlineMode && !wallet.locked else{return}
            for collection in live.collections where collectionNames[collection.text("metadata_hash")] == nil {
                let hash=collection.text("metadata_hash")
                guard !Task.isCancelled else{return}
                if let name=try? await AssetMedia.shared.loadName(hash:hash),!Task.isCancelled {
                    var names=collectionNames;names[hash]=name
                    if names.count<=512,let bytes=try? JSONEncoder().encode(names) {rawCollectionNames=bytes}
                }
            }
        }
    }
    @ViewBuilder private var homeTokenSection:some View {
        if !tokenPositions.isEmpty {
            Button {withAnimation {tokensExpanded.toggle()}} label: {
                HStack {
                    Text("Tokens").font(Theme.headline)
                    Text("\(tokenPositions.count)").font(Theme.caption).foregroundStyle(Theme.secondary)
                    Spacer()
                    Image(systemName:tokensExpanded ? "chevron.down" : "chevron.right").font(Theme.caption)
                }.padding(.top,6).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(tokensExpanded ? "Collapse tokens" : "Expand tokens")
            if tokensExpanded {
                ForEach(tokenPositions) { item in
                    NavigationLink { AssetActionsView(item:item) } label: {
                        HStack(spacing:12) {
                            AssetRowIcon(item:item,size:48,enabled:externalMedia && !wallet.locked,allowNetwork:!wallet.offlineMode)
                            VStack(alignment:.leading,spacing:4) {
                                Text(tokenNames[item.asset] ?? (String(item.asset.prefix(12)) + "…")).font(Theme.subheadline)
                                Text(tokenPrice(item) ?? "Native token").font(Theme.caption).foregroundStyle(Theme.secondary).monospacedDigit()
                            }
                            Spacer()
                            VStack(alignment:.trailing,spacing:4) {
                                Text(wallet.amount(Amounts.format(item.text("units")) ?? "—")).monospacedDigit().privacySensitive()
                                Text(wallet.amount(tokenUSD(item) ?? (displayedBalance == nil ? "USD after the balance check" : "USD value unavailable"))).font(Theme.caption).foregroundStyle(Theme.secondary).privacySensitive()
                            }
                        }.padding(.vertical,10).overlay(alignment:.top) {Divider()}
                    }.disabled(wallet.localWallet?.recoveryVerified != true)
                }
            }
        }
    }
    @ViewBuilder private var homeNFTSection:some View {
        if !ownedCollections.isEmpty {
            HStack {
                Button {withAnimation {nftsExpanded.toggle()}} label: {
                    HStack(spacing:7) {
                        Text("NFT collections").font(Theme.headline)
                        Text("\(ownedCollections.count)").font(Theme.caption).foregroundStyle(Theme.secondary)
                        Image(systemName:nftsExpanded ? "chevron.down" : "chevron.right").font(Theme.caption)
                    }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(nftsExpanded ? "Collapse NFT collections" : "Expand NFT collections")
                if nftsExpanded {NFTGridChoice(grid:$homeNFTGrid,columns:$homeNFTColumns)}
            }.padding(.top,6)
            if nftsExpanded {
                ForEach(ownedCollections,id:\.self) { id in
                    let items=ownedNFTs.filter{$0.collection == id}
                    HStack(spacing:12) {
                        Button {withAnimation {
                            if !collapsedCollections.insert(id).inserted {collapsedCollections.remove(id)}
                        }} label: {
                            HStack(spacing:12) {
                                if let cover=items.first {
                                    AssetRowIcon(item:cover,size:48,enabled:externalMedia && !wallet.locked,allowNetwork:!wallet.offlineMode)
                                }
                                VStack(alignment:.leading,spacing:4) {
                                    Text(collectionName(id)).font(Theme.subheadline).lineLimit(1)
                                    Text("\(items.count) NFT\(items.count == 1 ? "" : "s")").font(Theme.caption).foregroundStyle(Theme.secondary)
                                }
                                Spacer(minLength:6)
                                if let floor=collectionFloor(id) {
                                    VStack(alignment:.trailing,spacing:2) {
                                        Text("FLOOR").font(.system(size:9,weight:.semibold)).tracking(1.2).foregroundStyle(Theme.secondary)
                                        Text(floor).font(Theme.caption.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.mint)
                                    }.accessibilityElement(children:.combine).accessibilityLabel("Floor price \(floor)")
                                }
                                Spacer(minLength:0)
                                Image(systemName:collapsedCollections.contains(id) ? "chevron.right" : "chevron.down").font(Theme.caption)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(collapsedCollections.contains(id) ? "Expand \(collectionName(id))" : "Collapse \(collectionName(id))")
                        NavigationLink {CollectionsView(initialCollection:id)} label: {
                            Image(systemName:"arrow.up.right.square").frame(width:44,height:44)
                        }.accessibilityLabel("Open \(collectionName(id)) gallery")
                    }.padding(.vertical,10).overlay(alignment:.top){Divider()}
                    if !collapsedCollections.contains(id) {
                        // Organized: NFTs in your wallet first, then the ones you listed, each by number.
                        let sorted=items.sorted {
                            let a=$0.isListed(by:wallet.address),b=$1.isListed(by:wallet.address)
                            return a != b ? !a : (UInt64($0.text("serial")) ?? 0) < (UInt64($1.text("serial")) ?? 0)
                        }
                        if homeNFTGrid && !textSize.isAccessibilitySize {
                            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:10),count:min(4,max(2,homeNFTColumns))),spacing:10) {
                                ForEach(sorted,id:\.nftDisplayID) {item in homeNFTItem(item,grid:true)}
                            }
                        } else {
                            ForEach(sorted,id:\.nftDisplayID) {item in homeNFTItem(item,grid:false)}
                        }
                    }
                }
            }
        }
    }
    private func homeNFTItem(_ item:NativeItem,grid:Bool)->some View {
        let pending=pendingNFTKeys.contains(item.collection+"#"+item.text("serial"))
        return NavigationLink {NFTDetail(item:item)} label: {
            if grid {
                VStack(alignment:.leading,spacing:6) {
                    AssetThumbnail(item:item,enabled:externalMedia && !wallet.offlineMode && !wallet.locked,showsTitle:false)
                        .modifier(PendingNFTStyle(pending:pending))
                    HStack(spacing:6) {
                        Text("NFT #"+item.text("serial")).font(Theme.caption).lineLimit(1)
                        if item.isListed(by:wallet.address) {Spacer(minLength:0);ListedBadge()}
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).padding(8).themedCard(14)
            } else {
                HStack(spacing:12) {
                    AssetRowIcon(item:item,size:58,enabled:externalMedia && !wallet.locked,allowNetwork:!wallet.offlineMode)
                        .saturation(pending ? 0 : 1).opacity(pending ? 0.5 : 1)
                    VStack(alignment:.leading,spacing:3) {
                        Text("NFT #"+item.text("serial")).font(Theme.subheadline)
                        if pending { Label("Pending transfer · locked",systemImage:"lock.fill").font(Theme.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    if item.isListed(by:wallet.address) {ListedBadge()}
                }.padding(.leading,18).padding(.vertical,5)
            }
        }
    }
    private var tokenPositions: [NativeItem] {
        let groups = Dictionary(grouping: live.holdings.filter { $0.type == "token" && $0.text("owner") == wallet.address }, by: \.asset)
        return groups.keys.sorted().compactMap { asset in
            guard let entries = groups[asset], let first = entries.first else { return nil }
            var units: UInt64 = 0
            for entry in entries {
                guard let value = UInt64(entry.text("units")) else { return nil }
                let (sum, overflow) = units.addingReportingOverflow(value)
                guard !overflow else { return nil }; units = sum
            }
            var fields = first.fields; fields["units"] = String(units)
            return NativeItem(fields: fields)
        }
    }
    /// Price of one token in NOID (and USD when prices are on), from the verified on-chain pool.
    private func tokenPrice(_ item: NativeItem) -> String? {
        guard let market = live.markets.first(where: { $0.asset == item.asset }), let price = market.price else { return nil }
        let noid = price.formatted(.number.precision(.significantDigits(1...6)))
        if livePrices, !wallet.offlineMode, let usd = quotes.currentPrice,
           let each = PriceFeed.currency(Decimal(price) * usd) { return "\(noid) NOID · \(each)" }
        return "\(noid) NOID each"
    }
    /// Lowest current ask among verified listings in this collection.
    private func collectionFloor(_ id: String) -> String? {
        CollectionPresentation.floor(id, listings: live.listings)
    }
    private func tokenUSD(_ item: NativeItem) -> String? {
        guard livePrices, !wallet.offlineMode, let usd = quotes.currentPrice,
              let market = live.markets.first(where: { $0.asset == item.asset }),
              let units = Decimal(string: item.text("units")), let numerator = Decimal(string: market.text("price_numerator")),
              let denominator = Decimal(string: market.text("price_denominator")), denominator > 0 else { return nil }
        return PriceFeed.currency(units / 1_000_000 * numerator / denominator * usd)
    }
    private var settingsButton: some View {
        Button { settings = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: [Theme.soft, Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 0.7))
                .contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel("Settings")
    }
    private var lockButton: some View {
        Button { wallet.lock() } label: {
            Image(systemName: "lock.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.text)
                .frame(width: 36, height: 36)
                .background(LinearGradient(colors: [Theme.soft, Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 0.7))
                .contentShape(Circle())
        }.buttonStyle(.plain).accessibilityLabel("Lock wallet now")
    }
    /// Home in the pixel looks (Cyber and Parano1d World, docs/DESIGN-SPEC.md): corner brackets around the hero,
    /// the glowing pixel "1" emblem, the balance in Departure Mono, a status line, then chamfered buttons
    /// (Send is the accent-filled primary).
    @ViewBuilder private var pixelHero: some View {
        VStack(spacing: 14) {
            if livePrices && !wallet.offlineMode, let price = quotes.currentPrice {
                Text("NOID $" + String(NSDecimalNumber(decimal: price).stringValue.prefix(7))).font(Theme.pixel(13)).foregroundStyle(Theme.sky)
                    .padding(.horizontal, 16).padding(.vertical, 7).overlay(ChamferShape(cut: 6).stroke(Theme.line, lineWidth: 2)).accessibilityLabel("NOID price")
            }
            VStack(spacing: 12) {
                PixelEmblem().fill(Theme.mint).frame(width: 96, height: 96).shadow(color: Theme.glow, radius: 18).accessibilityHidden(true)
                HStack(spacing: 8) {
                    Text((wallet.localWallet == nil ? "Watch-only balance" : verifiedBalance != nil ? "Verified balance" : savedBalance != nil ? "Last verified balance" : "Balance"))
                        .font(Theme.pixel(12)).foregroundStyle(Theme.mint)
                    Button { wallet.hideBalances.toggle() } label: { Image(systemName: wallet.hideBalances ? "eye.slash" : "eye").font(.system(size: 13)).frame(width: 32, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(Theme.secondary).accessibilityLabel(wallet.hideBalances ? "Show balances" : "Hide balances")
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(wallet.amount(displayedBalance ?? "—")).font(Theme.pixel(42, .largeTitle))
                        .foregroundStyle(Theme.text).shadow(color: .white.opacity(0.13), radius: 9)
                        .minimumScaleFactor(0.4).lineLimit(1).privacySensitive()
                    Text("NOID").font(Theme.pixel(16)).foregroundStyle(Theme.mint)
                }
                Text(livePrices && !wallet.offlineMode ? wallet.amount(quotes.usd(displayedBalance).map { "≈ " + $0 + " USD" } ?? (displayedBalance == nil ? "USD after the balance check" : "USD value unavailable")) : "USD estimate off").font(Theme.pixel(13)).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
                HStack {
                    HStack(spacing: 6) {
                        Rectangle().fill(pixelHealthy ? Theme.mint : .orange).frame(width: 7, height: 7)
                        Text(pixelStatus).font(Theme.pixel(12)).foregroundStyle(pixelHealthy ? Theme.mint : .orange).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    Spacer(minLength: 8)
                    Text(pixelDetail).font(Theme.pixel(12)).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
                }
            }.padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 18).frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) { PixelCorner().stroke(Theme.mint, lineWidth: 4).frame(width: 30, height: 30) }
                .overlay(alignment: .topTrailing) { PixelCorner().stroke(Theme.mint, lineWidth: 4).frame(width: 30, height: 30).scaleEffect(x: -1) }
            if node.phase == "Error", savedBalance != nil {
                Text("Current verification failed. This saved balance may have changed. Open Device node for the cause and retry.").font(Theme.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                NavigationLink { SendView() } label: { ThemedLabel("Send", systemImage: "arrow.up.right") }.buttonStyle(MintButtonStyle())
                    .disabled(wallet.localWallet?.recoveryVerified != true)
                Button { showReceive = true } label: { ThemedLabel("Receive", systemImage: "arrow.down.left") }.buttonStyle(PixelOutlineButtonStyle())
            }
            HStack(spacing: 10) {
                Button { showGallery = true } label: { Text("NFTs") }.buttonStyle(PixelOutlineButtonStyle())
                NavigationLink { ReceiptLookupView(scope: .all) } label: { Text("Receipts") }.buttonStyle(PixelOutlineButtonStyle())
                Button { showMore = true } label: { Text("More") }.buttonStyle(PixelOutlineButtonStyle())
            }
            NavigationLink { NetworkStatusView() } label: { Text("Network check") }.buttonStyle(PixelOutlineButtonStyle())
        }
    }
    /// Home in the Parano1d World look: built from the game's own art. A framed command panel with the HQ,
    /// the balance and status, then game-icon tiles for the main actions.
    @ViewBuilder private var worldHero: some View {
        VStack(spacing: 12) {
            if livePrices && !wallet.offlineMode, let price = quotes.currentPrice {
                Text("NOID $" + String(NSDecimalNumber(decimal: price).stringValue.prefix(7))).font(.system(size: 12, weight: .heavy)).tracking(1.2)
                    .foregroundStyle(Theme.text).padding(.horizontal, 22).padding(.vertical, 9).background(WorldFrame(kind: .chip)).accessibilityLabel("NOID price")
            }
            ZStack(alignment: .trailing) {
                if let hq = WorldArt.image("hq", scale: 3) {
                    Image(uiImage: hq).resizable().scaledToFit().frame(width: 150).opacity(0.95).hueRotation(.degrees(ParanoidLook.enabled ? -62 : 0))
                        .shadow(color: Theme.mint.opacity(0.25), radius: 14).padding(.trailing, 18).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text((verifiedBalance != nil ? "Wallet balance" : savedBalance != nil ? "Last verified" : "Balance").uppercased())
                            .font(.system(size: 13, weight: .heavy)).tracking(1.5).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                        Button { wallet.hideBalances.toggle() } label: { Image(systemName: wallet.hideBalances ? "eye.slash" : "eye").font(.system(size: 13)).frame(width: 30, height: 26) }
                            .buttonStyle(.plain).foregroundStyle(Theme.secondary).accessibilityLabel(wallet.hideBalances ? "Show balances" : "Hide balances")
                    }
                    if wallet.localWallet == nil {
                        Text("WATCH-ONLY").font(.system(size: 9, weight: .heavy)).tracking(1.4).foregroundStyle(Theme.mint)
                            .padding(.horizontal, 7).padding(.vertical, 3).overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.mint.opacity(0.6), lineWidth: 1))
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(wallet.amount(displayedBalance ?? "—")).font(.system(size: 34, weight: .black)).monospacedDigit()
                            .foregroundStyle(Theme.text).shadow(color: .black, radius: 3).minimumScaleFactor(0.4).lineLimit(1).privacySensitive()
                        Text("NOID").font(.system(size: 14, weight: .heavy)).tracking(2).foregroundStyle(Theme.mint)
                    }
                    Text((livePrices && !wallet.offlineMode ? wallet.amount(quotes.usd(displayedBalance).map { "≈ " + $0 + " USD" } ?? (displayedBalance == nil ? "USD after the balance check" : "USD value unavailable")) : "USD estimate off").uppercased()).font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(Theme.secondary).lineLimit(1).minimumScaleFactor(0.7).privacySensitive()
                    HStack(spacing: 6) {
                        Circle().fill(pixelHealthy ? Theme.mint : .orange).frame(width: 7, height: 7).shadow(color: pixelHealthy ? Theme.mint : .orange, radius: 3)
                        Text(pixelStatus.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(pixelHealthy ? Theme.mint : .orange)
                    }
                    Text(pixelDetail.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1).foregroundStyle(Theme.secondary).lineLimit(1).privacySensitive()
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 120)
            }.padding(.horizontal, 26).padding(.vertical, 30).frame(maxWidth: .infinity).frame(minHeight: 190).background(WorldFrame(kind: .panel))
            if node.phase == "Error", savedBalance != nil {
                Text("Current verification failed. This saved balance may have changed. Open Device node for the cause and retry.").font(Theme.caption).foregroundStyle(.orange)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                NavigationLink { SendView() } label: { worldTile("Send", icon: "send", lit: true) }.disabled(wallet.localWallet?.recoveryVerified != true)
                Button { showReceive = true } label: { worldTile("Receive", icon: "receive") }
                Button { showGallery = true } label: { worldTile("NFTs", icon: "nfts") }
                NavigationLink { ReceiptLookupView(scope: .all) } label: { worldTile("Receipts", icon: "receipts") }
                NavigationLink { NetworkStatusView() } label: { worldTile("Network", icon: "network") }
                Button { showMore = true } label: { worldTile("More", icon: "more") }
            }.buttonStyle(.plain)
        }
    }
    /// Game action tile: a game icon over a capital label, in the game's metal frame; Send is lit lime.
    private func worldTile(_ title: String, icon: String, lit: Bool = false) -> some View {
        VStack(spacing: 4) {
            WorldIcon(tab: icon, size: 54)
            Text(title.uppercased()).font(.system(size: 12, weight: .heavy)).tracking(1.4).foregroundStyle(lit ? Theme.accent2 : Theme.text)
        }.frame(maxWidth: .infinity).frame(height: 112)
            .background(WorldFrame(kind: .panel))
            .overlay { if lit { RoundedRectangle(cornerRadius: 12).stroke(Theme.mint.opacity(0.55), lineWidth: 1.5).padding(10).shadow(color: Theme.mint.opacity(0.5), radius: 6) } }
            .contentShape(Rectangle())
    }
    private var pixelHealthy: Bool { node.error == nil && !wallet.offlineMode }
    private var pixelStatus: String {
        if wallet.offlineMode { return "Offline · saved" }
        if node.running { return "Verifying" }
        if verifiedBalance != nil, node.balanceHeight != nil { return "Verified" }
        return node.error == nil ? node.phase : "Not verified"
    }
    private var pixelDetail: String {
        if verifiedBalance != nil, let height = node.balanceHeight { return "Block \(height)" }
        if savedBalance != nil, let saved = node.lastBalance { return "Saved · block \(saved.height)" }
        if livePrices && !wallet.offlineMode, let usd = quotes.usd(displayedBalance) { return wallet.amount("≈ " + usd) }
        return wallet.localWallet == nil ? "Public address" : "Not yet verified"
    }
    private func action(_ title: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 19, weight: .light)).frame(width: 48, height: 48)
                .background(LinearGradient(colors: [Theme.mint.opacity(0.12), Theme.panel], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .overlay(Circle().stroke(Theme.line, lineWidth: 0.7))
            Text(title).font(.system(size: 11))
        }.foregroundStyle(Theme.text).frame(maxWidth: .infinity).padding(.vertical,8).contentShape(Rectangle())
    }
}
struct PrivacyView: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) {
            Text("Privacy").font(Theme.editorial(38))
            Panel { Label("Your keys stay on this device", systemImage: "key").font(Theme.headline); Text("Your master key is created and stored on this device, protected by the iOS Keychain and your device passcode or Face ID. It is never sent to us. We cannot recover it, so keep your backup safe.") }
            Panel { Label("No accounts, no analytics", systemImage: "chart.bar.xaxis").font(Theme.headline); Text("There is no sign-up and no tracking or advertising. The app does not collect analytics.") }
            Panel { Label("Public blockchain", systemImage: "eye").font(Theme.headline); Text("NOID transactions are public. Amounts and addresses are visible on the chain to anyone; this app cannot hide on-chain activity.") }
            Panel { Label("Network requests", systemImage: "network").font(Theme.headline); Text("The on-device node talks directly to Parano1d peers, sometimes briefly in the background when iOS allows it. With Connection set to Endpoint, balance and payment lookups use a Parano1d node service, which sees your public address and IP address. Turn on Offline mode in Settings to stop all internet access.") }
            Panel { Label("Mining", systemImage: "cpu").font(Theme.headline); Text("Mining runs on your own computers; this phone never mines. To show status and send Start or Stop, the phone talks to your computers through parano1dworld.com, signed with a key that stays on this phone. Mining alerts check your computers in the background when iOS allows it, at most about every 15 minutes, only if you turn them on. None of this runs in Offline mode.") }
            Panel { Label("Private messages", systemImage: "message").font(Theme.headline); Text("Messages are end-to-end encrypted between connected contacts. If you turn on online delivery, the relay stores encrypted packets and sees sender and recipient identities, not message text. Instant alerts are off unless you turn them on, and never include message text. Nearby relay is off unless you turn it on.") }
            Link(destination: URL(string: "https://parano1dworld.com/privacy")!) { Label("Read the full privacy policy", systemImage: "arrow.up.right") }.font(Theme.headline).foregroundStyle(Theme.mint)
        }.padding(22).frame(maxWidth:720).frame(maxWidth:.infinity) }.background(AmbientBackground()).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .principal) { Brand() } }
    }
}

/// Payment links from other apps and sites (for example a Parano1d World coin quote):
/// `paramo1d://pay?to=<o1 address>&amount=<NOID>`. Only a valid address and amount are accepted;
/// anything else in the link is ignored. The link never sends by itself.
enum PayLink {
    static func parse(_ url: URL) -> WatchHandoffRequest? {
        guard url.scheme?.lowercased() == "paramo1d", url.host?.lowercased() == "pay",
              url.absoluteString.count <= 300,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let to = items.first(where: { $0.name == "to" })?.value?.trimmingCharacters(in: .whitespaces),
              AddressValidator.valid(to) else { return nil }
        let raw = items.first(where: { $0.name == "amount" })?.value?.trimmingCharacters(in: .whitespaces) ?? ""
        let amount = raw.isEmpty ? "" : (Amounts.parse(raw) != nil && raw.count <= 24 ? raw : "")
        if !raw.isEmpty && amount.isEmpty { return nil }
        return WatchHandoffRequest(address: to, amount: amount)
    }
}
/// A payment the Apple Watch couldn't approve alone, opened in the iPhone Send review.
struct WatchHandoffRequest: Identifiable {
    let id = UUID()
    let address: String
    let amount: String
}

