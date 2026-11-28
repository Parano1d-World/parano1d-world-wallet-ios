import SwiftUI
import CryptoKit

/// A bounded avatar recipe carried inside the existing signed/encrypted Text message.
/// The sender identity and timestamp MUST come from native envelope verification.
struct SharedAvatar: Codable, Equatable {
    static let allowedSymbols = ["person.fill","cat.fill","bolt.fill","leaf.fill","moon.stars.fill","sparkles","shield.fill"]
    static let prefix = "Parano1d avatar v1: "
    var version = 1
    var kind: String
    var letters: String = ""
    var symbol: String = "person.fill"
    var color: String = "Green"
    var character: CharacterAvatarConfiguration? = nil
    var metadataHash: String = ""
    var collection: String = ""
    var serial: String = ""
    static func hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    var valid: Bool {
        guard version == 1, ["initials","monogram","symbol","character","nft"].contains(kind),
              ["Green","Cyan","Purple","Orange","Pink"].contains(color),
              Self.allowedSymbols.contains(symbol), letters.count <= 3,
              letters.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        // NFT ownership does not unlock features in the public edition.
        if kind == "nft" { return false }
        if kind == "nft" {
            guard Self.hex(metadataHash), Self.hex(collection), !serial.isEmpty, serial.count <= 20,
                  serial.allSatisfy({ $0.isASCII && $0.isNumber }), UInt64(serial) != nil else { return false }
        } else if !metadataHash.isEmpty || !collection.isEmpty || !serial.isEmpty { return false }
        if kind == "character" {
            guard let c = character else { return false }
            typealias O = CharacterAvatarOptions
            return (O.styles.contains(c.style) || O.legacyStyles.contains(c.style))
                && (c.rendering == nil || ["Vector","Pixel"].contains(c.rendering!))
                && (c.pixelTheme == nil || O.pixelThemes.contains(c.pixelTheme!))
                && (O.presentations.contains(c.presentation) || O.legacyPresentations.contains(c.presentation))
                && (O.faces.contains(c.face) || O.legacyFaces.contains(c.face))
                && CharacterAvatarConfiguration.skinColors[c.skin] != nil
                && CharacterAvatarConfiguration.hairColors[c.hairColor] != nil
                && O.hairstyles.contains(c.hair)
                && O.facialHair.contains(c.facialHair)
                && O.expressions.contains(c.eyes)
                && O.accessories.contains(c.accessory)
                && (c.jewelry == nil || (c.jewelry != "None" && O.jewelry.contains(c.jewelry!)))
                && O.clothing.contains(c.clothing)
                && O.accents.contains(c.accent)
                && O.backgrounds.contains(c.background)
        }
        return character == nil
    }
    static func parse(_ text: String) -> Self? {
        guard text.utf8.count <= 4096, text.hasPrefix(prefix),
              let bytes = String(text.dropFirst(prefix.count)).data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: bytes), value.valid else { return nil }
        return value
    }
    func message() throws -> String {
        guard valid else { throw AppFailure("Select a valid avatar before sharing.") }
        let text = Self.prefix + String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
        guard text.utf8.count <= 4096 else { throw AppFailure("Avatar exceeds the message limit.") }
        return text
    }
    static func displayText(_ text: String) -> String {
        guard let avatar = parse(text) else { return text }
        return avatar.kind == "nft" ? "Shared an NFT avatar · #\(avatar.serial). This image is not proof of current ownership." : "Shared a selected avatar."
    }
    @MainActor static func selected(root: String, holdings: [NativeItem], listings: [NativeItem] = [], owner: String, verified: Bool, listingsVerified: Bool = false) throws -> Self {
        guard !root.isEmpty else { throw AppFailure("Set up your chat identity first.") }
        let defaults = UserDefaults.standard
        func setting(_ key: String, _ fallback: String = "") -> String { defaults.string(forKey: "profile.avatar." + key + "." + root) ?? fallback }
        var mode = setting("mode", "legacy")
        if mode == "legacy" {
            if !setting("nft").isEmpty { mode = "nft" }
            else if !setting("character").isEmpty { mode = "character" }
            else { mode = setting("symbol", "person.fill") == "person.fill" ? "initials" : "symbol" }
        }
        var result = Self(kind: mode, color: setting("color", "Green"))
        switch mode {
        case "monogram": result.letters = setting("monogram"); if result.letters.isEmpty { result.kind = "initials" }
        case "symbol": result.symbol = setting("symbol", "person.fill")
        case "character": result.character = CharacterAvatarConfiguration.decode(setting("character"))
        case "nft":
            let item=AvatarNFTInventory.candidates(holdings:verified ? holdings : [],listings:listingsVerified ? listings : [],owner:owner)
                .first {AvatarNFTInventory.key($0,owner:owner) == setting("nft")}
            guard let item else { throw AppFailure("Refresh verified NFT holdings or listings before sharing this avatar.") }
            result.metadataHash = item.text("metadata_hash"); result.collection = item.collection; result.serial = item.text("serial")
        default: break
        }
        guard result.valid else { throw AppFailure("Your avatar selection is unavailable or invalid. Open avatar settings to choose again.") }
        return result
    }
}

actor PeerAvatarStore {
    static let shared = PeerAvatarStore()
    static let changed = Notification.Name("PeerAvatarChanged")
    private let baseDirectory: URL?
    init(baseDirectory: URL? = nil) { self.baseDirectory = baseDirectory }
    struct Record: Codable {
        let avatar: SharedAvatar
        let createdMS: UInt64
        let messageID: String
    }
    private func file(scope: String) throws -> URL {
        let directory: URL
        if let baseDirectory { directory = baseDirectory }
        else { directory = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("PeerAvatars",isDirectory:true) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(scope.utf8)).map { String(format:"%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    private func read(scope: String) throws -> [String:Record] {
        let url = try file(scope: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 524288 else { throw AppFailure("Avatar cache exceeds its limit.") }
        let rows = try JSONDecoder().decode([String:Record].self, from: Data(contentsOf: url))
        guard rows.count <= 256 else { throw AppFailure("Avatar cache exceeds its limit.") }
        return rows.filter { SharedAvatar.hex($0.key) && $0.value.avatar.valid && SharedAvatar.hex($0.value.messageID) }
    }
    /// Call only after native signature/decryption verification; never use a name as an identity.
    func accept(_ avatar: SharedAvatar, identity: String, createdMS: UInt64, messageID: String, scope: String) async throws {
        guard avatar.valid, SharedAvatar.hex(identity), SharedAvatar.hex(messageID), !scope.isEmpty,
              createdMS > 0, createdMS <= UInt64(Date().timeIntervalSince1970 * 1000) + 300000 else { return }
        var rows = try read(scope: scope)
        if let prior = rows[identity] {
            guard createdMS > prior.createdMS || (createdMS == prior.createdMS && messageID > prior.messageID) else { return }
        }
        rows[identity] = Record(avatar: avatar, createdMS: createdMS, messageID: messageID)
        if rows.count > 256, let oldest = rows.min(by: { $0.value.createdMS < $1.value.createdMS })?.key { rows.removeValue(forKey: oldest) }
        let bytes = try JSONEncoder().encode(rows)
        guard bytes.count <= 524288 else { throw AppFailure("Avatar cache exceeds its limit.") }
        var url = try file(scope: scope)
        try bytes.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
        await MainActor.run { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
    func avatar(identity: String, root: String?, publicOnly: Bool) async -> SharedAvatar? {
        // A private selection is visible only inside this wallet's private/contact screens.
        if !publicOnly, let root, !root.isEmpty, let rows = try? read(scope: "private:" + root), let record = rows[identity] { return record.avatar }
        guard let rows = try? read(scope:"public"), let record = rows[identity] else { return nil }
        let hidden = await MainActor.run { PublicModerationStore.shared.restriction(messageID:record.messageID,identity:identity) != nil }
        return hidden ? nil : record.avatar
    }

}

struct PeerAvatar: View {
    let identity: String
    let name: String
    var size: CGFloat = 48
    var publicOnly = false
    var fallbackIcon = "initials"
    @EnvironmentObject private var wallet: WalletState
    @AppStorage("externalMedia") private var artwork = true
    @State private var selection: SharedAvatar?
    @State private var image: UIImage?
    @ObservedObject private var moderation = PublicModerationStore.shared
    private var root: String { wallet.accounts.first(where: { $0.index == 0 })?.address ?? "" }
    private var fallback:some View {ContactIconView(name:name,icon:fallbackIcon,size:size)}
    var body: some View {
        Group {
            if let selection, !wallet.locked {
                switch selection.kind {
                case "character":
                    CharacterAvatarArt(configuration: selection.character ?? CharacterAvatarConfiguration())
                case "monogram":
                    Text(selection.letters).font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                        .frame(width: size, height: size).foregroundStyle(PersonalAvatar.tint(selection.color))
                        .background(PersonalAvatar.tint(selection.color).opacity(0.14))
                case "symbol":
                    Image(systemName: selection.symbol).font(.system(size: size * 0.43, weight: .semibold))
                        .frame(width: size, height: size).foregroundStyle(PersonalAvatar.tint(selection.color))
                        .background(PersonalAvatar.tint(selection.color).opacity(0.14))
                case "nft":
                    if artwork, let image { Image(uiImage: image).resizable().scaledToFill() }
                    else { fallback }
                default: fallback
                }
            } else { fallback }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: selection?.character?.style == "Pixel" ? size * 0.22 : size / 2))
            .accessibilityLabel("Avatar for " + name)
            .task(id: "\(identity)-\(root)-\(wallet.locked)-\(publicOnly)") { await reload() }
            .onChange(of:moderation.status) { _,_ in Task { await reload() } }
            .onReceive(NotificationCenter.default.publisher(for: PeerAvatarStore.changed).receive(on:RunLoop.main)) { _ in Task { await reload() } }
            .task(id: "\(selection?.metadataHash ?? "")-\(artwork)-\(wallet.offlineMode)-\(wallet.locked)") {
                image = nil
                guard artwork, !wallet.offlineMode, !wallet.locked, let hash = selection?.metadataHash, SharedAvatar.hex(hash) else { return }
                if let loaded = try? await AssetMedia.shared.load(hash: hash), !Task.isCancelled, !wallet.locked, artwork, selection?.metadataHash == hash { image = loaded.image }
            }
            .onDisappear { image = nil; selection = nil }
    }
    private func reload() async {
        guard !wallet.locked else { selection = nil; image = nil; return }
        let expectedRoot = root
        let value = await PeerAvatarStore.shared.avatar(identity: identity, root: root, publicOnly: publicOnly)
        guard !Task.isCancelled, !wallet.locked, root == expectedRoot else { return }
        selection = value
    }
}
