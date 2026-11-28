import XCTest
import CryptoKit
@testable import Paranoid

final class SharedAvatarTests: XCTestCase {
    func testCharacterPresetsProduceShareableRecipes() throws {
        for name in CharacterAvatarConfiguration.presets where name != "Custom" {
            let recipe=CharacterAvatarConfiguration.preset(name,from:.init())
            let avatar=SharedAvatar(kind:"character",character:recipe)
            XCTAssertTrue(avatar.valid,name)
            XCTAssertNotNil(SharedAvatar.parse(try avatar.message()),name)
        }
    }
    func testAvatarInventoryIncludesOwnedAndListedWithoutDuplicating() {
        let owner="my-public-address"
        let listed=NativeItem(fields:["type":"nft_listing","collection_id":"collection","serial":"9","seller":owner,"metadata_hash":String(repeating:"a",count:64)])
        let held=NativeItem(fields:["type":"nft","collection_id":"collection","serial":"9","owner":owner,"metadata_hash":String(repeating:"a",count:64)])
        XCTAssertEqual(AvatarNFTInventory.candidates(holdings:[],listings:[listed],owner:owner).count,1)
        let candidates=AvatarNFTInventory.candidates(holdings:[held],listings:[listed],owner:owner)
        XCTAssertEqual(candidates.count,1)
        XCTAssertEqual(candidates.first?.type,"nft")
        XCTAssertTrue(AvatarNFTInventory.candidates(holdings:[],listings:[listed],owner:"other").isEmpty)
    }
    func testOnlyBoundedValidatedRecipesAreRecognized() throws {
        let avatar = SharedAvatar(kind:"monogram",letters:"GJ")
        XCTAssertEqual(SharedAvatar.parse(try avatar.message()),avatar)
        XCTAssertNil(SharedAvatar.parse(SharedAvatar.prefix + "{}"))
        XCTAssertNil(SharedAvatar.parse(String(repeating:"x",count:4097)))
        XCTAssertFalse(SharedAvatar(kind:"website",metadataHash:"https://example.com").valid)
        XCTAssertFalse(SharedAvatar(kind:"monogram",letters:"TOO LONG").valid)
        XCTAssertFalse(SharedAvatar(kind:"symbol",symbol:"unknown.symbol").valid)
        var invalid = avatar; invalid.version = 2
        XCTAssertFalse(invalid.valid)
    }
    func testCharacterOptionsAreValidatedAndOrdinaryTextPreserved() throws {
        var avatar = SharedAvatar(kind:"character",character:CharacterAvatarConfiguration())
        XCTAssertTrue(avatar.valid)
        avatar.character?.hair = "unsupported"
        XCTAssertFalse(avatar.valid)
        XCTAssertEqual(SharedAvatar.displayText("hello 👋"),"hello 👋")
        XCTAssertEqual(AvatarInitials.text(" Ada Lovelace "),"AL")
        XCTAssertEqual(AvatarInitials.text("Nemo"),"N")
        XCTAssertEqual(AvatarInitials.text(""),"?")
    }
    func testWalletCiphertextAndWrapperReferencesAreAuthenticated() throws {
        let key = SymmetricKey(size:.bits256), bytes = Data("synthetic test portfolio".utf8)
        let device = UUID().uuidString, pin = UUID().uuidString
        let record = try AlternateWalletProtection.seal(bytes,key:key,deviceKey:device,pinKey:pin)
        XCTAssertEqual(try record.decrypt(using:key),bytes)
        XCTAssertThrowsError(try record.decrypt(using:SymmetricKey(size:.bits256)))
        let changedReference = AlternateWalletProtection.Envelope(version:2,deviceKey:device,pinKey:UUID().uuidString,sealed:record.sealed)
        XCTAssertThrowsError(try changedReference.decrypt(using:key))
        var corrupt = record.sealed; corrupt[corrupt.startIndex] ^= 1
        let changedBytes = AlternateWalletProtection.Envelope(version:2,deviceKey:device,pinKey:pin,sealed:corrupt)
        XCTAssertThrowsError(try changedBytes.decrypt(using:key))
    }
    func testPrivateSelectionsDoNotLeakToAnotherWalletOrPublicView() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store = PeerAvatarStore(baseDirectory:directory)
        let identity = String(repeating:"a",count:64)
        let avatar = SharedAvatar(kind:"monogram",letters:"GJ")
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        try await store.accept(avatar,identity:identity,createdMS:now,messageID:String(repeating:"b",count:64),scope:"private:wallet-a")
        let own = await store.avatar(identity:identity,root:"wallet-a",publicOnly:false)
        let other = await store.avatar(identity:identity,root:"wallet-b",publicOnly:false)
        let publicView = await store.avatar(identity:identity,root:"wallet-a",publicOnly:true)
        XCTAssertEqual(own,avatar); XCTAssertNil(other); XCTAssertNil(publicView)
        let old = SharedAvatar(kind:"symbol",symbol:"cat.fill")
        try await store.accept(old,identity:identity,createdMS:now - 1,messageID:String(repeating:"c",count:64),scope:"private:wallet-a")
        let unchanged = await store.avatar(identity:identity,root:"wallet-a",publicOnly:false)
        XCTAssertEqual(unchanged,avatar)
        let reopened = PeerAvatarStore(baseDirectory:directory)
        let persisted = await reopened.avatar(identity:identity,root:"wallet-a",publicOnly:false)
        XCTAssertEqual(persisted,avatar)
    }
    func testInterruptedPINChangeHeaderIsAuthenticated() throws {
        let key = SymmetricKey(size:.bits256), bytes = Data("test".utf8)
        let record = try AlternateWalletProtection.seal(bytes,key:key,deviceKey:UUID().uuidString,pinKey:UUID().uuidString,previousPinKey:UUID().uuidString)
        XCTAssertEqual(try record.decrypt(using:key),bytes)
        var tampered = record; tampered.previousPinKey = nil
        XCTAssertThrowsError(try tampered.decrypt(using:key))
    }

    func testTabMigrationKeepsSupportedChoicesAndDropsWebsiteSlots() {
        // App Store edition: only the four public tabs exist (no trade or website tabs).
        XCTAssertEqual(Set(WalletTab.allCases),[.nfts,.chat,.ecosystem,.mining])
        // App Store edition: the tab layout is fixed. A layout saved by an older
        // install (including Trade or website tabs) never brings those tabs back.
        XCTAssertEqual(TabLayout.read("chat,website1,octonoid"),[.nfts,.chat,.ecosystem])
        XCTAssertEqual(TabLayout.read("trade,chat,nfts"),[.nfts,.chat,.ecosystem])
        XCTAssertEqual(TabLayout.read("trade,trade,trade"),[.nfts,.chat,.ecosystem])
        XCTAssertEqual(Set(TabLayout.read("nfts,nfts,website2")).count,3)
        XCTAssertFalse(WalletTab.allCases.map(\.rawValue).contains("website1"))
    }

}
