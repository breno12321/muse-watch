import Foundation
import CryptoKit

/// Bounded assembly for the immediate Watch audio path. Partial audio is never submitted.
public struct VoiceChunkAssembly: Sendable {
    public static let chunkBytes = 24 * 1024
    public let request: RelayRequest
    public let totalBytes: Int
    private var data = Data()
    public init(request: RelayRequest, totalBytes: Int) throws {
        try request.validate()
        guard request.audioSHA256 != nil, totalBytes > 0, totalBytes <= 2 * 1024 * 1024 else { throw RelayError.invalid }
        self.request = request; self.totalBytes = totalBytes
    }
    public mutating func append(index: Int, chunk: Data) throws -> Data? {
        let count = (totalBytes + Self.chunkBytes - 1) / Self.chunkBytes
        guard index >= 0, index < count else { throw RelayError.invalid }
        let offset = index * Self.chunkBytes
        guard chunk.count == min(Self.chunkBytes, totalBytes - offset), offset <= data.count else { throw RelayError.invalid }
        if offset < data.count {
            guard offset + chunk.count <= data.count, data.subdata(in: offset..<(offset + chunk.count)) == chunk else { throw RelayError.duplicate }
        } else { data.append(chunk) }
        guard data.count == totalBytes else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == request.audioSHA256 else { throw RelayError.invalid }
        return data
    }
}

public enum Delivery: String, Codable, Sendable {
    case queued, received, connecting, sending, accepted, complete, uncertain, replyUnavailable, failed
    public var label: String {
        switch self {
        case .queued: "Waiting for iPhone"
        case .received: "On iPhone"
        case .connecting: "Connecting to Muse"
        case .sending: "Sending to Muse"
        case .accepted: "Sent · waiting for Muse"
        case .complete: "Sent"
        case .uncertain: "Delivery uncertain · not resent"
        case .replyUnavailable: "Sent · open Muse for reply"
        case .failed: "Not sent"
        }
    }
    public var terminal: Bool { [.complete, .uncertain, .replyUnavailable, .failed].contains(self) }
}
public struct RelayRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let account: String
    public let chatID: UUID
    public let text: String
    public let audioSHA256: String?
    public let duration: Double?
    public let createdAt: Date
    public let newChat: RelayChat?
    public init(id: UUID = UUID(), account: String, chatID: UUID, text: String, audioSHA256: String? = nil, duration: Double? = nil, createdAt: Date = .now, newChat: RelayChat? = nil) {
        self.id = id; self.account = account; self.chatID = chatID; self.text = text
        self.audioSHA256 = audioSHA256; self.duration = duration; self.createdAt = createdAt
        self.newChat = newChat
    }
    public func validate() throws {
        guard !account.isEmpty, account.utf8.count < 512, text.utf8.count <= 16384,
              createdAt.timeIntervalSinceNow < 300,
              (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || audioSHA256 != nil) else { throw RelayError.invalid }
        if let hash = audioSHA256 {
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }), let duration, duration.isFinite, duration >= 0.3, duration <= 61 else { throw RelayError.invalid }
        } else if duration != nil { throw RelayError.invalid }
        if let chat = newChat {
            guard chat.id == chatID, !chat.exists, chat.serverTitle == nil, chat.customTitle == nil, chat.nameRevision == nil,
                  !chat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  chat.title.utf8.count <= 80, !chat.symbol.isEmpty, chat.symbol.utf8.count <= 80 else { throw RelayError.invalid }
        }
    }
    /// First messages can introduce a Watch-created chat, but never replace an existing session.
    public func chatToInsert(in chats: [RelayChat]) throws -> RelayChat? {
        try validate()
        if chats.contains(where: { $0.id == chatID }) { return nil }
        guard let newChat else { throw RelayError.invalid }
        return newChat
    }
}
public enum RelayError: LocalizedError {
    case invalid, duplicate, full
    public var errorDescription: String? {
        switch self { case .invalid: "This Watch request is invalid."; case .duplicate: "This request identifier was already used."; case .full: "The outbox is full. Open Muse on iPhone to finish sending." }
    }
}
public struct RelayChat: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var symbol: String
    public var exists: Bool
    public var serverTitle: String?
    public var customTitle: String?
    public var nameRevision: Int?
    public var displayTitle: String { customTitle ?? serverTitle ?? title }
    /// Exact title/symbol pairs seeded by the original prototype, not Muse account sections.
    public var isLegacyStarter: Bool {
        guard customTitle == nil, serverTitle == nil else { return false }
        return ["Check-in": "sparkles", "Ideas": "lightbulb", "Goals": "checkmark.circle"][title] == symbol
    }
    public init(id: UUID = UUID(), title: String, symbol: String, exists: Bool = false) { self.id = id; self.title = title; self.symbol = symbol; self.exists = exists }
    public mutating func rename(_ name: String?) throws {
        guard (nameRevision ?? 0) >= 0, (nameRevision ?? 0) < Int.max else { throw RelayError.invalid }
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleaned {
            guard !cleaned.isEmpty, cleaned.count <= 80, !cleaned.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw RelayError.invalid }
        }
        customTitle = cleaned
        nameRevision = (nameRevision ?? 0) + 1
    }
    public static func fresh(in chats: [RelayChat]) -> RelayChat {
        let titles = Set(chats.map(\.title))
        var number = 1
        while titles.contains("Chat \(number)") { number += 1 }
        return RelayChat(title: "Chat \(number)", symbol: "bubble.left.and.bubble.right")
    }
}
/// Watch name edits are metadata only: they never become a user message or a Muse API request.
public struct ChatRename: Codable, Equatable, Sendable {
    public let account: String
    public let chatID: UUID
    public let title: String
    public let revision: Int
    public let newChat: RelayChat?
    public init(account: String, chatID: UUID, title: String, revision: Int, newChat: RelayChat? = nil) {
        self.account = account; self.chatID = chatID; self.title = title; self.revision = revision; self.newChat = newChat
    }
    public func validate() throws {
        guard !account.isEmpty, account.utf8.count < 512, revision > 0, revision < Int.max else { throw RelayError.invalid }
        var validation = RelayChat(title: "Chat", symbol: "bubble")
        try validation.rename(title)
        guard validation.customTitle == title else { throw RelayError.invalid }
        if let chat = newChat {
            guard chat.id == chatID, !chat.exists, chat.serverTitle == nil, chat.customTitle == nil, chat.nameRevision == nil,
                  !chat.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, chat.title.utf8.count <= 80,
                  !chat.symbol.isEmpty, chat.symbol.utf8.count <= 80 else { throw RelayError.invalid }
        }
    }
    @discardableResult public func apply(to chats: inout [RelayChat], account expectedAccount: String) throws -> Bool {
        try validate()
        guard account == expectedAccount else { throw RelayError.invalid }
        let index = chats.firstIndex { $0.id == chatID }
        guard var chat = index.map({ chats[$0] }) ?? newChat else { throw RelayError.invalid }
        // Duplicated/superseded transfers cannot overwrite newer edits. Concurrent phone edits win ties.
        guard revision > (chat.nameRevision ?? 0) else { return false }
        try chat.rename(title); chat.nameRevision = revision
        if let index { chats[index] = chat } else { chats.append(chat) }
        return true
    }
}
public struct RelayMessage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var requestID: UUID?
    public var chatID: UUID
    public var role: String
    public var text: String
    public var date: Date
    public var duration: Double?
    public var delivery: Delivery?
    public var detail: String?
    public var replyAudio: ReplyAudio?
    public var replyAudioState: ReplyAudioState?
    public init(id: String, requestID: UUID? = nil, chatID: UUID, role: String, text: String, date: Date = .now, duration: Double? = nil, delivery: Delivery? = nil, detail: String? = nil) {
        self.id = id; self.requestID = requestID; self.chatID = chatID; self.role = role; self.text = text; self.date = date; self.duration = duration; self.delivery = delivery; self.detail = detail
    }
}
public struct RelaySnapshot: Codable, Sendable {
    public var version = 1
    public var account: String
    public var revision: Int
    public var paired: Bool
    public var status: String
    public var museName: String
    public var personName: String
    public var avatarRevision: String?
    public var chats: [RelayChat]
    public var messages: [RelayMessage]
    public var updatedAt: Date
    public func contextData() throws -> Data {
        var compact = self
        compact.messages = Array(messages.suffix(80))
        for i in compact.messages.indices { compact.messages[i].text = String(compact.messages[i].text.prefix(8000)) }
        var data = try JSONEncoder().encode(compact)
        while data.count > 55000, compact.messages.count > 1 {
            compact.messages.removeFirst(); data = try JSONEncoder().encode(compact)
        }
        guard data.count <= 55000 else { throw RelayError.invalid }; return data
    }
}
public struct JournalEntry: Codable, Sendable, Identifiable {
    public var request: RelayRequest
    public var delivery: Delivery
    public var acceptedID: String?
    public var detail: String?
    public var recoveryStopped: Bool?
    public var transcript: String?
    public var transcriptionBlocked: Bool?
    public var voiceReply: Bool?
    public var askForVoiceNote: Bool?
    public var id: UUID { request.id }
    public var canRecoverReply: Bool { delivery == .replyUnavailable && acceptedID != nil && recoveryStopped != true }
    public var canPrepare: Bool { delivery == .received && acceptedID == nil && transcriptionBlocked != true }
    public static let voiceNoteInstruction = "If possible, also append a voice note reply. Always include your reply as text."
    public func outgoingText(includeVoiceRequest: Bool = false) throws -> String {
        // A voice caption is never a substitute for a completed transcription.
        let base = (request.audioSHA256 == nil ? request.text : transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw RelayError.invalid }
        let value = includeVoiceRequest && askForVoiceNote == true ? base + "\n\n" + Self.voiceNoteInstruction : base
        guard value.utf8.count <= 16384 else { throw RelayError.invalid }
        return value
    }
}
public struct RelayJournal: Codable, Sendable {
    public var entries: [JournalEntry] = []
    public init() {}
    @discardableResult public mutating func receive(_ request: RelayRequest) throws -> Bool {
        try request.validate()
        if let old = entries.first(where: { $0.id == request.id }) {
            guard old.request == request else { throw RelayError.duplicate }; return false
        }
        guard entries.filter({ !$0.delivery.terminal }).count < 30, entries.count < 10000 else { throw RelayError.full }
        entries.append(JournalEntry(request: request, delivery: .received)); return true
    }
    public mutating func recoverInterrupted() {
        for i in entries.indices where [.sending, .accepted].contains(entries[i].delivery) {
            entries[i].delivery = entries[i].acceptedID == nil ? .uncertain : .replyUnavailable
            entries[i].detail = "The connection ended after submission. Check the conversation in Muse. This message will not be resent."
        }
        for i in entries.indices where entries[i].delivery == .uncertain && entries[i].acceptedID != nil { entries[i].delivery = .replyUnavailable }
        for i in entries.indices where entries[i].delivery == .connecting { entries[i].delivery = entries[i].acceptedID == nil ? .received : .replyUnavailable }
        for i in entries.indices where entries[i].delivery == .received && entries[i].acceptedID == nil && entries[i].voiceReply == nil { entries[i].voiceReply = false }
    }
    public mutating func stopReplyRecovery(_ id: UUID, detail: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].acceptedID != nil else { return }
        entries[index].recoveryStopped = true; entries[index].delivery = .replyUnavailable; entries[index].detail = detail
    }
    public mutating func saveTranscript(_ text: String, for id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].acceptedID == nil,
              [.received, .connecting].contains(entries[index].delivery), entries[index].request.audioSHA256 != nil else { throw RelayError.invalid }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 16384 else { throw RelayError.invalid }
        entries[index].transcript = value; entries[index].transcriptionBlocked = nil
    }
    public mutating func retryTranscriptions() {
        for index in entries.indices where entries[index].delivery == .received && entries[index].acceptedID == nil {
            entries[index].transcriptionBlocked = nil
        }
    }
}
