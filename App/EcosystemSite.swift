import Foundation

/// A website listed in the Ecosystem tab. The App Store edition opens every site in the system browser
/// after a leaving notice; it has no in-app website browser and no website wallet connection.
struct EcosystemSite: Identifiable {
    let name: String
    let url: URL
    var category: String = "apps"
    var summary: String = ""
    var id: String { url.absoluteString }
}
enum BrowsingOrigin {
    static func origin(_ url: URL?) -> String? {
        guard let url, url.scheme == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return "https://" + host
    }
}
