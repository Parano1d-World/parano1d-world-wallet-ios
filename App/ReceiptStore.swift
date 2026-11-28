import Foundation

/// Saved evidence is reverified against the accepted chain on every use.
/// It never grants permission to release a payment reservation by itself.
struct ReceiptStore {
    let directory:URL
    /// Receipts are small (a few KB); 4,096 covers years of payments. Saving is a cache:
    /// the payment checker never depends on it succeeding.
    static let limit=4096
    static func device() throws -> ReceiptStore {
        let directory=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("PaymentReceipts",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var url=directory;var values=URLResourceValues();values.isExcludedFromBackup=true;try url.setResourceValues(values)
        return ReceiptStore(directory:directory)
    }
    private func path(_ id:String) throws -> URL {
        guard id.utf8.count==64,id.utf8.allSatisfy({(48...57).contains($0) || (97...102).contains($0)}) else{throw AppFailure("Invalid receipt identity.")}
        return directory.appendingPathComponent(id+".receipt")
    }
    func load(_ id:String) throws -> ReceiptInput? {
        let file=try path(id)
        guard FileManager.default.fileExists(atPath:file.path) else{return nil}
        let values=try file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey,.isSymbolicLinkKey])
        guard values.isRegularFile==true,values.isSymbolicLink != true,let size=values.fileSize,size<=262144 else{throw AppFailure("Invalid saved receipt.")}
        let data=try Data(contentsOf:file)
        guard let hex=String(data:data,encoding:.utf8) else{throw AppFailure("Damaged saved receipt.")}
        return try ReceiptInput(hex:hex,transactionID:id)
    }
    func save(_ receipt:ReceiptInput) throws {
        let file=try path(receipt.transactionID)
        if !FileManager.default.fileExists(atPath:file.path) {
            let files=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
            guard files.filter({$0.pathExtension=="receipt"}).count<Self.limit else{throw AppFailure("Receipt storage is full. Existing evidence has been retained.")}
        }
        try Data(receipt.hex.utf8).write(to:file,options:[.atomic,.completeFileProtection])
    }
}
