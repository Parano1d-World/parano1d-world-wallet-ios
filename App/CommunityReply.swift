import Foundation

/// The public room carries text packets. Keep the entire quoted post in the
/// signed text so recipients can read it even after their recent-post page moves.
enum CommunityReply {
    static let maximumBytes = 4096

    static func quote(name: String, message: String) -> String {
        name + ":\n" + message
    }

    static func compose(quote: String?, draft: String) -> String {
        (quote.map { "↪ \($0)\n\n" } ?? "") + draft
    }

    static func fits(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= maximumBytes
    }
}
