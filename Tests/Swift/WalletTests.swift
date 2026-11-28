import XCTest
import LocalAuthentication
@testable import Paranoid

final class MemoryWalletStorage: WalletRecordStorage {
    var data: Data?
    var inserts = 0
    var failWrite = false
    var discardUpdates = false
    func read(context: LAContext) throws -> Data? { data }
    func insert(_ bytes: Data, context: LAContext) throws {
        if failWrite { throw AppFailure("storage failure") }
        guard data == nil else { throw AppFailure("duplicate") }
        inserts += 1; data = bytes
    }
    func update(_ bytes: Data, context: LAContext) throws {
        guard data != nil else { throw AppFailure("not found") }
        if !discardUpdates { data = bytes }
    }
    func delete() throws { data = nil }
}
final class MemoryWalletIdentity: WalletIdentityStorage {
    var expectedAddress: String?
    func remember(_ address: String) throws {
        if let old=expectedAddress, old != address { throw AppFailure("identity mismatch") }
        expectedAddress=address
    }
    func forget() throws { expectedAddress = nil }
}
final class WalletTests: XCTestCase {
    func testNodeHeaderNeverClaimsStaleOrFailedVerificationIsSynced() {
        let now = Date()
        func status(_ phase: String, _ checked: Date?, error: String? = nil) -> NodeHeaderStatus {
            NodeHeaderStatus.current(enabled: true, offline: false, framework: true,
                phase: phase, error: error, verifiedAt: checked, now: now)
        }
        XCTAssertEqual(status("Verified boundary", now.addingTimeInterval(-40)), .synced)
        XCTAssertEqual(status("Verified boundary", now.addingTimeInterval(-121)), .offline)
        XCTAssertEqual(status("Verifying", now.addingTimeInterval(-40)), .synchronizing)
        XCTAssertEqual(status("Error", now, error: "No peers"), .needsAttention)
        XCTAssertEqual(NodeHeaderStatus.current(enabled: true, offline: true, framework: true,
            phase: "Verified boundary", error: nil, verifiedAt: now, now: now), .offline)
        XCTAssertEqual(NodeHeaderStatus.current(enabled: false, offline: false, framework: true,
            phase: "Verified boundary", error: nil, verifiedAt: now, now: now), .offline)
    }
    func testAddressChecksumAndPadding() {
        XCTAssertTrue(AddressValidator.valid("o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7m"))
        XCTAssertFalse(AddressValidator.valid("o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7q"))
    }
    func testContactQRIsDistinctFromPaymentAddress() {
        let invitation = "paramo1d://contact/fixture"
        XCTAssertEqual(ScannedContactInvitation.parse(invitation), invitation)
        XCTAssertEqual(ScannedContactInvitation.parse("Let's connect in Parano1d. Add my invitation:\nparamo1d://contact/ fixt\nure"), invitation)
        XCTAssertTrue(ScannedContactInvitation.candidates("paramo1d://contact/ fixt-\nure").contains(invitation))
        XCTAssertTrue(ScannedContactInvitation.candidates("Let's connect. Add mine:\nparamo1d://contact/ fixt\nure\n\nparamo1d://contact/fixture").contains(invitation))
        XCTAssertEqual(ScannedContactInvitation.parse("eyJjb250YWN0Ijo"),"paramo1d://contact/eyJjb250YWN0Ijo")
        XCTAssertEqual(ScannedContactInvitation.parse("paramo1d://contact/fixture\nThen send yours back."),invitation)
        XCTAssertNil(ScannedAddress.parse(invitation))
        let address="o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7m"
        XCTAssertEqual(ScannedAddress.parse(" \n"+address+" "),address)
        XCTAssertNil(ScannedContactInvitation.parse(address))
        XCTAssertNil(ScannedAddress.parse("https://example.com/pay?to="+address))
        XCTAssertNil(ScannedAddress.parse(String(repeating:"x",count:257)))
        XCTAssertNil(ScannedContactInvitation.parse("https://example.com/contact"))
        XCTAssertNil(ScannedContactInvitation.parse(String(repeating: "x", count: 4097)))
    }
    func testLastBalanceDisplayNeverAcceptsAnotherWalletOrFutureTimestamp() {
        let owner="o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7m"
        let valid=LastBalanceSnapshot(owner:owner,micronoid:"1000000",height:123,
            blockHash:String(repeating:"a",count:64),verifiedAt:Date().addingTimeInterval(-60))
        XCTAssertTrue(valid.valid(for:owner))
        XCTAssertFalse(valid.valid(for:"o1mkkwhlqj7hgaljlacl7lgrs7g7vshrectev6cxw3ccuja0up9flsu9hd7q"))
        XCTAssertFalse(LastBalanceSnapshot(owner:owner,micronoid:"1000000",height:123,
            blockHash:String(repeating:"a",count:64),verifiedAt:Date().addingTimeInterval(600)).valid(for:owner))
        XCTAssertFalse(LastBalanceSnapshot(owner:owner,micronoid:"bad",height:123,
            blockHash:String(repeating:"a",count:64),verifiedAt:Date()).valid(for:owner))
    }
    func testExactAmounts() {
        XCTAssertEqual(Amounts.parse("1.000001"),"1000001")
        XCTAssertEqual(Amounts.format("18446744073709551615"),"18446744073709.551615")
        for value in ["1e3","-1","1.1234567","18446744073709.551616"] { XCTAssertNil(Amounts.parse(value)) }
    }
    func testCreationIsIdempotentAndBackupInitiallyUnverified() async throws {
        try XCTSkipUnless(NativeCore.available,"Build project-native.yml to execute native wallet tests")
        let storage=MemoryWalletStorage(),context=LAContext()
        let vault=WalletVault(storage:storage,identity:MemoryWalletIdentity())
        let a=try await vault.create(context:context), b=try await vault.create(context:context)
        XCTAssertEqual(a.address,b.address);XCTAssertEqual(storage.inserts,1);XCTAssertFalse(a.recoveryVerified)
    }
    func testBackupRecoveryAndAdditionalImportPreserveOriginal() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let context=LAContext(),source=WalletVault(storage:MemoryWalletStorage(),identity:MemoryWalletIdentity())
        let first=try await source.create(context:context)
        let key=try await source.revealKey(context:context)
        let verified=try await source.verify(keyHex:key,context:context)
        XCTAssertTrue(verified.recoveryVerified)
        let store=MemoryWalletStorage(),destination=WalletVault(storage:store,identity:MemoryWalletIdentity())
        let recovered=try await destination.recover(keyHex:key,context:context)
        let repeated=try await destination.recover(keyHex:key,context:context)
        XCTAssertEqual(first.address,recovered.address);XCTAssertEqual(repeated.address,first.address);XCTAssertEqual(store.inserts,1)
        let other=WalletVault(storage:MemoryWalletStorage(),identity:MemoryWalletIdentity());_ = try await other.create(context:context)
        let otherKey=try await other.revealKey(context:context)
        let additional=try await destination.recover(keyHex:otherKey,name:"Other",context:context)
        XCTAssertEqual(additional.profiles.count,2)
        XCTAssertEqual(additional.profiles.last?.name,"Other")
        XCTAssertNotEqual(additional.address,first.address)
        _ = try await destination.selectWallet(first.address,context:context)
        let after=try await destination.summary(context:context)
        XCTAssertEqual(after?.address,first.address)
    }
    func testDesktopMasterKeyRestoresAndKeepsOriginalOnSecondImport() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let context=LAContext(), source=WalletVault(storage:MemoryWalletStorage(),identity:MemoryWalletIdentity())
        let original=try await source.create(context:context)
        let key=try await source.revealKey(context:context)
        let storage=MemoryWalletStorage(), destination=WalletVault(storage:storage,identity:MemoryWalletIdentity())
        let restored=try await destination.recover(keyHex:key.uppercased(),context:context)
        XCTAssertEqual(restored.address,original.address)
        XCTAssertEqual(storage.inserts,1)
        let other=String(repeating:"a",count:64)
        let imported=try await destination.recover(keyHex:other,context:context)
        XCTAssertEqual(imported.profiles.count,2)
        _ = try await destination.selectWallet(original.address,context:context)
        let after=try await destination.summary(context:context)
        XCTAssertEqual(after?.address,original.address)
    }
    func testInterruptedCreationCanImportAnotherKeyWithoutLosingFirst() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let store=MemoryWalletStorage(),identity=MemoryWalletIdentity(),context=LAContext()
        let vault=WalletVault(storage:store,identity:identity)
        let unfinished=try await vault.create(context:context)
        let firstKey=try await vault.revealKey(context:context)
        XCTAssertFalse(unfinished.recoveryVerified)
        let second=WalletVault(storage:MemoryWalletStorage(),identity:MemoryWalletIdentity())
        _ = try await second.create(context:context)
        let secondKey=try await second.revealKey(context:context)
        let imported=try await vault.recover(keyHex:secondKey,name:"  Personal  ",context:context)
        XCTAssertEqual(imported.profiles.count,2)
        XCTAssertEqual(imported.profiles.last?.name,"Personal")
        XCTAssertEqual(identity.expectedAddress,unfinished.address)
        let selected=try await vault.selectWallet(unfinished.address,context:context)
        XCTAssertFalse(selected.recoveryVerified)
        let verified=try await vault.recover(keyHex:firstKey,context:context)
        XCTAssertEqual(verified.address,unfinished.address)
        XCTAssertTrue(verified.recoveryVerified)
        let restarted=WalletVault(storage:store,identity:identity)
        let afterRestart=try await restarted.summary(context:context)
        XCTAssertEqual(afterRestart?.profiles.count,2)
    }
    func testAdditionalCreatedWalletKeepsOriginalAndRequiresOwnBackup() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let storage=MemoryWalletStorage(), identity=MemoryWalletIdentity(), context=LAContext()
        let vault=WalletVault(storage:storage,identity:identity)
        let original=try await vault.create(context:context)
        do { _ = try await vault.createAdditional(context:context); XCTFail("Unverified wallet must block another creation") } catch { }
        let originalKey=try await vault.revealKey(context:context)
        _ = try await vault.verify(keyHex:originalKey,context:context)
        let additional=try await vault.createAdditional(context:context)
        XCTAssertNotEqual(additional.address,original.address)
        XCTAssertFalse(additional.recoveryVerified)
        XCTAssertEqual(additional.profiles.count,2)
        XCTAssertEqual(additional.profiles.last?.name,"Wallet 2")
        let secondKey=try await vault.revealKey(context:context)
        let restarted=WalletVault(storage:storage,identity:identity)
        let beforeBackup=try await restarted.summary(context:context)
        XCTAssertEqual(beforeBackup?.address,original.address)
        let unfinished=try await restarted.selectWallet(additional.selectedRoot,context:context)
        XCTAssertFalse(unfinished.recoveryVerified)
        let verified=try await restarted.verify(keyHex:secondKey,context:context)
        XCTAssertTrue(verified.recoveryVerified)
        let selected=try await restarted.selectWallet(original.address,context:context)
        XCTAssertTrue(selected.recoveryVerified)
        XCTAssertEqual(identity.expectedAddress,original.address)
    }
    func testWalletOrderDefaultAndVisibilitySurviveRestart() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let storage=MemoryWalletStorage(), identity=MemoryWalletIdentity(), context=LAContext()
        let vault=WalletVault(storage:storage,identity:identity)
        let original=try await vault.create(context:context)
        let key=try await vault.revealKey(context:context)
        _ = try await vault.verify(keyHex:key,context:context)
        let next=try await vault.createAdditional(context:context)
        let nextKey=try await vault.revealKey(context:context)
        _ = try await vault.verify(keyHex:nextKey,context:context)
        let ordered=try await vault.moveWallet(next.selectedRoot,by:-1,context:context)
        XCTAssertEqual(ordered.profiles.first?.address,next.selectedRoot)
        _ = try await vault.setDefaultWallet(original.selectedRoot,context:context)
        let hidden=try await vault.setWalletHidden(next.selectedRoot,hidden:true,context:context)
        XCTAssertTrue(hidden.profiles.first?.hidden == true)
        XCTAssertEqual(hidden.defaultRoot,original.selectedRoot)
        let restarted=WalletVault(storage:storage,identity:identity)
        let after=try await restarted.summary(context:context)
        XCTAssertEqual(after?.profiles.first?.address,next.selectedRoot)
        XCTAssertTrue(after?.profiles.first?.hidden == true)
        XCTAssertEqual(after?.selectedRoot,original.selectedRoot)
        _ = try await restarted.setWalletHidden(next.selectedRoot,hidden:false,context:context)
        _ = try await restarted.setDefaultWallet(next.selectedRoot,context:context)
        _ = try await restarted.selectWallet(original.selectedRoot,context:context)
        let relaunched=try await restarted.summary(context:context)
        XCTAssertEqual(relaunched?.selectedRoot,next.selectedRoot)
    }
    func testUnfinishedWalletCanBeExplicitlyRemovedBeforeStartingOver() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let storage=MemoryWalletStorage(),identity=MemoryWalletIdentity(),context=LAContext()
        let vault=WalletVault(storage:storage,identity:identity)
        let unfinished=try await vault.create(context:context)
        XCTAssertFalse(unfinished.recoveryVerified)
        let removed=try await vault.removeWallet(unfinished.selectedRoot,context:context)
        XCTAssertNil(removed)
        XCTAssertNil(identity.expectedAddress)
        XCTAssertNil(storage.data)
        let replacement=try await vault.create(context:context)
        XCTAssertNotEqual(replacement.address,unfinished.address)
    }
    func testMissingWalletMarkerResetNeverDeletesStoredWallet() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let storage=MemoryWalletStorage(),identity=MemoryWalletIdentity(),context=LAContext()
        let vault=WalletVault(storage:storage,identity:identity)
        let original=try await vault.create(context:context)
        do { try await vault.forgetMissingIdentity(context:context); XCTFail("stored wallet must block reset") } catch { }
        XCTAssertEqual(identity.expectedAddress,original.address)
        XCTAssertNotNil(storage.data)
        storage.data=nil
        try await vault.forgetMissingIdentity(context:context)
        XCTAssertNil(identity.expectedAddress)
        let fresh=try await vault.create(context:context)
        XCTAssertNotEqual(fresh.address,original.address)
    }
    func testNewMasterKeyBackupVerification() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let vault=WalletVault(storage:MemoryWalletStorage(),identity:MemoryWalletIdentity()), context=LAContext()
        let created=try await vault.create(context:context)
        let key=try await vault.revealKey(context:context)
        XCTAssertEqual(key.count,64)
        do { _ = try await vault.verify(keyHex:String(repeating:"0",count:64),context:context); XCTFail("wrong key must fail") } catch { }
        let unverified=try await vault.summary(context:context)
        XCTAssertEqual(unverified?.recoveryVerified,false)
        let verified=try await vault.verify(keyHex:key,context:context)
        XCTAssertEqual(verified.address,created.address)
        XCTAssertTrue(verified.recoveryVerified)
    }
    func testWriteFailureDoesNotCreateWallet() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let storage=MemoryWalletStorage();storage.failWrite=true
        let vault=WalletVault(storage:storage,identity:MemoryWalletIdentity())
        do { _ = try await vault.create(context:LAContext());XCTFail("must fail") } catch { }
        XCTAssertNil(storage.data)
    }
    func testMissingSecretCannotCreateOrRecoverDifferentWallet() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let storage=MemoryWalletStorage(),identity=MemoryWalletIdentity(),context=LAContext()
        let vault=WalletVault(storage:storage,identity:identity)
        let original=try await vault.create(context:context)
        let key=try await vault.revealKey(context:context)
        storage.data=nil // Simulate loss of the passcode-bound item.
        do { _ = try await vault.create(context:context);XCTFail("must require recovery") } catch { }
        XCTAssertNil(storage.data)
        let other=WalletVault(storage:MemoryWalletStorage(),identity:MemoryWalletIdentity())
        _ = try await other.create(context:context)
        let different=try await other.revealKey(context:context)
        do { _ = try await vault.recover(keyHex:different,context:context);XCTFail("must not replace identity") } catch { }
        XCTAssertNil(storage.data)
        let restored=try await vault.recover(keyHex:key,context:context)
        XCTAssertEqual(restored.address,original.address)
    }
    func testLockoutDeletesOnlyLocalKeyAndRequiresOriginalRecovery() async throws {
        try XCTSkipUnless(NativeCore.available,"Native core required")
        let storage=MemoryWalletStorage(),identity=MemoryWalletIdentity(),context=LAContext()
        let vault=WalletVault(storage:storage,identity:identity)
        let original=try await vault.create(context:context)
        let key=try await vault.revealKey(context:context)
        try await vault.eraseLocalSecretAfterLockout()
        XCTAssertNil(storage.data)
        XCTAssertEqual(identity.expectedAddress,original.address)
        do {_ = try await vault.create(context:context);XCTFail("A new wallet replaced the erased identity")}catch{}
        let restored=try await vault.recover(keyHex:key,context:context)
        XCTAssertEqual(restored.address,original.address)
    }
    func testSeparateKeyImportSelectionRemovalAndRestart() async throws {
        try XCTSkipUnless(NativeCore.available, "Native core required")
        let store = MemoryWalletStorage(), identity = MemoryWalletIdentity(), context = LAContext()
        let vault = WalletVault(storage: store, identity: identity)
        let original = try await vault.create(context: context)
        let originalKey = try await vault.revealKey(context: context)
        _ = try await vault.verify(keyHex: originalKey, context: context)
        let other = WalletVault(storage: MemoryWalletStorage(), identity: MemoryWalletIdentity())
        _ = try await other.create(context: context)
        let otherKey = try await other.revealKey(context: context)
        let imported = try await vault.importAdditional(keyHex: otherKey, context: context)
        XCTAssertNotEqual(imported.address, original.address)
        XCTAssertEqual(imported.profiles.count, 2)
        let account = try await vault.addAccount(context: context)
        XCTAssertEqual(account.selectedIndex, 1)
        let reopened = WalletVault(storage: store, identity: identity)
        let saved = try await reopened.summary(context: context)
        XCTAssertEqual(saved?.address, original.address)
        XCTAssertEqual(saved?.defaultRoot, original.address)
        XCTAssertEqual(saved?.profiles.count, 2)
        let switched = try await reopened.selectWallet(imported.selectedRoot, context: context)
        XCTAssertEqual(switched.address, account.address)
        let first = try await reopened.selectWallet(original.address, context: context)
        XCTAssertEqual(first.address, original.address)
        let duplicate = try await reopened.importAdditional(keyHex: otherKey, context: context)
        XCTAssertEqual(duplicate.profiles.count, 2)
        let removed = try await reopened.removeWallet(imported.selectedRoot, context: context)
        XCTAssertEqual(removed?.address, original.address)
        XCTAssertEqual(removed?.profiles.count, 1)
        XCTAssertNotNil(store.data)
    }
    func testRenamedWalletsAndAccountsSurviveRestartWithoutChangingAddresses() async throws {
        try XCTSkipUnless(NativeCore.available, "Native core required")
        let store = MemoryWalletStorage(), identity = MemoryWalletIdentity(), context = LAContext()
        let vault = WalletVault(storage: store, identity: identity)
        let original = try await vault.create(context: context)
        let key = try await vault.revealKey(context: context)
        _ = try await vault.verify(keyHex: key, context: context)
        let added = try await vault.addAccount(context: context)
        _ = try await vault.renameWallet(original.address, to: "  Personal  ", context: context)
        let renamed = try await vault.renameAccount(added.selectedIndex, to: "  Savings  ", context: context)
        XCTAssertEqual(renamed.address, added.address)
        XCTAssertEqual(renamed.profiles.first?.name, "Personal")
        XCTAssertEqual(renamed.accounts.first(where: { $0.index == added.selectedIndex })?.name, "Savings")
        let reopened = WalletVault(storage: store, identity: identity)
        let snapshot = try await reopened.summary(context: context)
        let saved = try XCTUnwrap(snapshot)
        XCTAssertEqual(saved.address, added.address)
        XCTAssertEqual(saved.profiles.first?.name, "Personal")
        XCTAssertEqual(saved.accounts.first(where: { $0.index == added.selectedIndex })?.name, "Savings")
        do { _ = try await vault.renameWallet(original.address, to: String(repeating: "x", count: 41), context: context); XCTFail("Invalid name saved") } catch { }
        let unchanged = try await reopened.summary(context: context)
        XCTAssertEqual(unchanged?.profiles.first?.name, "Personal")
    }
    func testOriginalCannotBeRemovedWhileImportedKeyNeedsItsIdentity() async throws {
        try XCTSkipUnless(NativeCore.available, "Native core required")
        let vault = WalletVault(storage: MemoryWalletStorage(), identity: MemoryWalletIdentity()), context = LAContext()
        let original = try await vault.create(context: context)
        let originalKey = try await vault.revealKey(context: context)
        _ = try await vault.verify(keyHex: originalKey, context: context)
        let other = WalletVault(storage: MemoryWalletStorage(), identity: MemoryWalletIdentity())
        _ = try await other.create(context: context)
        let otherKey = try await other.revealKey(context: context)
        _ = try await vault.importAdditional(keyHex: otherKey, context: context)
        do { _ = try await vault.removeWallet(original.address, context: context); XCTFail("Original identity must remain") } catch { }
    }
    func testWrongBackupNeverMarksWalletVerified() async throws {
        try XCTSkipUnless(NativeCore.available, "Native core required")
        let context = LAContext()
        let vault = WalletVault(storage: MemoryWalletStorage(), identity: MemoryWalletIdentity())
        let other = WalletVault(storage: MemoryWalletStorage(), identity: MemoryWalletIdentity())
        _ = try await vault.create(context: context)
        _ = try await other.create(context: context)
        let wrong = try await other.revealKey(context: context)
        do { _ = try await vault.verify(keyHex: wrong, context: context); XCTFail("Wrong backup must fail") } catch { }
        let summary = try await vault.summary(context: context)
        XCTAssertEqual(summary?.recoveryVerified, false)
    }
    func testDiscardedVerificationWriteCannotReportSuccess() async throws {
        try XCTSkipUnless(NativeCore.available, "Native core required")
        let context = LAContext(), storage = MemoryWalletStorage()
        let vault = WalletVault(storage: storage, identity: MemoryWalletIdentity())
        let original = try await vault.create(context: context)
        let key = try await vault.revealKey(context: context)
        storage.discardUpdates = true
        do { _ = try await vault.verify(keyHex: key, context: context); XCTFail("Read-back must reject a discarded update") } catch { }
        let summary = try await vault.summary(context: context)
        XCTAssertEqual(summary?.address, original.address)
        XCTAssertEqual(summary?.recoveryVerified, false)
    }
    func testDamagedStoredIdentityCannotRevealKey() async throws {
        try XCTSkipUnless(NativeCore.available, "Native core required")
        let context = LAContext(), storage = MemoryWalletStorage()
        let identity = MemoryWalletIdentity()
        let vault = WalletVault(storage: storage, identity: identity)
        _ = try await vault.create(context: context)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(storage.data)) as? [String: Any])
        // Corrupt the secret while retaining the original address and marker.
        record["master"] = Data(repeating: 0x47, count: 32).base64EncodedString()
        storage.data = try JSONSerialization.data(withJSONObject: record)
        do { _ = try await vault.revealKey(context: context); XCTFail("Mismatched secret must not be displayed as the backup") } catch { }
    }
    func testIndexedAccountsSurviveRestartAndRestore() async throws {
        try XCTSkipUnless(NativeCore.available, "Native core required")
        let store = MemoryWalletStorage(), identity = MemoryWalletIdentity(), context = LAContext()
        let vault = WalletVault(storage: store, identity: identity)
        let original = try await vault.create(context: context)
        let key = try await vault.revealKey(context: context)
        _ = try await vault.verify(keyHex: key, context: context)
        let second = try await vault.addAccount(context: context)
        XCTAssertEqual(second.selectedIndex, 1); XCTAssertNotEqual(original.address, second.address)
        let reopened = WalletVault(storage: store, identity: identity)
        let persisted = try await reopened.summary(context: context)
        XCTAssertEqual(persisted?.address, second.address)
        let restored = WalletVault(storage: MemoryWalletStorage(), identity: MemoryWalletIdentity())
        _ = try await restored.recover(keyHex: key, context: context)
        let candidates = try await restored.candidates(start: 0, context: context)
        XCTAssertEqual(candidates[1].address, second.address)
        let discovered = try await restored.rememberUsed([candidates[1]], context: context)
        XCTAssertEqual(discovered.accounts.first?.index, 1)
        XCTAssertEqual(discovered.address, second.address)
        XCTAssertEqual(store.inserts, 1)
    }
    func testAccountRegistryTamperingIsRejected() async throws {
        try XCTSkipUnless(NativeCore.available, "Native core required")
        let store = MemoryWalletStorage(), context = LAContext()
        let vault = WalletVault(storage: store, identity: MemoryWalletIdentity())
        _ = try await vault.create(context: context)
        let key = try await vault.revealKey(context: context)
        _ = try await vault.verify(keyHex: key, context: context)
        _ = try await vault.addAccount(context: context)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(store.data)) as? [String: Any])
        var wallets = try XCTUnwrap(record["wallets"] as? [[String: Any]])
        XCTAssertEqual(wallets.count, 1)
        var selected = wallets[0]
        var accounts = try XCTUnwrap(selected["accounts"] as? [[String: Any]])
        accounts[1]["address"] = accounts[0]["address"]
        selected["accounts"] = accounts
        wallets[0] = selected
        record["wallets"] = wallets
        store.data = try JSONSerialization.data(withJSONObject: record)
        do { _ = try await vault.summary(context: context); XCTFail("A foreign derived-address mapping must fail") } catch { }
    }
    @MainActor func testHideBalances() {
        let state=WalletState();state.hideBalances=true
        XCTAssertEqual(state.amount("75,000 NOID"),"••••••")
        state.hideBalances=false
    }
}
