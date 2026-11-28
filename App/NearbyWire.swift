import Foundation

/// iOS BLE transport v1: 4-byte big-endian length followed by untouched Courier JSON.
/// Deliberately a distinct GATT service from Android's RFCOMM protocol.
struct NearbyFrameDecoder {
    static let limit=(1024*1024)
    private var buffer=Data()
    private var expected:Int?
    mutating func feed(_ chunk:Data) throws -> [Data] {
        guard !chunk.isEmpty,chunk.count<=512,buffer.count+chunk.count<=Self.limit+516 else {throw AppFailure("Invalid nearby fragment.")}
        buffer.append(chunk)
        var frames:[Data]=[]
        while true {
            if expected==nil {
                guard buffer.count>=4 else {break}
                let size=buffer.prefix(4).reduce(UInt32(0)){($0<<8)|UInt32($1)}
                guard size>0,size<=UInt32(Self.limit) else {throw AppFailure("Invalid nearby packet length.")}
                expected=Int(size);buffer=Data(buffer.dropFirst(4))
            }
            guard let size=expected,buffer.count>=size else {break}
            frames.append(Data(buffer.prefix(size)));buffer=Data(buffer.dropFirst(size));expected=nil
            guard frames.count<=8 else {throw AppFailure("Too many nearby packets.")}
        }
        return frames
    }
    static func encode(_ packet:Data) throws -> Data {
        guard !packet.isEmpty,packet.count<=limit else {throw AppFailure("Nearby packet exceeds its limit.")}
        let n=UInt32(packet.count)
        return Data([UInt8(n>>24),UInt8((n>>16)&255),UInt8((n>>8)&255),UInt8(n&255)])+packet
    }
}

struct ValidatedMessage:Identifiable {
    let id:String
    let senderID:String
    let recipientID:String
    let expires:UInt64
    let data:Data
    static func inspect(_ data:Data) async throws -> Self {
        guard data.count<=NearbyFrameDecoder.limit else {throw AppFailure("Packet too large.")}
        let envelope=try JSONSerialization.jsonObject(with:data)
        let result=try await NativeCore.shared.call(["op":"chat_inspect","envelope":envelope,"now_ms":UInt64(Date().timeIntervalSince1970*1000)])
        guard let id=result["id"] as? String,let sender=result["sender"] as? [String:Any],let recipient=result["recipient"] as? [String:Any],let senderID=sender["id"] as? String,let recipientID=recipient["id"] as? String,let expires=result["expires_ms"] as? NSNumber else {throw AppFailure("Invalid verified packet.")}
        return Self(id:id,senderID:senderID,recipientID:recipientID,expires:expires.uint64Value,data:data)
    }
}

/// Store only signed ciphertext; the app-wide relay preference controls forwarding.
actor NearbyPacketStore {
    static let shared=NearbyPacketStore()
    private let directory:URL?
    init(directory:URL?=nil) {self.directory=directory}
    private struct Record:Codable {let id:String;let expires:UInt64;let data:Data}
    private struct Archive:Codable {var version=1;var records:[Record]}
    private func location() throws -> URL {
        let base=try directory ?? FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("Nearby",isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication])
        var url=base;var values=URLResourceValues();values.isExcludedFromBackup=true;try url.setResourceValues(values)
        let path=base.appendingPathComponent("packets.json")
        // Migrate only this ciphertext relay queue. Wallet keys and the private
        // conversation archive retain their existing stricter protections.
        try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:base.path)
        if FileManager.default.fileExists(atPath:path.path) {
            try FileManager.default.setAttributes([.protectionKey:FileProtectionType.completeUntilFirstUserAuthentication],ofItemAtPath:path.path)
        }
        return path
    }
    private func load() throws -> [Record] {
        let url=try location()
        guard FileManager.default.fileExists(atPath:url.path) else{return []}
        guard (try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=8*1024*1024 else{throw AppFailure("Nearby storage limit exceeded.")}
        let archive=try JSONDecoder().decode(Archive.self,from:Data(contentsOf:url))
        guard archive.version==1,archive.records.count<=128,Set(archive.records.map(\.id)).count==archive.records.count,archive.records.allSatisfy({$0.data.count<=(1024*1024)}) else{throw AppFailure("Nearby storage is invalid; it was not replaced.")}
        let now=UInt64(Date().timeIntervalSince1970*1000)
        return archive.records.filter{$0.expires>now}
    }
    func packets() throws -> [Data] {try load().map(\.data)}
    func save(_ packet:ValidatedMessage,evicting:Set<String>=[]) throws {
        var records=try load().filter{!evicting.contains($0.id)}
        if records.contains(where:{$0.id==packet.id}) {return}
        guard records.count<128 else{throw AppFailure("Nearby storage is full. Clear carried packets to continue.")}
        records.append(.init(id:packet.id,expires:packet.expires,data:packet.data))
        let data=try JSONEncoder().encode(Archive(records:records))
        guard data.count<=8*1024*1024 else{throw AppFailure("Nearby storage is full.")}
        try data.write(to:location(),options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
    }
    func clear() throws {let url=try location();if FileManager.default.fileExists(atPath:url.path){try FileManager.default.removeItem(at:url)}}
}
