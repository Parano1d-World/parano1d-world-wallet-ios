import Foundation
import CryptoKit

/// Public transaction references from decrypted chat payments, scoped to one wallet.
/// A reference or supplied receipt is never considered proof of settlement.
actor ChatReceiptIndex {
    static let shared=ChatReceiptIndex()
    private let directory:URL?
    init(directory:URL?=nil) {self.directory=directory}
    struct Entry:Codable,Identifiable {
        let id:String
        var seenAt:Date
        var suppliedReceipt:String?
        var source:String
    }
    private func location(root:String) throws -> URL {
        guard AddressValidator.valid(root) else{throw AppFailure("Invalid wallet identity.")}
        let base=try directory ?? FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("ChatReceipts",isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var directory=base;var values=URLResourceValues();values.isExcludedFromBackup=true;try directory.setResourceValues(values)
        let name=SHA256.hash(data:Data(root.utf8)).map{String(format:"%02x",$0)}.joined()
        return base.appendingPathComponent(name+".json")
    }
    func entries(root:String) throws -> [Entry] {
        let path=try location(root:root)
        guard FileManager.default.fileExists(atPath:path.path) else{return []}
        let values=try path.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true,(values.fileSize ?? Int.max)<=36*1024*1024 else{throw AppFailure("Saved chat receipt list is invalid.")}
        let entries=try JSONDecoder().decode([Entry].self,from:Data(contentsOf:path))
        guard entries.count<=256,Set(entries.map(\.id)).count==entries.count,
              entries.allSatisfy({$0.id.count==64 && Data(hex:$0.id)?.count==32 && ($0.suppliedReceipt?.utf8.count ?? 0)<=262144})
        else{throw AppFailure("Saved chat receipt list is invalid.")}
        return entries.sorted{$0.seenAt>$1.seenAt}
    }
    func observe(root:String,preview:ChatPaymentPreview,date:Date) throws {
        guard let id=preview.transactionID else{return}
        let supplied=preview.receipt.flatMap{try? ReceiptInput(hex:$0,transactionID:id).hex}
        var entries=try entries(root:root)
        if let index=entries.firstIndex(where:{$0.id==id}) {
            entries[index].seenAt=max(entries[index].seenAt,date)
            if let supplied {entries[index].suppliedReceipt=supplied}
        } else {
            // References aren't proof (verified receipts live in ReceiptStore), so when the list
            // is full the oldest-seen reference makes way instead of refusing the new one.
            if entries.count>=256,let oldest=entries.min(by:{$0.seenAt<$1.seenAt}) {entries.removeAll{$0.id==oldest.id}}
            entries.append(.init(id:id,seenAt:date,suppliedReceipt:supplied,source:"chat"))
        }
        try JSONEncoder().encode(entries).write(to:location(root:root),options:[.atomic,.completeFileProtection])
    }
    func rememberVerified(root:String,transactionID:String,hex:String?,date:Date) throws {
        guard transactionID.count==64,Data(hex:transactionID)?.count==32 else {throw AppFailure("Invalid transaction ID.")}
        let supplied=hex.flatMap{try? ReceiptInput(hex:$0,transactionID:transactionID).hex}
        var list=try entries(root:root)
        if let index=list.firstIndex(where:{$0.id==transactionID}) {
            list[index].seenAt=max(list[index].seenAt,date)
            if let supplied {list[index].suppliedReceipt=supplied}
        } else {
            if list.count>=256,let oldest=list.min(by:{$0.seenAt<$1.seenAt}) {list.removeAll{$0.id==oldest.id}}
            list.append(.init(id:transactionID,seenAt:date,suppliedReceipt:supplied,source:"manual"))
        }
        try JSONEncoder().encode(list).write(to:location(root:root),options:[.atomic,.completeFileProtection])
    }
}

/// Finalized receipts this phone already verified against its own accepted chain.
/// Finality is permanent, so these are shown at once instead of being re-checked on every
/// visit. An entry above the phone's current verified height (for example after the node
/// data was reset) is ignored until the chain catches up again.
actor VerifiedReceiptCache {
    static let shared=VerifiedReceiptCache()
    private struct Row:Codable {let id:String;let height:UInt64;let confirmations:UInt64;let checkedAt:Date}
    private func location(root:String) throws -> URL {
        guard AddressValidator.valid(root) else{throw AppFailure("Invalid wallet identity.")}
        let base=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            .appendingPathComponent("VerifiedReceipts",isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var directory=base;var values=URLResourceValues();values.isExcludedFromBackup=true;try directory.setResourceValues(values)
        return base.appendingPathComponent(SHA256.hash(data:Data(root.utf8)).map{String(format:"%02x",$0)}.joined()+".json")
    }
    private func rows(root:String) -> [Row] {
        guard let path=try? location(root:root),let data=try? Data(contentsOf:path),data.count<=2*1024*1024,
              let rows=try? JSONDecoder().decode([Row].self,from:data) else{return []}
        return rows.filter{$0.id.count==64 && Data(hex:$0.id)?.count==32}
    }
    func load(root:String,verifiedHeight:UInt64?) -> [String:VerifiedReceipt] {
        var out:[String:VerifiedReceipt]=[:]
        for row in rows(root:root) where verifiedHeight.map({row.height<=$0}) ?? true {
            out[row.id]=VerifiedReceipt(transactionID:row.id,height:row.height,confirmations:row.confirmations,finalized:true,checkedAt:row.checkedAt)
        }
        return out
    }
    func remember(root:String,_ receipt:VerifiedReceipt) {
        guard receipt.finalized,let path=try? location(root:root) else{return}
        var list=rows(root:root).filter{$0.id != receipt.transactionID}
        list.append(Row(id:receipt.transactionID,height:receipt.height,confirmations:receipt.confirmations,checkedAt:receipt.checkedAt))
        if list.count>1000 {list=Array(list.sorted{$0.checkedAt>$1.checkedAt}.prefix(1000))}
        try? JSONEncoder().encode(list).write(to:path,options:[.atomic,.completeFileProtection])
    }
}
