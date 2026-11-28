import Foundation
import CryptoKit

/// Display-only JSON. Restored data cannot provide a transaction review parent.
actor DisplaySnapshotStore {
    static let shared = DisplaySnapshotStore()
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }
    static func chainID() throws -> String {
        let result = try DeviceNodeBridge.call(["op":"chain_identity"])
        guard let chain = result["chain_id"] as? String, chain.count == 64, Data(hex:chain)?.count == 32 else {
            throw AppFailure("Cannot identify the snapshot network.")
        }
        return chain
    }
    private func file(kind:String,owner:String,chain:String) throws -> URL {
        guard ["assets","verified_assets","history"].contains(kind), AddressValidator.valid(owner), chain.count == 64, Data(hex:chain)?.count == 32 else {throw AppFailure("Invalid snapshot identity.")}
        var base = try directory ?? FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("DisplaySnapshots",isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var values=URLResourceValues();values.isExcludedFromBackup=true;try base.setResourceValues(values)
        let key=SHA256.hash(data:Data((chain+"|"+owner).utf8)).map {String(format:"%02x",$0)}.joined()
        return base.appendingPathComponent(kind+"-"+key+".json")
    }
    func load(kind:String,owner:String,chain:String) throws -> (payload:[String:Any],date:Date)? {
        let path=try file(kind:kind,owner:owner,chain:chain)
        guard FileManager.default.fileExists(atPath:path.path) else{return nil}
        guard (try path.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max) <= 16*1024*1024 else {throw AppFailure("Saved snapshot is too large.")}
        let bytes=try Data(contentsOf:path)
        guard let result=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              result["version"] as? Int == 1,result["owner"] as? String == owner,result["chain"] as? String == chain,
              let time=result["saved_at"] as? Double,time.isFinite,time>0,time<=Date().timeIntervalSince1970+60,
              let payload=result["payload"] as? [String:Any] else {throw AppFailure("Invalid saved snapshot.")}
        return (payload,Date(timeIntervalSince1970:time))
    }
    func save(kind:String,owner:String,chain:String,payload:[String:Any],date:Date) throws {
        let path=try file(kind:kind,owner:owner,chain:chain)
        if let previous=try? load(kind:kind,owner:owner,chain:chain) {
            if previous.date>date{return}
            let old=try JSONSerialization.data(withJSONObject:previous.payload,options:.sortedKeys)
            let next=try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys)
            if old==next{return}
        }
        let bytes=try JSONSerialization.data(withJSONObject:["version":1,"owner":owner,"chain":chain,"saved_at":date.timeIntervalSince1970,"payload":payload],options:.sortedKeys)
        guard bytes.count<=16*1024*1024 else {throw AppFailure("Snapshot storage limit exceeded; previous data retained.")}
        try bytes.write(to:path,options:[.atomic,.completeFileProtection])
    }
}
