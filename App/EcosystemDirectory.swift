import SwiftUI

struct EcosystemCategory: Identifiable {
    let id: String
    let label: String
}

enum EcosystemDirectoryParser {
    static func parse(_ bytes: Data) throws -> (categories: [EcosystemCategory], sites: [EcosystemSite]) {
        guard bytes.count <= 512_000,
              let document = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              document["version"] as? Int == 1,
              let rawCategories = document["categories"] as? [[String: Any]],
              let rawProjects = document["projects"] as? [[String: Any]],
              rawCategories.count <= 30, rawProjects.count <= 300 else {
            throw AppFailure("The ecosystem directory format is unavailable.")
        }
        let categories: [EcosystemCategory] = rawCategories.compactMap { raw in
            guard let id = raw["id"] as? String, id.count <= 40,
                  let label = raw["label"] as? String, !label.isEmpty, label.count <= 100 else { return nil }
            return .init(id: id, label: label)
        }
        let known = Set(categories.map(\.id))
        var seen = Set<String>(), seenURLs = Set<String>()
        let sites: [EcosystemSite] = rawProjects.compactMap { raw in
            guard let id = raw["id"] as? String, !id.isEmpty, id.count <= 100,
                  let name = raw["name"] as? String, !name.isEmpty, name.count <= 120,
                  let category = raw["category"] as? String, known.contains(category),
                  let address = raw["url"] as? String, address.count <= 2048,
                  let url = URL(string: address), BrowsingOrigin.origin(url) != nil,
                  seen.insert(id).inserted, seenURLs.insert(url.absoluteString).inserted else { return nil }
            let description = raw["description"] as? String ?? ""
            return .init(name: name, url: url, category: category,
                         summary: String(description.prefix(300)))
        }
        guard !categories.isEmpty, !sites.isEmpty else { throw AppFailure("The ecosystem directory is empty.") }
        return (categories, sites)
    }
}

@MainActor final class EcosystemDirectory: ObservableObject {
    @Published private(set) var categories: [EcosystemCategory] = []
    @Published private(set) var sites: [EcosystemSite] = []
    @Published private(set) var updated: Date?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    private static let source = URL(string: "https://parano1d.org/ecosystem.json")!
    private let session = URLSession(configuration:.ephemeral,delegate:RejectRedirects(),delegateQueue:nil)
    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            var request = URLRequest(url: Self.source)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.url == Self.source else { throw AppFailure("Official directory could not be reached.") }
            var bytes = Data()
            for try await byte in stream {
                try Task.checkCancellation()
                guard bytes.count < 512_000 else { throw AppFailure("Ecosystem directory exceeds size limit.") }
                bytes.append(byte)
            }
            let parsed = try EcosystemDirectoryParser.parse(bytes)
            try Task.checkCancellation()
            categories = parsed.categories; sites = parsed.sites; updated = Date(); error = nil
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
