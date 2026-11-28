import Foundation
import CoreFoundation

/// Never trust relay cursors, sender labels or payloads. A page commits atomically.
enum MessageInbox {
    struct Page {let packets:[MessageArchive.Packet];let cursor:UInt64}
    static func cursor(_ value:Any?) throws -> UInt64 {
        guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),let result=UInt64(number.stringValue) else{throw AppFailure("Invalid inbox cursor.")}
        return result
    }
    static func validate(_ object:[String:Any],identity:String,after:UInt64) async throws -> Page {
        guard let entries=object["messages"] as? [[String:Any]],entries.count<=30 else{throw AppFailure("Invalid inbox page.")}
        let end=try cursor(object["cursor"])
        var previous=after;var packets:[MessageArchive.Packet]=[]
        for entry in entries {
            try Task.checkCancellation()
            let next=try cursor(entry["cursor"])
            guard next>previous,next<=end,let envelope=entry["envelope"] as? [String:Any] else{throw AppFailure("Inbox ordering is invalid; nothing was skipped.")}
            let data=try JSONSerialization.data(withJSONObject:envelope,options:.sortedKeys)
            let verified=try await ValidatedMessage.inspect(data)
            guard verified.recipientID==identity else{throw AppFailure("Inbox contained another recipient's packet.")}
            packets.append(.init(id:verified.id,contactID:verified.senderID,received:true,date:Date(),envelope:data))
            previous=next
        }
        guard end==previous else{throw AppFailure("Inbox cursor does not match its messages.")}
        return Page(packets:packets,cursor:end)
    }
}
