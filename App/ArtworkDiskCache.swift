import Foundation
import CryptoKit

/// Bounded raw media cache. AssetMedia revalidates hashes and dimensions on read.
actor ArtworkDiskCache {
    static let shared = ArtworkDiskCache()
    private func folder() throws -> URL {
        var url=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("ArtworkCache",isDirectory:true)
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.complete])
        var values=URLResourceValues();values.isExcludedFromBackup=true;try url.setResourceValues(values)
        return url
    }
    private func file(_ resource:String) throws -> URL {
        let key=SHA256.hash(data:Data(resource.utf8)).map {String(format:"%02x",$0)}.joined()
        return try folder().appendingPathComponent(key)
    }
    func read(_ resource:String,limit:Int) throws -> Data? {
        let url=try file(resource)
        guard FileManager.default.fileExists(atPath:url.path) else{return nil}
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=limit else{try? FileManager.default.removeItem(at:url);return nil}
        let data=try Data(contentsOf:url)
        try? FileManager.default.setAttributes([.modificationDate:Date()],ofItemAtPath:url.path)
        return data
    }
    func remove(_ resource:String) {if let url=try? file(resource) {try? FileManager.default.removeItem(at:url)}}
    func save(_ data:Data,resource:String) throws {
        guard data.count<=4*1024*1024 else{return}
        let url=try file(resource)
        try data.write(to:url,options:[.atomic,.completeFileProtection])
        let files=try FileManager.default.contentsOfDirectory(at:folder(),includingPropertiesForKeys:[.fileSizeKey,.contentModificationDateKey])
        var entries:[(URL,Int,Date)]=[]
        for file in files {
            let values=try file.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey])
            entries.append((file,values.fileSize ?? 0,values.contentModificationDate ?? .distantPast))
        }
        var total=entries.reduce(0) {$0+$1.1}
        for entry in entries.sorted(by:{$0.2<$1.2}) where total>128*1024*1024 {
            try FileManager.default.removeItem(at:entry.0);total-=entry.1
        }
    }
}
