import Foundation

enum RelayResponseError:LocalizedError {
    case tooLarge
    var errorDescription:String? {"The relay response is too large. No inbox messages were skipped."}
}

@MainActor enum InboxPaging {
    static func load(fetch:(Int) async throws -> [String:Any]) async throws -> [String:Any] {
        for limit in [30,8,2,1] {
            try Task.checkCancellation()
            do {return try await fetch(limit)}
            catch RelayResponseError.tooLarge {if limit==1{throw RelayResponseError.tooLarge}}
        }
        throw RelayResponseError.tooLarge
    }
}

/// Upstream public relay. Receives ciphertext and public routing identities only.
/// No URL supplied by a website/contact is accepted, and redirects are rejected.
actor MessageRelay {
    static let shared=MessageRelay()
    private let origin=URL(string:"https://chat.parano1d.org")!
    private let session=URLSession(configuration:.ephemeral,delegate:RejectRedirects(),delegateQueue:nil)
    private func request(_ path:String,body:Data?=nil,auth:[String:Any]?=nil) async throws -> [String:Any] {
        guard path.hasPrefix("/v1/"),let url=URL(string:path,relativeTo:origin)?.absoluteURL,url.host==origin.host,url.scheme=="https" else {throw AppFailure("Invalid relay route.")}
        if ChatPrivacy.enabled {
            if path.hasPrefix("/v1/groups") {throw AppFailure("Public rooms are disabled in Private-only chat.")}
            if let body,let packet=try JSONSerialization.jsonObject(with:body) as? [String:Any],
               let data=packet["data"] as? [String:Any],let destination=data["destination"] as? [String:Any],
               destination["type"] as? String == "group" {throw AppFailure("Public posting is disabled in Private-only chat.")}
        }
        var request=URLRequest(url:url);request.timeoutInterval=20;request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {guard body.count<=(1024*1024) else{throw AppFailure("Encrypted message is too large.")};request.httpMethod="POST";request.httpBody=body;request.setValue("application/json",forHTTPHeaderField:"Content-Type")}
        if let auth {
            guard let time=auth["time_ms"] as? String,UInt64(time) != nil,let signature=auth["signature"] as? String,signature.count==128,Data(hex:signature)?.count==64 else{throw AppFailure("Invalid relay authorization.")}
            request.setValue(time,forHTTPHeaderField:"x-paramo1d-time");request.setValue(signature,forHTTPHeaderField:"x-paramo1d-signature")
        }
        let (stream,response)=try await session.bytes(for:request)
        guard let http=response as? HTTPURLResponse else {throw AppFailure("The chat relay returned no HTTP response. Try again.")}
        guard http.statusCode==200 else {
            let detail: String
            switch http.statusCode {
            case 401,403: detail="Relay authorization was rejected. Check the phone clock and your chat identity."
            case 429: detail="The chat relay is rate-limiting requests. Wait before retrying."
            default: detail="Chat relay returned HTTP \(http.statusCode). Try again."
            }
            throw AppFailure(detail + " Delivery is not confirmed.")
        }
        var data=Data()
        for try await byte in stream {try Task.checkCancellation();guard data.count<4*1024*1024 else{throw RelayResponseError.tooLarge};data.append(byte)}
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw AppFailure("Invalid relay response.")}
        return object
    }
    func send(_ ciphertext:Data) async throws {
        let result=try await request("/v1/messages",body:ciphertext)
        guard result["accepted"] as? Bool == true else{throw AppFailure("Relay did not acknowledge this packet.")}
    }
    func inbox(auth:[String:Any]) async throws -> [String:Any] {
        guard let path=auth["path"] as? String,path.hasPrefix("/v1/inbox/"),path.utf8.count<200 else{throw AppFailure("Invalid inbox authorization.")}
        let response=try await request(path,auth:auth)
        guard let limit=auth["limit"] as? Int,(1...30).contains(limit),let messages=response["messages"] as? [[String:Any]],messages.count<=limit else{throw AppFailure("Invalid inbox page.")}
        return response
    }
    func community(after:UInt64,limit:Int=30) async throws -> [String:Any] {
        guard (1...30).contains(limit) else{throw AppFailure("Invalid community page size.")}
        let response=try await request("/v1/groups/parano1d/messages?after=\(after)&limit=\(limit)")
        guard let entries=response["messages"] as? [[String:Any]],entries.count<=limit,
              let cursor=response["cursor"] as? NSNumber,cursor.uint64Value>=after else{throw AppFailure("Invalid community page.")}
        return response
    }
    func communityTip() async throws -> UInt64 {
        let response=try await request("/v1/groups")
        guard let groups=response["groups"] as? [[String:Any]],groups.count<=100,
              let lobby=groups.first(where:{$0["id"] as? String == "parano1d"}),
              let cursor=lobby["cursor"] as? NSNumber else{throw AppFailure("Community room is unavailable.")}
        return cursor.uint64Value
    }
}

/// Walk the bounded recent window; a first-page-only refresh misses new posts.
@MainActor enum CommunityPaging {
    static func load(after: UInt64, through tip: UInt64,
                     fetch: (UInt64) async throws -> [String: Any]) async throws -> [String: Any] {
        var cursor = after
        var entries: [[String: Any]] = []
        for _ in 0..<8 {
            try Task.checkCancellation()
            let page = try await fetch(cursor)
            guard let batch = page["messages"] as? [[String: Any]], batch.count <= 30,
                  let value = page["cursor"] as? NSNumber else { throw AppFailure("Invalid community page.") }
            let next = value.uint64Value
            guard next >= cursor else { throw AppFailure("Community cursor moved backwards.") }
            if batch.isEmpty { return ["messages": entries, "cursor": cursor] }
            var previous = cursor
            for entry in batch {
                guard let value = entry["cursor"] as? NSNumber, value.uint64Value > previous,
                      value.uint64Value <= next else { throw AppFailure("Invalid community message ordering.") }
                previous = value.uint64Value
                entries.append(entry)
            }
            guard next == previous else { throw AppFailure("Community cursor skipped unseen messages.") }
            cursor = next
            if cursor >= tip { return ["messages": entries, "cursor": cursor] }
        }
        throw AppFailure("The recent room window could not be fully refreshed. Retry shortly.")
    }
}
