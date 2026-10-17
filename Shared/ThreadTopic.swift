import Foundation

/// Optional, scoped server metadata. Never invent an undocumented title-fetch endpoint.
public enum ThreadTopic {
    public static func extract(_ object: [String: Any], sessionID: String) -> String? {
        let value = object["result"] as? [String: Any] ?? object["payload"] as? [String: Any] ?? object
        guard let scope = value["session_id"] as? String ?? object["session_id"] as? String,
              scope == sessionID || (UUID(uuidString: scope) != nil && UUID(uuidString: scope) == UUID(uuidString: sessionID)) else { return nil }
        let event = object["event"] as? String
        let metadataEvent = event == nil || ["thread.", "chat.", "session."].contains { event!.hasPrefix($0) }
        let candidates = [value["thread_title"], value["session_title"], value["thread_topic"]] + (metadataEvent ? [value["title"], value["topic"]] : [])
        for candidate in candidates {
            guard let title = candidate as? String, title.utf8.count <= 1024 else { continue }
            let clean = title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty { return String(clean.prefix(80)) }
        }
        return nil
    }
}
