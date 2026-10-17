// Reply correlation adapted from muse-gadget-sdk/muse_turn.py (Apache-2.0).
import Foundation

public final class TurnAccumulator {
    public struct Reply: Equatable, Sendable { public let id: String; public var text: String; public var done: Bool }
    public let sessionID: String
    public private(set) var acknowledgedID: String?
    private var userIDs = Set<String>()
    private var pending: [[String: Any]] = []
    private var pendingBytes = 0
    private var replies: [String: Reply] = [:]
    private var retired: Set<String>
    private var sequences = Set<String>()
    public init(sessionID: String, retiredMessageIDs: Set<String> = []) { self.sessionID = sessionID; retired = retiredMessageIDs }
    /// Restore a server acknowledgement saved in the account-bound phone journal.
    /// This only listens again; it never submits the user message a second time.
    public convenience init(resumingSessionID: String, acceptedMessageID: String) throws {
        guard !resumingSessionID.isEmpty, resumingSessionID.utf8.count <= 512, !acceptedMessageID.isEmpty, acceptedMessageID.utf8.count <= 512 else { throw MuseError.invalid("Saved reply scope is invalid.") }
        self.init(sessionID: resumingSessionID)
        acknowledgedID = acceptedMessageID; userIDs.insert(acceptedMessageID)
    }
    public var replyIDs: Set<String> { Set(replies.keys) }
    public var allRepliesComplete: Bool { !replies.isEmpty && replies.values.allSatisfy(\.done) }
    public func acknowledge(_ object: [String: Any]) throws -> [Reply] {
        let ack = object["result"] as? [String: Any] ?? object
        guard let acknowledgedSession = ack["session_id"] as? String, matchesSession(acknowledgedSession) else { throw MuseError.invalid("Muse acknowledged a different chat identifier.") }
        guard ack["is_thread"] as? Bool == true else { throw MuseError.invalid("Muse did not acknowledge a dedicated side chat.") }
        guard let id = nonempty(ack["message_id"]) ?? nonempty(ack["reply_to_message_id"]), !id.isEmpty, id.utf8.count <= 512 else { throw MuseError.invalid("Muse acknowledgement omitted an accepted message identifier.") }
        acknowledgedID = id; userIDs.insert(id)
        if let parent = nonempty(ack["reply_to_message_id"]) { userIDs.insert(parent) }
        let held = pending; pending = []; pendingBytes = 0
        return try held.flatMap { try feed($0) }
    }
    public func feed(_ event: [String: Any]) throws -> [Reply] {
        guard event["type"] as? String == "event", let payload = event["payload"] as? [String: Any],
              let eventSession = nonempty(payload["session_id"]) ?? nonempty(event["session_id"]), matchesSession(eventSession) else { return [] }
        if acknowledgedID == nil {
            pendingBytes += try jsonData(event).count
            guard pending.count < 64, pendingBytes <= 65536 else { throw MuseError.invalid("Too many events arrived before Muse acknowledged the message.") }
            pending.append(event); return []
        }
        guard let name = event["event"] as? String,
              ["delta.message_start", "delta.text_append", "delta.message_done", "message.assistant"].contains(name),
              payload["role"] as? String != "user",
              let id = nonempty(payload["message_id"]) ?? nonempty(event["message_id"]) ?? nonempty(payload["id"]),
              !id.isEmpty, id.utf8.count <= 512, !retired.contains(id) else { return [] }
        if let parent = nonempty(payload["reply_to_message_id"]) ?? nonempty(payload["parent_message_id"]),
           !userIDs.contains(parent), replies[parent] == nil, parent != id { return [] }
        // The sequence number is scoped to this subscription, never inferred from text.
        if let seq = event["seq"] as? NSNumber {
            guard sequences.count < 16384 else { throw MuseError.invalid("Too many reply events.") }
            let key = "\(seq):\(id):\(name)"; guard sequences.insert(key).inserted else { return [] }
        }
        guard replies[id] != nil || replies.count < 32 else { throw MuseError.invalid("Too many assistant messages.") }
        var reply = replies[id] ?? Reply(id: id, text: "", done: false)
        if name == "delta.text_append", !reply.done, let text = payload["text"] as? String { reply.text += clean(text) }
        if name == "delta.message_done" || name == "message.assistant" {
            let final = payload["display_text"] as? String ?? payload["transcript"] as? String ?? transcript(payload["transcript"], id: id) ?? payload["content"] as? String
            if let final { reply.text = clean(final) }
            if name == "delta.message_done" || payload["display_text_ready"] as? Bool != false { reply.done = true }
        }
        guard reply.text.utf8.count <= 65536 else { throw MuseError.invalid("Muse reply exceeds 64 KiB.") }
        if replies[id] == reply { return [] }; replies[id] = reply; return [reply]
    }
    // Python SDK uses `a or b`: empty IDs are absent, not foreign parents.
    private func nonempty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }; return text
    }
    private func clean(_ text: String) -> String { String(text.unicodeScalars.filter { !((0...8).contains($0.value) || (11...12).contains($0.value) || (14...31).contains($0.value) || (127...159).contains($0.value)) }) }
    private func matchesSession(_ other: String) -> Bool {
        if other == sessionID { return true }
        guard let first = UUID(uuidString: sessionID), let second = UUID(uuidString: other) else { return false }
        return first == second
    }
    private func transcript(_ object: Any?, id: String) -> String? {
        guard let transcript = object as? [String: Any], let messages = transcript["messages"] as? [[String: Any]] else { return nil }
        let parts = messages.filter { $0["role"] as? String == "assistant" && $0["id"] as? String == id }.flatMap { message -> [String] in
            if let content = message["content"] as? String { return [content] }
            return (message["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
