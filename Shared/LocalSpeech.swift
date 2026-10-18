import Foundation
import CryptoKit

/// A request identifies saved text, never a prompt to send to Muse.
public struct LocalSpeechRequest: Codable, Equatable, Sendable {
    public static let currentVersion = "kokoro-en-heart-v1"
    public let id: UUID
    public let account: String
    public let chatID: UUID
    public let messageID: String
    public let textHash: String
    public let revision: Int
    public let version: String
    public let createdAt: Date
    public init(id: UUID = UUID(), account: String, chatID: UUID, messageID: String, textHash: String, revision: Int) {
        self.id = id; self.account = account; self.chatID = chatID; self.messageID = messageID
        self.textHash = textHash; self.revision = revision; version = Self.currentVersion; createdAt = .now
    }
    public static func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public var cacheKey: String {
        // JSON array framing avoids ambiguous concatenation; retries share the same cache.
        Self.hash(String(data: try! JSONEncoder().encode([account, chatID.uuidString, messageID, textHash, version]), encoding: .utf8)!)
    }
    public func validate() throws {
        guard !account.isEmpty, account.utf8.count < 512, !messageID.isEmpty, messageID.utf8.count <= 512,
              revision > 0, revision < Int.max, version == Self.currentVersion,
              textHash.count == 64, textHash.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw RelayError.invalid }
    }
    public func matches(_ message: RelayMessage, account: String) -> Bool {
        self.account == account && chatID == message.chatID && messageID == message.id && message.role == "muse"
            && message.replyComplete == true && textHash == Self.hash(message.text)
    }
}

public struct LocalSpeechStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case queued, generating, paused, ready, failed }
    public let request: LocalSpeechRequest
    public var phase: Phase
    public var audio: ReplyAudio?
    public var detail: String?
    public var retryable: Bool
    public var updatedAt: Date
    public init(request: LocalSpeechRequest, phase: Phase = .queued, audio: ReplyAudio? = nil, detail: String? = nil, retryable: Bool = true, updatedAt: Date = .now) {
        self.request = request; self.phase = phase; self.audio = audio; self.detail = detail; self.retryable = retryable; self.updatedAt = updatedAt
    }
    public var pending: Bool { phase == .queued || phase == .generating }
}
