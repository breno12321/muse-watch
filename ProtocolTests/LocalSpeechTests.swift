import XCTest
@testable import MuseCore

final class LocalSpeechTests: XCTestCase {
    func testScopeCompletionAndChangedText() throws {
        var message = RelayMessage(id: "reply", chatID: UUID(), role: "muse", text: "Hello.")
        let request = LocalSpeechRequest(account: "synthetic", chatID: message.chatID, messageID: message.id, textHash: LocalSpeechRequest.hash(message.text), revision: 1)
        try request.validate()
        XCTAssertFalse(request.matches(message, account: "synthetic"))
        message.replyComplete = true
        XCTAssertTrue(request.matches(message, account: "synthetic"))
        XCTAssertFalse(request.matches(message, account: "other"))
        message.text = "Changed."
        XCTAssertFalse(request.matches(message, account: "synthetic"))
    }
    func testRetryCacheIdentityAndLegacyArchive() throws {
        let chat = UUID(), hash = LocalSpeechRequest.hash("Hello")
        let first = LocalSpeechRequest(account: "a", chatID: chat, messageID: "m", textHash: hash, revision: 1)
        let retry = LocalSpeechRequest(account: "a", chatID: chat, messageID: "m", textHash: hash, revision: 2)
        XCTAssertNotEqual(first.id, retry.id); XCTAssertEqual(first.cacheKey, retry.cacheKey)
        XCTAssertNotEqual(first.cacheKey, LocalSpeechRequest(account: "b", chatID: chat, messageID: "m", textHash: hash, revision: 1).cacheKey)
        let message = RelayMessage(id: "m", chatID: chat, role: "muse", text: "Hello")
        let decoded = try JSONDecoder().decode(RelayMessage.self, from: JSONEncoder().encode(message))
        XCTAssertNil(decoded.localSpeech); XCTAssertNil(decoded.replyComplete)
    }
    func testCompactSnapshotKeepsOriginalTextIdentity() throws {
        let chat = RelayChat(id: UUID(), title: "Synthetic", symbol: "bubble")
        var message = RelayMessage(id: "m", chatID: chat.id, role: "muse", text: String(repeating: "English words. ", count: 900))
        message.replyComplete = true
        let snapshot = RelaySnapshot(account: "a", revision: 1, paired: true, status: "Ready", museName: "Muse", personName: "You", chats: [chat], messages: [message], updatedAt: .now)
        let compact = try JSONDecoder().decode(RelaySnapshot.self, from: snapshot.contextData())
        XCTAssertEqual(compact.messages[0].text.count, 8000)
        XCTAssertEqual(compact.messages[0].speechTextHash, LocalSpeechRequest.hash(message.text))
    }
    func testTransferProvenanceAndChecksum() throws {
        var data = Data([0, 0, 0, 20]); data.append(Data("ftypM4A ".utf8))
        let audio = try ReplyAudio(data: data, duration: 2)
        let request = LocalSpeechRequest(account: "a", chatID: UUID(), messageID: "m", textHash: LocalSpeechRequest.hash("Hello"), revision: 1)
        let valid = ReplyAudioTransfer(account: "a", chatID: request.chatID, messageID: "m", audio: audio, speechRequest: request)
        try valid.validate(data)
        XCTAssertThrowsError(try valid.validate(data + Data([0])))
        XCTAssertThrowsError(try ReplyAudioTransfer(account: "b", chatID: request.chatID, messageID: "m", audio: audio, speechRequest: request).validate(data))
    }
}
