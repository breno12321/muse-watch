import Foundation
import CryptoKit

public enum ReplyAudioState: String, Codable, Sendable { case preparing, ready, unavailable }

public struct ReplyAudio: Codable, Equatable, Sendable {
    public static let maximumBytes = 3 * 1024 * 1024
    public let id: UUID
    public let sha256: String
    public let bytes: Int
    public let duration: Double
    public let format: String?
    public let generatedLocally: Bool?
    public var fileExtension: String { if let format, ["wav", "m4a"].contains(format) { return format }; return "mp3" }
    public var filename: String { "\(generatedLocally == true ? "speech" : "reply")-\(id.uuidString).\(fileExtension)" }
    public init(data: Data, duration: Double, generatedLocally: Bool = false) throws {
        self.generatedLocally = generatedLocally ? true : nil
        format = try Self.detectFormat(data)
        guard duration.isFinite, duration > 0, duration <= 1800 else { throw RelayError.invalid }
        id = UUID(); bytes = data.count; self.duration = duration
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func validate(_ data: Data) throws {
        guard try Self.detectFormat(data) == (format ?? "mp3") else { throw RelayError.invalid }
        guard data.count == bytes, duration.isFinite, duration > 0, duration <= 1800,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else { throw RelayError.invalid }
    }
    public static func validateMP3(_ data: Data) throws {
        guard data.count >= 4, data.count <= maximumBytes else { throw RelayError.invalid }
        let head = [UInt8](data.prefix(3))
        let id3 = head == [0x49, 0x44, 0x33]
        let frame = head[0] == 0xff && head[1] & 0xe0 == 0xe0 && head[1] & 0x18 != 0x08 && head[1] & 0x06 != 0
        guard id3 || frame else { throw RelayError.invalid }
    }
    public static func detectFormat(_ data: Data) throws -> String {
        guard data.count >= 4, data.count <= maximumBytes else { throw RelayError.invalid }
        if (try? validateMP3(data)) != nil { return "mp3" }
        if data.count >= 12, String(data: data.prefix(4), encoding: .ascii) == "RIFF",
           String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE" { return "wav" }
        if data.count >= 12, String(data: data.dropFirst(4).prefix(4), encoding: .ascii) == "ftyp" { return "m4a" }
        throw RelayError.invalid
    }
    public static func paths(messageID: String) throws -> [String] {
        guard !messageID.isEmpty, messageID.utf8.count <= 512,
              let escaped = messageID.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) else { throw RelayError.invalid }
        return ["/api/voice/tts-stream", "/voice/tts-stream"].map { "\($0)?message_id=\(escaped)" }
    }
}

public struct ReplyAudioTransfer: Codable, Equatable, Sendable {
    public let account: String
    public let chatID: UUID
    public let messageID: String
    public let audio: ReplyAudio
    public let speechRequest: LocalSpeechRequest?
    public init(account: String, chatID: UUID, messageID: String, audio: ReplyAudio, speechRequest: LocalSpeechRequest? = nil) {
        self.account = account; self.chatID = chatID; self.messageID = messageID; self.audio = audio
        self.speechRequest = speechRequest
    }
    public func validate(_ data: Data) throws {
        guard !account.isEmpty, account.utf8.count < 512, !messageID.isEmpty, messageID.utf8.count <= 512 else { throw RelayError.invalid }
        try audio.validate(data)
        if let speechRequest {
            try speechRequest.validate()
            guard speechRequest.account == account, speechRequest.chatID == chatID, speechRequest.messageID == messageID else { throw RelayError.invalid }
        }
    }
}

public struct ReplyAudioRequest: Codable, Equatable, Sendable {
    public let account: String
    public let chatID: UUID
    public let messageID: String
    public init(account: String, chatID: UUID, messageID: String) { self.account = account; self.chatID = chatID; self.messageID = messageID }
    public func validate() throws {
        guard !account.isEmpty, account.utf8.count < 512, !messageID.isEmpty, messageID.utf8.count <= 512 else { throw RelayError.invalid }
    }
}

public enum ReplyAudioError: Error { case http(UInt64), incomplete, tooLarge }
/// Bounded TTS response assembly; an audio error must not fail the chat stream.
public struct ReplyAudioResponse {
    private var status: UInt64 = 0
    private var data = Data()
    private let allowContainers: Bool
    public init(allowContainers: Bool = false) { self.allowContainers = allowContainers }
    public mutating func append(status: UInt64, data chunk: Data, ended: Bool) throws -> Data? {
        if status != 0 { self.status = status }
        if self.status >= 400 { throw ReplyAudioError.http(self.status) }
        guard data.count + chunk.count <= ReplyAudio.maximumBytes else { throw ReplyAudioError.tooLarge }
        data += chunk
        guard ended else { return nil }
        guard (200..<300).contains(self.status) else { throw ReplyAudioError.incomplete }
        if allowContainers { _ = try ReplyAudio.detectFormat(data) }
        else { try ReplyAudio.validateMP3(data) }
        return data
    }
}
