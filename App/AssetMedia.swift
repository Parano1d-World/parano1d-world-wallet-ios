import SwiftUI
import ImageIO

struct AssetDisplay {
    let name: String
    let image: UIImage?
}
private actor ArtworkLoadGate {
    private var active = 0
    private var waiting: [CheckedContinuation<Void,Never>] = []
    func acquire() async {
        if active < 4 { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().resume() }
    }
}
actor AssetMedia {
    static let shared = AssetMedia()
    /// Lower-case hex in one pass. String(format:) per byte took seconds for a 4 MB image.
    nonisolated static func hex(_ data: Data) -> String {
        let digits=Array("0123456789abcdef".utf8)
        var out=[UInt8](repeating:0,count:data.count*2)
        var i=0
        for byte in data { out[i]=digits[Int(byte>>4)];out[i+1]=digits[Int(byte&0x0f)];i+=2 }
        return String(decoding:out,as:UTF8.self)
    }
    private let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
    private var cache: [String: AssetDisplay] = [:]
    private var order: [String] = []
    private var cacheBytes = 0
    private let loadGate = ArtworkLoadGate()
    private var inFlight: [String:Task<AssetDisplay,Error>] = [:]
    /// Hash-checked full-size PNG resource for each loaded NFT (for full screen and saving).
    private var verifiedImageResource: [String:String] = [:]
    func cancelLoads() { for task in inFlight.values { task.cancel() } }
    func trimMemory() { cache.removeAll();order.removeAll();cacheBytes=0 }
    private func fetch(_ path: String, limit: Int, allowNetwork: Bool = true) async throws -> Data {
        if let saved=try? await ArtworkDiskCache.shared.read(path,limit:limit) {return saved}
        guard allowNetwork else {throw AppFailure("Artwork is not saved on this device.")}
        let url = URL(string: "https://tradedata.parano1d.org/" + path)!
        var request = URLRequest(url: url); request.timeoutInterval = 15
        // Downloads to a temporary file in one transfer (the old byte-by-byte stream was
        // the main cause of slow NFT artwork), then checks the size before reading it.
        let (file,response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at:file) }
        try Task.checkCancellation()
        guard let http=response as? HTTPURLResponse, http.statusCode == 200 else { throw AppFailure("Asset media unavailable.") }
        guard http.expectedContentLength <= Int64(limit) else { throw AppFailure("Asset media exceeds size limit.") }
        let size=(try? file.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? Int.max
        guard size <= limit else { throw AppFailure("Asset media exceeds size limit.") }
        let result = try Data(contentsOf:file)
        try? await ArtworkDiskCache.shared.save(result,resource:path)
        return result
    }
    func loadName(hash: String) async throws -> String {
        guard hash.count == 64, hash.range(of: "^[a-f0-9]+$", options: .regularExpression) != nil else { throw AppFailure("Invalid metadata identity.") }
        let bytes = try await fetch("metadata/\(hash).json", limit: 8192)
        do {
            let manifest = try JSONSerialization.jsonObject(with: bytes)
            let checked = try await NativeCore.shared.call(["op": "inspect_metadata", "manifest": manifest, "expected_hash": hash])
            guard let name = checked["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("Metadata name missing.") }
            return name
        } catch {
            await ArtworkDiskCache.shared.remove("metadata/\(hash).json")
            throw error
        }
    }
    func load(hash: String) async throws -> AssetDisplay {
        if let cached = cache[hash] { return cached }
        if let existing = inFlight[hash] { return try await existing.value }
        let task = Task {
            await loadGate.acquire()
            do {
                try Task.checkCancellation()
                let result = try await self.loadUncached(hash:hash)
                await loadGate.release()
                return result
            } catch {
                await loadGate.release()
                throw error
            }
        }
        inFlight[hash] = task
        defer { inFlight[hash] = nil }
        return try await task.value
    }
    /// Full-resolution artwork (up to 2048 px) for the full-screen view and Save to Photos.
    /// Loads and hash-checks the NFT first, then reads the verified PNG from the disk cache.
    func fullImage(hash: String) async throws -> UIImage {
        _ = try await load(hash: hash)
        guard let resource = verifiedImageResource[hash] else { throw AppFailure("This NFT has no artwork.") }
        let png = try await fetch(resource, limit: 4 * 1024 * 1024, allowNetwork: false)
        guard let image = UIImage(data: png) else { throw AppFailure("Image decoding failed.") }
        return image
    }
    func loadCached(hash:String) async throws -> AssetDisplay {
        if let cached=cache[hash] {return cached}
        return try await loadUncached(hash:hash,allowNetwork:false)
    }
    private func loadUncached(hash: String, allowNetwork: Bool = true) async throws -> AssetDisplay {
        guard hash.count == 64, hash.range(of: "^[a-f0-9]+$",options: .regularExpression) != nil else { throw AppFailure("Invalid metadata identity.") }
        if let cached = cache[hash] { return cached }
        var imageResource: String?
        do {
        let bytes = try await fetch("metadata/\(hash).json",limit: 8192,allowNetwork:allowNetwork)
        let manifest = try JSONSerialization.jsonObject(with: bytes)
        let checked = try await NativeCore.shared.call(["op": "inspect_metadata", "manifest": manifest, "expected_hash": hash])
        guard let name = checked["name"] as? String else { throw AppFailure("Metadata name missing.") }
        var image: UIImage?
        if let spec = checked["image"] as? [String: Any], let imageHash = spec["hash"] as? String,
           let size = spec["bytes"] as? Int, let width = spec["width"] as? Int, let height = spec["height"] as? Int {
            imageResource="images/\(imageHash).png"
            let png = try await fetch("images/\(imageHash).png",limit: 4 * 1024 * 1024,allowNetwork:allowNetwork)
            guard png.count == size, png.starts(with: [137,80,78,71,13,10,26,10]) else { throw AppFailure("Image size or format mismatch.") }
            _ = try await NativeCore.shared.call(["op": "inspect_image", "bytes_hex": AssetMedia.hex(png), "expected_hash": imageHash])
            guard let source = CGImageSourceCreateWithData(png as CFData,nil), CGImageSourceGetCount(source) == 1,
                  let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString: Any],
                  props[kCGImagePropertyPixelWidth] as? Int == width, props[kCGImagePropertyPixelHeight] as? Int == height,
                  width <= 2048, height <= 2048 else { throw AppFailure("Image dimensions rejected.") }
            let options: [CFString:Any] = [kCGImageSourceCreateThumbnailFromImageAlways:true,
                kCGImageSourceThumbnailMaxPixelSize:768,kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceShouldCacheImmediately:true]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source,0,options as CFDictionary) else { throw AppFailure("Image decoding failed.") }
            image = UIImage(cgImage:thumbnail)
            verifiedImageResource[hash] = "images/\(imageHash).png"
        }
        let display = AssetDisplay(name: name,image: image)
        let cost = image?.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        while !order.isEmpty && (cache.count >= 64 || cacheBytes + cost > 32 * 1024 * 1024) {
            let key = order.removeFirst()
            if let old = cache.removeValue(forKey: key)?.image?.cgImage { cacheBytes -= old.bytesPerRow * old.height }
        }
        cache[hash] = display; order.append(hash); cacheBytes += cost
        return display
        } catch {
            // A corrupt/unvalidated disk entry must not permanently poison retries.
            if allowNetwork && !(error is CancellationError) {
                await ArtworkDiskCache.shared.remove("metadata/\(hash).json")
                if let imageResource {await ArtworkDiskCache.shared.remove(imageResource)}
            }
            throw error
        }
    }
}
struct AssetThumbnail: View {
    @AppStorage(DisplayStyle.storageKey) private var appDisplayStyle="system"
    let item: NativeItem
    let enabled: Bool
    var allowsRetry = false
    var showsTitle = true
    @State private var loadedHash: String?
    @State private var retry = 0
    @State private var failure: String?
    @State private var media: AssetDisplay?
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading,spacing: 9) {
            Group {
                // The art keeps its own shape and sits centred in the square (portrait and landscape art
                // used to hug the left edge), with its own rounded corners.
                if let image = media?.image {
                    Color.clear.overlay { Image(uiImage: image).resizable().interpolation(.high).scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14)) }
                } else {
                    Rectangle().fill(Theme.panel).overlay {
                        VStack(spacing: 10) {
                            if loading { ProgressView().tint(Theme.mint) }
                            else { Image(systemName: enabled ? "photo" : "eye.slash").font(.system(size: 24, weight: .ultraLight)) }
                            Text(loading ? "Loading artwork" : enabled ? "Artwork unavailable" : "Artwork off").font(Theme.caption)
                        }.foregroundStyle(Theme.secondary).padding(12)
                    }
                }
            }.aspectRatio(1,contentMode: .fit).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 16))
            if allowsRetry, enabled, let failure {
                Text(failure).font(Theme.caption).foregroundStyle(.orange)
                Button("Retry artwork") { retry += 1 }.disabled(loading)
            }
            if showsTitle { Text(media?.name ?? (item.text("serial").isEmpty ? String(item.collection.prefix(10)) : "NFT #" + item.text("serial"))).font(Theme.editorial(17)).foregroundStyle(Theme.text).lineLimit(2) }
        }.onDisappear { media=nil; loadedHash=nil; loading=false }.task(id: "\(enabled)-\(item.text("metadata_hash"))-\(retry)") {
            let hash=item.text("metadata_hash")
            failure = nil
            guard enabled else { media=nil;loadedHash=nil;loading = false; return }
            if loadedHash != hash {media=nil}
            if loadedHash == hash,media != nil,retry == 0 {loading=false;return}
            loading = true
            do {
                let loaded = try await AssetMedia.shared.load(hash: item.text("metadata_hash"))
                guard !Task.isCancelled else { return }
                media = loaded; loadedHash=hash; loading = false
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription; loading = false
            }
        }
    }
}
