import Foundation
import Security
import SwiftUI

struct GatewayConfiguration: Codable, Equatable {
    var baseURL: String
    var chainID: String
    // An installed public service is an address, not a credential. The node
    // identity remains pinned by the device framework, and no key is bundled.
    static var bundled: GatewayConfiguration? {
        guard let address = Bundle.main.object(forInfoDictionaryKey: "Parano1dPublicGatewayURL") as? String,
              let url = URL(string: address), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let identity = try? DeviceNodeBridge.call(["op":"chain_identity"]),
              let chain = identity["chain_id"] as? String else { return nil }
        return GatewayConfiguration(baseURL: address, chainID: chain)
    }
    var isBundled: Bool { self == Self.bundled }
    // A bundled URL never opts the wallet into a gateway connection.
    static var enabled:Bool {UserDefaults.standard.object(forKey:"gatewayEnabled") as? Bool ?? false}
    static var saved: GatewayConfiguration? {enabled ? stored : nil}
    static var stored: GatewayConfiguration? {
        guard let bytes = UserDefaults.standard.data(forKey: "gatewayConfiguration") else { return nil }
        return try? JSONDecoder().decode(Self.self, from: bytes)
    }
    func validate() throws -> URL {
        guard let url = URL(string: baseURL), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              chainID.count == 64, chainID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw AppFailure("Use an HTTPS gateway URL and its trusted 64-character chain identity.") }
        let pinned=try DeviceNodeBridge.call(["op":"chain_identity"])
        guard chainID == pinned["chain_id"] as? String else {throw AppFailure("Gateway chain identity differs from this device's pinned Parano1d chain.")}
        return url
    }
    func save(token: String) throws {
        _ = try validate()
        guard (32...256).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else {
            throw AppFailure("Use a 32–256 character ASCII gateway access token.")
        }
        try GatewayCredential.save(token)
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "gatewayConfiguration")
        UserDefaults.standard.set(true,forKey:"gatewayEnabled")
        UserDefaults.standard.set(Date(),forKey:"gatewayLastConnectionTest")
    }
}
enum GatewayCredential {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.koajent.parano1d.gateway", kSecAttrAccount as String: "access", kSecAttrSynchronizable as String: false] }
    static func save(_ token: String) throws {
        let update = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = Data(token.utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure("Unable to save gateway access.") }
    }
    static func load() throws -> String {
        var q = query; q[kSecReturnData as String] = true
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess, let data = value as? Data, let token = String(data: data, encoding: .utf8) else { throw AppFailure("Gateway credentials are not configured.") }
        return token
    }
    static func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppFailure("Unable to remove gateway access (\(status)).") }
    }
}
final class RejectRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
actor GatewayClient {
    private let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
    let configuration: GatewayConfiguration
    private let candidateCredential: String?
    init(_ configuration: GatewayConfiguration, credential: String? = nil) { self.configuration = configuration; self.candidateCredential = credential }
    func query(_ body: [String: Any]) async throws -> [String: Any] {
        let base = try configuration.validate()
        var request = URLRequest(url: base.appendingPathComponent("v1/query"))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let credential = try candidateCredential ?? GatewayCredential.load()
        request.setValue("Bearer " + credential, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw AppFailure("Gateway request failed. Refresh or check configuration.") }
        var bytes = Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard bytes.count < 4 * 1024 * 1024 else { throw AppFailure("Gateway response exceeds the limit.") }
            bytes.append(byte)
        }
        guard let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], result["chain_id"] as? String == configuration.chainID else { throw AppFailure("Gateway chain identity mismatch.") }
        guard let value = result["result"] as? [String: Any] else { throw AppFailure("Malformed gateway result.") }
        return value
    }
}
struct NativeItem: Identifiable {
    var nftDisplayID:String {collection + ":" + text("serial")}
    let fields: [String: Any]
    var id: String { text("root") + ":" + text("slot_index") }
    func text(_ name: String) -> String { fields[name] as? String ?? "" }
    var type: String { text("type") }
    var collection: String { text("collection_id") }
    var asset: String { text("asset_id") }
    var marketKey: String { type + ":" + asset }
    var price: Double? {
        guard let n = Double(text("price_numerator")), let d = Double(text("price_denominator")), n > 0, n.isFinite, d > 0, d.isFinite else { return nil }
        let value=n/d
        return value.isFinite && value>0 ? value : nil
    }
}
enum NativeAssetMetadata {
    /// Join only market metadata at the same catalog boundary as holdings.
    static func attach(to holdings:[NativeItem],markets:[NativeItem])->[NativeItem] {
        let candidates=markets.compactMap { market -> (String,String)? in
            let hash=market.text("metadata_hash")
            guard market.asset.count==64,hash.count==64,
                  hash.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil else{return nil}
            return (market.asset,hash)
        }
        let grouped=Dictionary(grouping:candidates,by:{$0.0})
        let hashes=grouped.compactMapValues { entries -> String? in
            guard let first=entries.first?.1,entries.allSatisfy({$0.1==first}) else{return nil}
            return first
        }
        return holdings.map { item in
            guard item.type=="token",let hash=hashes[item.asset] else{return item}
            var fields=item.fields;fields["metadata_hash"]=hash
            return NativeItem(fields:fields)
        }
    }
}
struct PriceSample: Identifiable {
    let id = UUID()
    let time: Date
    let price: Double
    let block: String
}
enum PriceObservations {
    static func append(_ sample:PriceSample,to history:[PriceSample])->[PriceSample] {
        guard sample.price.isFinite,sample.price>0 else{return history}
        if let prior=history.firstIndex(where:{$0.block==sample.block}) {
            return Array(history.prefix(prior+1))
        }
        return Array((history+[sample]).suffix(180))
    }
}
enum Amounts {
    static func format(_ raw: String) -> String? {
        guard let n = UInt64(raw), String(n) == raw else { return nil }
        let whole = n / 1_000_000, remainder = n % 1_000_000
        if remainder == 0 { return String(whole) }
        let tail = String(format: "%06llu", remainder).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
        return "\(whole).\(tail)"
    }
    static func parse(_ text: String) -> String? {
        guard text.range(of: "^[0-9]+(?:\\.[0-9]{1,6})?$", options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = UInt64(parts[0]) else { return nil }
        let (scaled, overflow) = whole.multipliedReportingOverflow(by: 1_000_000)
        guard !overflow else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]).padding(toLength: 6, withPad: "0", startingAt: 0) : "0"
        guard let tail = UInt64(fraction) else { return nil }
        let (sum, overflow2) = scaled.addingReportingOverflow(tail)
        return overflow2 ? nil : String(sum)
    }
}
@MainActor final class LiveData: ObservableObject {
    @Published var balance: String?
    @Published var markets: [NativeItem] = []
    @Published var collections: [NativeItem] = []
    @Published var listings: [NativeItem] = []
    @Published var listingsHeight:UInt64?
    @Published var listingsError:String?
    @Published var holdings: [NativeItem] = []
    @Published var samples: [String: [PriceSample]] = [:]
    @Published var updated: Date?
    @Published private(set) var savedSnapshotDate: Date?
    @Published private(set) var savedHoldingsHeight: UInt64?
    @Published private(set) var holdingsVerifiedLocally = false
    @Published var error: String?
    @Published var refreshing = false
    @Published var parentHash: String?
    @Published var catalogHeight: UInt64?
    @Published var holdingsHash: String?
    @Published var holdingsHeight: UInt64?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var nextAttempt = Date.distantPast
    func stop() { generation = UUID(); task?.cancel(); task = nil; refreshing = false }
    func pauseGateway() {stop();parentHash=nil;catalogHeight=nil}
    func clear() { stop(); savedSnapshotDate=nil; savedHoldingsHeight=nil; holdingsVerifiedLocally=false; listingsHeight=nil;listingsError=nil; nextAttempt = .distantPast; error = nil; balance = nil; holdings = []; updated = nil; parentHash = nil; catalogHeight = nil; holdingsHash = nil; holdingsHeight = nil; markets = []; collections = []; listings = []; samples = [:] }
    func refreshAndWait(owner: String, offline: Bool) async {
        refresh(owner: owner, offline: offline, force: true)
        await task?.value
    }
    func refresh(owner: String, offline: Bool, force: Bool = false) {
        guard !refreshing, !offline, force || Date() >= nextAttempt else { return }
        nextAttempt = Date().addingTimeInterval(10)
        let token = generation; refreshing = true
        task = Task {
            defer { if token == generation { refreshing = false; task = nil } }
            // A node refresh can complete (or fail) before the view's restore
            // task runs. Publish the last verified inventory first so login
            // and offline-to-online transitions do not start with an empty list.
            await restoreDisplay(owner: owner)
            guard token == generation, !Task.isCancelled else { return }
            let local: (items: [NativeItem], collections: [NativeItem], height: UInt64, hash: String)? = try? await localHoldings(owner: owner)
            // Show owned tokens and NFTs as soon as the verified holdings are read; market,
            // collection and listing data (each a separate State read) fill in after.
            if let local, token == generation, GatewayConfiguration.saved == nil {
                holdings = local.items
                if collections.isEmpty { collections = local.collections }
                holdingsHash = local.hash; holdingsHeight = local.height
                holdingsVerifiedLocally=true; savedSnapshotDate=nil; savedHoldingsHeight=nil
            }
            var localListingIssue:String?
            let localListings:(items:[NativeItem],height:UInt64,hash:String)?
            do {localListings=try await localMarkets(operation:"native_listings")}
            catch {localListings=nil;localListingIssue=error.localizedDescription}
            let localMarket: (items: [NativeItem], height: UInt64, hash: String)? = try? await localMarkets()
            let localCollections: (items: [NativeItem], height: UInt64, hash: String)? = try? await localMarkets(operation:"native_collections")
            if let local, token == generation {
                // Save only complete native State holdings bound to a verified block.
                persistVerifiedHoldings(owner:owner,local:local,market:localMarket,
                                        collections:localCollections,listings:localListings)
            }
            do {
                if let local, GatewayConfiguration.saved == nil {
                    guard token == generation else { return }
                    holdings = localMarket?.hash == local.hash
                        ? NativeAssetMetadata.attach(to:local.items,markets:localMarket?.items ?? []) : local.items
                    balance = nil
                    if let localMarket,localMarket.hash == local.hash {markets=localMarket.items}
                    collections = localCollections?.hash == local.hash ? (localCollections?.items ?? []) : local.collections
                    if let localListings,localListings.hash == local.hash {listings=localListings.items;listingsHeight=localListings.height}
                    listingsError = localListings?.hash != local.hash ? (localListingIssue ?? "NFT listings changed during refresh. Retry to load a consistent snapshot.") : nil
                    parentHash = local.hash; catalogHeight = local.height; updated = Date(); error = nil
                    holdingsHash = local.hash; holdingsHeight = local.height
                    holdingsVerifiedLocally=true; savedSnapshotDate=nil; savedHoldingsHeight=nil
                    if localMarket?.hash != local.hash || localCollections?.hash != local.hash {parentHash=nil}
                    return
                }
                guard let config = GatewayConfiguration.saved else {
                    throw AppFailure("On-device native State is still synchronizing. Saved inventory remains visible until a fresh verified snapshot is installed.")
                }
                guard NativeCore.available else { throw AppFailure("Native engine is required to decode and check market data.") }
                let client = GatewayClient(config)
                async let marketPage = catalog("markets", client: client)
                async let collectionPage = catalog("collections", client: client)
                async let listingPage = catalog("nft_listings", client: client)
                let (market, collection, listing) = try await (marketPage, collectionPage, listingPage)
                guard market.parent == collection.parent, market.parent == listing.parent,
                      market.height == collection.height, market.height == listing.height else { throw AppFailure("Markets changed during refresh. Waiting for a consistent snapshot.") }
                // Public gateways deliberately do not expose the unverified
                // balance operation. DeviceNode owns verified NOID balances.
                // Do not disclose this owner again when local holdings exist.
                var owned: [NativeItem] = []
                if !owner.isEmpty, case nil = local {
                    owned = try await walletHoldings(owner, parent: market.parent, client: client)
                }
                try Task.checkCancellation()
                guard token == generation else { return }
                markets = market.items
                collections = (local?.hash == market.parent && localCollections?.hash == market.parent)
                    ? (localCollections?.items ?? []) : collection.items
                listings = listing.items;listingsHeight=listing.height;listingsError=nil
                if let local {
                    holdings = local.hash == market.parent
                        ? NativeAssetMetadata.attach(to:local.items,markets:market.items) : local.items
                    holdingsHash = local.hash; holdingsHeight = local.height
                    holdingsVerifiedLocally=true; savedSnapshotDate=nil; savedHoldingsHeight=nil
                } else {
                    // Catalog/remote discovery cannot replace saved verified ownership.
                    if savedSnapshotDate == nil { holdings = NativeAssetMetadata.attach(to:owned,markets:market.items) }
                    holdingsHash = nil; holdingsHeight = nil; holdingsVerifiedLocally=false
                }
                balance = nil; parentHash = market.parent; catalogHeight = market.height; updated = Date(); error = nil
                let active=Set(market.items.map(\.marketKey))
                samples=samples.filter{active.contains($0.key)}
                for item in market.items {
                    guard let price = item.price else { continue }
                    let history = samples[item.marketKey] ?? []
                    // A repeated older snapshot must not appear as new price
                    // movement; reset its later observations on a rollback.
                    samples[item.marketKey] = PriceObservations.append(.init(time:Date(),price:price,block:market.parent),to:history)
                }
            } catch is CancellationError { }
            catch {
                guard token == generation else { return }
                if let local {
                    holdings = local.items; balance = nil
                    if let localMarket,localMarket.hash == local.hash {markets=localMarket.items}
                    collections = localCollections?.hash == local.hash ? (localCollections?.items ?? []) : local.collections
                    if let localListings,localListings.hash == local.hash {listings=localListings.items;listingsHeight=localListings.height}
                    listingsError = localListings?.hash != local.hash ? (localListingIssue ?? "NFT listings changed during refresh. Retry to load a consistent snapshot.") : nil
                    parentHash = local.hash; catalogHeight = local.height; updated = Date()
                    holdingsHash = local.hash; holdingsHeight = local.height
                    holdingsVerifiedLocally=true; savedSnapshotDate=nil; savedHoldingsHeight=nil
                    if localMarket?.hash != local.hash || localCollections?.hash != local.hash {parentHash=nil}
                    self.error = "Live data service is unavailable. Installed State holdings are shown at verified block \(local.height)."
                } else { self.error = error.localizedDescription;listingsError=error.localizedDescription }
            }
        }
    }
    func restoreDisplay(owner:String) async {
        guard updated == nil,savedSnapshotDate == nil,AddressValidator.valid(owner) else{return}
        let token=generation
        do {
            let chain=try DisplaySnapshotStore.chainID()
            let verified=try await DisplaySnapshotStore.shared.load(kind:"verified_assets",owner:owner,chain:chain)
            let saved: (payload:[String:Any],date:Date)?
            if let verified { saved=verified }
            else { saved=try await DisplaySnapshotStore.shared.load(kind:"assets",owner:owner,chain:chain) }
            guard let saved else{return}
            if case .some = verified {
                guard let height=saved.payload["holdings_height"] as? NSNumber,height.uint64Value>0,
                      let hash=saved.payload["holdings_hash"] as? String,Data(hex:hash)?.count==32 else{return}
            }
            guard token == generation,updated == nil,savedSnapshotDate == nil,!Task.isCancelled else{return}
            func items(_ key:String) -> [NativeItem] {
                let rows=saved.payload[key] as? [[String:Any]] ?? []
                return Array(rows.prefix(16384)).map {NativeItem(fields:$0)}
            }
            holdings=items("holdings");collections=items("collections");listings=items("listings");markets=items("markets")
            savedHoldingsHeight=(saved.payload["holdings_height"] as? NSNumber)?.uint64Value
            holdingsHeight=nil; listingsHeight=nil; holdingsVerifiedLocally=false
            savedSnapshotDate=saved.date
            // Saved display data never authorizes a trade or claims a fresh response.
            parentHash=nil;catalogHeight=nil;updated=nil;holdingsHash=nil
        } catch { /* A bad cache must not block a fresh verified refresh. */ }
    }
    private func persistVerifiedHoldings(owner:String,local:(items:[NativeItem],collections:[NativeItem],height:UInt64,hash:String),
                                         market:(items:[NativeItem],height:UInt64,hash:String)?,
                                         collections:(items:[NativeItem],height:UInt64,hash:String)?,
                                         listings:(items:[NativeItem],height:UInt64,hash:String)?) {
        guard AddressValidator.valid(owner),local.height>0,local.hash.count==64,
              Data(hex:local.hash)?.count==32,let chain=try? DisplaySnapshotStore.chainID() else{return}
        let matchingMarket=market?.hash == local.hash ? market?.items ?? [] : []
        let matchingCollections=collections?.hash == local.hash ? collections?.items ?? [] : local.collections
        // Listings that couldn't be read at this block keep the last ones shown (display only),
        // instead of saving an empty list that hid listed NFTs until a later full read.
        let matchingListings=listings?.hash == local.hash ? listings?.items ?? [] : self.listings
        let items=NativeAssetMetadata.attach(to:local.items,markets:matchingMarket)
        let payload:[String:Any]=["holdings":items.map(\.fields),"collections":matchingCollections.map(\.fields),
                                  "holdings_height":local.height,"holdings_hash":local.hash,
                                  "listings":matchingListings.map(\.fields),"markets":matchingMarket.map(\.fields)]
        let time=Date()
        Task {try? await DisplaySnapshotStore.shared.save(kind:"verified_assets",owner:owner,chain:chain,payload:payload,date:time)}
    }
    func localHoldings(owner: String) async throws -> (items: [NativeItem], collections: [NativeItem], height: UInt64, hash: String) {
        guard !owner.isEmpty, DeviceNodeBridge.available,
              let artifacts = Bundle.main.url(forResource: "NodeParameters", withExtension: nil) else {
            throw AppFailure("No local native State available.")
        }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("VerifiedNode", isDirectory: true)
        let result = await Task.detached(priority: .userInitiated) {
            Result { try DeviceNodeBridge.call(["op":"native_holdings", "owner":owner,
                "artifacts":artifacts.path, "data_dir":directory.path]) }
        }.value
        let payload = try result.get()
        guard payload["owner"] as? String == owner, payload["complete"] as? Bool == true,
              let height = payload["height"] as? NSNumber, height.uint64Value > 0,
              let hash = payload["block_hash"] as? String, hash.count == 64,
              let records = payload["items"] as? [[String: Any]],
              let definitions = payload["collections"] as? [[String: Any]] else {
            throw AppFailure("Local native holdings are incomplete.")
        }
        return (records.map { NativeItem(fields: $0) }, definitions.map { NativeItem(fields: $0) }, height.uint64Value, hash)
    }
    private func localMarkets(operation:String="native_markets") async throws -> (items: [NativeItem], height: UInt64, hash: String) {
        guard DeviceNodeBridge.available,
              let artifacts = Bundle.main.url(forResource: "NodeParameters", withExtension: nil) else {
            throw AppFailure("No local native State available.")
        }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("VerifiedNode", isDirectory: true)
        let result = await Task.detached(priority: .utility) {
            Result { try DeviceNodeBridge.call(["op":operation,
                "artifacts":artifacts.path, "data_dir":directory.path]) }
        }.value
        let payload = try result.get()
        guard payload["complete"] as? Bool == true,
              let height = payload["height"] as? NSNumber, height.uint64Value > 0,
              let hash = payload["block_hash"] as? String, hash.count == 64,
              let records = payload["items"] as? [[String: Any]] else {
            throw AppFailure("Local native markets are incomplete.")
        }
        return (records.map { NativeItem(fields: $0) }, height.uint64Value, hash)
    }
    private func catalog(_ kind: String, client: GatewayClient) async throws -> (items: [NativeItem], parent: String, height: UInt64) {
        var cursor: Any = NSNull(), items: [NativeItem] = [], parent: String?, height: UInt64?
        for _ in 0..<64 {
            try Task.checkCancellation()
            let page = try await client.query(["kind": "catalog", "catalog": kind, "cursor": cursor])
            guard page["kind"] as? String == kind, let hash = page["block_hash"] as? String, hash.count == 64, Data(hex: hash)?.count == 32,
                  let pageHeight = page["height"] as? NSNumber, pageHeight.int64Value >= 0 else { throw AppFailure("Catalog identity mismatch.") }
            if let parent, parent != hash { throw AppFailure("Catalog changed during pagination. Refresh required.") }
            if let height, height != pageHeight.uint64Value { throw AppFailure("Catalog height changed during pagination.") }
            parent = hash
            height = pageHeight.uint64Value
            let checked = try await NativeCore.shared.call(["op": "inspect_items", "page": page])
            guard let values = checked["items"] as? [[String: Any]] else { throw AppFailure("Invalid catalog items.") }
            items += values.map { NativeItem(fields: $0) }
            guard let next = page["next"], !(next is NSNull) else { return (items, hash, pageHeight.uint64Value) }
            cursor = next
        }
        throw AppFailure("Catalog exceeds this client's pagination limit. No partial catalog was applied.")
    }
    private func walletHoldings(_ owner: String, parent expectedParent: String, client: GatewayClient) async throws -> [NativeItem] {
        var cursor: Any = NSNull(), items: [NativeItem] = [], parent: String?
        for _ in 0..<64 {
            let page = try await client.query(["kind": "holdings", "owner": owner, "cursor": cursor])
            guard page["owner"] as? String == owner, let hash = page["block_hash"] as? String, hash == expectedParent else { throw AppFailure("Holdings owner mismatch.") }
            if let parent, parent != hash { throw AppFailure("Holdings changed during refresh.") }; parent = hash
            let checked = try await NativeCore.shared.call(["op": "inspect_holdings", "holdings": page["holdings"] ?? []])
            guard let values = checked["items"] as? [[String: Any]] else { throw AppFailure("Invalid holdings.") }
            items += values.map { NativeItem(fields: $0) }
            guard let next = page["next"], !(next is NSNull) else { return items }; cursor = next
        }
        throw AppFailure("Holdings exceed the pagination limit.")
    }
}

/// Pull-to-refresh waits for a refresh for a few seconds at most, then lets the
/// spinner close while the refresh finishes in the background. A long-lived spinner
/// collapsing under a finger moved Home and opened the wrong row (Receipts → backup).
enum PullRefresh {
    @MainActor static func wait(seconds: Double, _ work: @escaping @MainActor () async -> Void) async {
        let job = Task { @MainActor in await work() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await job.value }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }
}
