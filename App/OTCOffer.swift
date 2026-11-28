import Foundation
import CryptoKit

/// Unsigned local terms only. This model cannot create a deposit address,
/// authorize funds, report settlement or promise an automatic refund.
struct OTCOffer:Codable,Identifiable {
    enum Side:String,Codable,CaseIterable {case buyNOID="Buy NOID",sellNOID="Sell NOID"}
    let id:UUID
    let side:Side
    let noidUnits:String
    let usdtUnits:String
    let makerNOID:String
    let makerUSDT:String
    let counterpartyNOID:String
    let counterpartyUSDT:String
    let created:Date
    let expires:Date
    let usdtNetwork:String
    var expired:Bool {Date()>=expires}
    static func amount(_ text:String) throws -> String {
        guard let units=Amounts.parse(text),let value=UInt64(units),value>0 else {throw AppFailure("Enter a positive amount with at most six decimal places.")}
        return String(value)
    }
    static func validEthereumAddress(_ address:String)->Bool {
        guard address.hasPrefix("0x"),address.count==42,let bytes=Data(hex:String(address.dropFirst(2))),bytes.count==20,bytes.contains(where:{$0 != 0}) else{return false}
        // Checksummed mixed-case validation belongs to the future EVM adapter.
        // Local drafts accept normalized lowercase only; never pretend this
        // proves key control or that the address can receive USDT.
        return address==address.lowercased()
    }
    static func make(side:Side,noid:String,usdt:String,makerNOID:String,makerUSDT:String,counterpartyNOID:String,counterpartyUSDT:String,expires:Date,now:Date=Date()) throws -> Self {
        guard AddressValidator.valid(makerNOID) else{throw AppFailure("Enter your valid NOID address.")}
        guard validEthereumAddress(makerUSDT) else{throw AppFailure("Enter your Ethereum USDT address in lowercase 0x format. Address ownership has not been verified.")}
        guard expires.timeIntervalSince(now)>=300,expires.timeIntervalSince(now)<=30*86400 else{throw AppFailure("Choose an offer expiry between five minutes and thirty days from now.")}
        if !counterpartyNOID.isEmpty || !counterpartyUSDT.isEmpty {
            guard AddressValidator.valid(counterpartyNOID),validEthereumAddress(counterpartyUSDT) else{throw AppFailure("Enter both valid counterparty addresses, or leave both empty for an open draft.")}
            guard counterpartyNOID != makerNOID,counterpartyUSDT != makerUSDT else{throw AppFailure("Counterparty addresses must differ from your own.")}
        }
        return try .init(id:UUID(),side:side,noidUnits:amount(noid),usdtUnits:amount(usdt),makerNOID:makerNOID,makerUSDT:makerUSDT,counterpartyNOID:counterpartyNOID,counterpartyUSDT:counterpartyUSDT,created:now,expires:expires,usdtNetwork:"Ethereum mainnet · ERC-20")
    }
}
actor OTCOfferStore {
    static let shared=OTCOfferStore()
    private func file(owner:String) throws -> URL {
        guard AddressValidator.valid(owner) else{throw AppFailure("A valid wallet address is required.")}
        var base=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("SwapDrafts",isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var values=URLResourceValues();values.isExcludedFromBackup=true;try base.setResourceValues(values)
        let name=SHA256.hash(data:Data(owner.utf8)).map{String(format:"%02x",$0)}.joined()
        return base.appendingPathComponent(name+".json")
    }
    func load(owner:String) throws -> [OTCOffer] {
        let path=try file(owner:owner)
        guard FileManager.default.fileExists(atPath:path.path) else{return []}
        guard (try path.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<512*1024 else{throw AppFailure("Swap drafts exceed the storage limit.")}
        let offers=try JSONDecoder().decode([OTCOffer].self,from:Data(contentsOf:path))
        guard offers.count<=100,Set(offers.map(\.id)).count==offers.count,offers.allSatisfy({$0.makerNOID==owner}) else{throw AppFailure("Invalid saved swap drafts.")}
        return offers.sorted{$0.created>$1.created}
    }
    func save(_ offer:OTCOffer,owner:String) throws {
        guard offer.makerNOID==owner,!offer.expired else{throw AppFailure("This offer expired or belongs to another wallet.")}
        var offers=try load(owner:owner)
        guard !offers.contains(where:{$0.id==offer.id}),offers.count<100 else{throw AppFailure("Draft already saved or draft limit reached.")}
        offers.append(offer)
        try JSONEncoder().encode(offers).write(to:file(owner:owner),options:[.atomic,.completeFileProtection])
    }
    func remove(_ id:UUID,owner:String) throws {
        let offers=try load(owner:owner).filter{$0.id != id}
        try JSONEncoder().encode(offers).write(to:file(owner:owner),options:[.atomic,.completeFileProtection])
    }
}
