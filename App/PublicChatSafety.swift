import Foundation

/// Deliberately narrow, deterministic public-text screening, not network moderation.
/// Never called for private messages or transaction payloads.
enum PublicChatSafety {
    static let rules = "No threats, targeted harassment, hateful or sexually explicit content, scams, or repeated spam. Never post recovery keys or other people's private information. Report concerning posts to support@koajent.com."
    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return folded.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func contentReason(_ text: String) -> String? {
        let padded = " " + normalized(text) + " "
        // Whole phrases avoid accidental matches inside ordinary words.
        let phrases = ["kill yourself", "i will kill you", "i am going to kill you", "you should kill yourself", "i will rape you", "send nudes", "suck my dick"]
        if phrases.contains(where: { padded.contains(" " + $0 + " ") }) {
            return "Potentially abusive or sexually explicit public text"
        }
        return nil
    }
    static func outgoingReason(text: String, name: String, history: [(text: String, time: TimeInterval)], now: TimeInterval) -> String? {
        if let reason = contentReason(text) ?? contentReason(name) { return reason + ". Edit it before posting." }
        let recent = history.filter { now >= $0.time && now - $0.time < 60 }
        if recent.count >= 5 { return "Public posting limit reached: five messages per minute. Please wait." }
        if recent.contains(where: { normalized($0.text) == normalized(text) }) { return "This repeats a public message sent in the last minute. Please wait or change it." }
        return nil
    }
}

/// Evaluated in verified relay order; per-sender suppression never hides other users.
struct PublicChatScreening {
    private var recent: [String: [(text: String, date: Date)]] = [:]
    mutating func reason(sender: String, name: String, text: String, date: Date, screenSpam: Bool = true) -> String? {
        if let reason = PublicChatSafety.contentReason(name) ?? PublicChatSafety.contentReason(text) { return reason }
        guard screenSpam else { return nil }
        let key = PublicChatSafety.normalized(text)
        var window = (recent[sender] ?? []).filter { abs(date.timeIntervalSince($0.date)) < 60 }
        let duplicate = window.contains { $0.text == key }
        let flood = window.count >= 5
        window.append((key, date))
        recent[sender] = Array(window.suffix(6))
        if duplicate { return "Repeated public message" }
        if flood { return "High-frequency public posting" }
        return nil
    }
}
