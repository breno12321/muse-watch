import XCTest
@testable import MuseCore

final class ReplyAudioTests: XCTestCase {
    private let mp3 = Data([0x49, 0x44, 0x33, 4] + Array(repeating: UInt8(0), count: 60))
    func testSpeechResponseWaitsForCompletionAndKeepsAByteBudget() throws {
        var response = ReplyAudioResponse()
        XCTAssertNil(try response.append(status: 200, data: mp3.prefix(2), ended: false))
        XCTAssertEqual(try response.append(status: 0, data: mp3.dropFirst(2), ended: true), mp3)
        var oversized = ReplyAudioResponse()
        XCTAssertThrowsError(try oversized.append(status: 200, data: Data(repeating: 0, count: ReplyAudio.maximumBytes + 1), ended: false))
        var invalid = ReplyAudioResponse()
        XCTAssertThrowsError(try invalid.append(status: 200, data: Data("<html>not audio</html>".utf8), ended: true))
    }
    func testTTS404IsAnIndependentFailureAndPathsEscapeTheWholeMessageID() throws {
        var response = ReplyAudioResponse()
        XCTAssertThrowsError(try response.append(status: 404, data: Data(), ended: false)) { error in
            guard case ReplyAudioError.http(404) = error else { return XCTFail("Expected an audio-only 404") }
        }
        let paths = try ReplyAudio.paths(messageID: "reply/one?x=1&two+")
        XCTAssertEqual(paths, ["/api/voice/tts-stream?message_id=reply%2Fone%3Fx%3D1%26two%2B", "/voice/tts-stream?message_id=reply%2Fone%3Fx%3D1%26two%2B"])
        XCTAssertThrowsError(try ReplyAudio.paths(messageID: ""))
    }
    func testTTSUsesGETWithoutChangingNormalPostRequests() throws {
        let transport = NoiseTransport(send: NoiseCipher(), receive: NoiseCipher())
        func method(_ frame: Data) throws -> String {
            let payload = try XCTUnwrap(Proto.decode(frame).first { $0.number == 4 }?.bytes)
            let service = try XCTUnwrap(Proto.decode(payload).first { $0.number == 2 }?.bytes)
            let request = try XCTUnwrap(Proto.decode(service).first { $0.number == 2 }?.bytes)
            let verb = try XCTUnwrap(Proto.decode(request).first { $0.number == 1 }?.bytes)
            return try XCTUnwrap(String(data: verb, encoding: .utf8))
        }
        XCTAssertEqual(try method(transport.request(path: "/api/voice/tts-stream", method: "GET").frames[0]), "GET")
        XCTAssertEqual(try method(transport.request(path: "/chat/stream").frames[0]), "POST")
    }
    func testAudioTransferRejectsChangedBytesAndInvalidPlaybackDuration() throws {
        let audio = try ReplyAudio(data: mp3, duration: 2.5)
        let asset = ReplyAudioTransfer(account: "synthetic-account", chatID: UUID(), messageID: "reply", audio: audio)
        try asset.validate(mp3)
        var tampered = mp3; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try asset.validate(tampered))
        XCTAssertThrowsError(try ReplyAudio(data: mp3, duration: .nan))
        XCTAssertThrowsError(try ReplyAudio(data: mp3, duration: 0))
        XCTAssertEqual(audio.filename, "reply-\(audio.id.uuidString).mp3")
        XCTAssertFalse(audio.filename.contains("/"))
    }
    func testTopicMetadataRequiresItsOwnChatAndNeverUsesAMessageTitle() {
        let id = UUID().uuidString
        let own: [String: Any] = ["type": "event", "event": "thread.updated", "payload": ["session_id": id.lowercased(), "title": "Audio file to transcribe"]]
        XCTAssertEqual(ThreadTopic.extract(own, sessionID: id), "Audio file to transcribe")
        XCTAssertNil(ThreadTopic.extract(own, sessionID: UUID().uuidString))
        XCTAssertNil(ThreadTopic.extract(["event": "delta.message_done", "payload": ["session_id": id, "title": "A file attachment"]], sessionID: id))
        XCTAssertNil(ThreadTopic.extract(["title": "No chat scope"], sessionID: id))
        XCTAssertEqual(ThreadTopic.extract(["result": ["session_id": id, "thread_title": " Topic \u{0} "]], sessionID: id), "Topic")
    }
    func testUserChatNameOverridesLaterServerTopicsAndCanBeReset() throws {
        var chat = RelayChat(title: "Chat 1", symbol: "bubble")
        chat.serverTitle = "Muse topic"
        try chat.rename("  My notes  ")
        chat.serverTitle = "A new server topic"
        XCTAssertEqual(chat.displayTitle, "My notes")
        let restored = try JSONDecoder().decode(RelayChat.self, from: JSONEncoder().encode(chat))
        XCTAssertEqual(restored.displayTitle, "My notes")
        XCTAssertThrowsError(try chat.rename("\n"))
        XCTAssertThrowsError(try chat.rename("Bad\nname"))
        XCTAssertThrowsError(try chat.rename(String(repeating: "a", count: 81)))
        XCTAssertEqual(chat.displayTitle, "My notes")
        try chat.rename(nil)
        XCTAssertEqual(chat.displayTitle, "A new server topic")
    }
    func testLegacyChatAndMessageDecodeWithoutAudioOrTitleOverrides() throws {
        let chat = RelayChat(title: "Muse", symbol: "bubble")
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as! [String: Any]
        raw.removeValue(forKey: "serverTitle"); raw.removeValue(forKey: "customTitle")
        let restored = try JSONDecoder().decode(RelayChat.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertEqual(restored.displayTitle, "Muse")
        let message = RelayMessage(id: "existing-reply", chatID: chat.id, role: "muse", text: "Existing Markdown")
        let older = try JSONDecoder().decode(RelayMessage.self, from: JSONEncoder().encode(message))
        XCTAssertNil(older.replyAudio); XCTAssertNil(older.replyAudioState)
        XCTAssertEqual(older.text, message.text)
    }
}
