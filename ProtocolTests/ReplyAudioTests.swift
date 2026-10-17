import XCTest
@testable import MuseCore

final class ReplyAudioTests: XCTestCase {
    func testPresentationMediaPathIsRestrictedToWorkspaceAudioAndEscapesLiteralNames() throws {
        func reference(_ path: String) throws -> MuseAudioPresentation {
            try MuseAudioPresentation(payload: ["kind": "audio", "data": ["audio": ["path": path, "mime": "audio/mpeg"]]])
        }
        XCTAssertEqual(try reference("sandbox://workspace/voice notes/hello.mp3").fetchPath(), "/workspace/voice%20notes/hello.mp3")
        XCTAssertEqual(try reference("/workspace/audio/hello.mp3").fetchPath(), "/workspace/audio/hello.mp3")
        for path in ["/api/admin.mp3", "https://example.invalid/file.mp3", "//workspace/file.mp3", "workspace/../file.mp3", "workspace/%2e%2e/file.mp3", "workspace/%252e%252e/file.mp3", "workspace/%2fetc/file.mp3", "workspace/a\\b/file.mp3", "workspace/file.html"] {
            XCTAssertThrowsError(try reference(path).fetchPath(), path)
        }
    }
    func testDownloadedVoiceCardsPreserveSupportedFormatsAndLegacyMP3Archives() throws {
        let mp3 = Data([0x49, 0x44, 0x33, 4, 0, 0])
        let wav = Data("RIFF0000WAVE0000".utf8)
        let m4a = Data([0, 0, 0, 16] + Array("ftypM4A 0000".utf8))
        for (data, ext) in [(mp3, "mp3"), (wav, "wav"), (m4a, "m4a")] {
            let audio = try ReplyAudio(data: data, duration: 1)
            XCTAssertEqual(audio.fileExtension, ext)
            XCTAssertTrue(audio.filename.hasSuffix("." + ext))
            XCTAssertNoThrow(try audio.validate(data))
            var response = ReplyAudioResponse(allowContainers: true)
            XCTAssertEqual(try response.append(status: 200, data: data, ended: true), data)
        }
        let audio = try ReplyAudio(data: mp3, duration: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(audio)) as? [String: Any])
        object.removeValue(forKey: "format")
        let legacy = try JSONDecoder().decode(ReplyAudio.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNoThrow(try legacy.validate(mp3))
        XCTAssertEqual(legacy.fileExtension, "mp3")
        object["format"] = "../../synthetic"
        let invalid = try JSONDecoder().decode(ReplyAudio.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(invalid.filename.hasSuffix(".mp3"))
        XCTAssertThrowsError(try invalid.validate(mp3))
    }
    func testSeparateAudioCardUsesTheSameTurnScopeAndDoesNotOverwriteText() throws {
        let turn = try TurnAccumulator(resumingSessionID: "synthetic-chat", acceptedMessageID: "synthetic-user")
        func card(_ id: String, parent: String = "synthetic-user", session: String = "synthetic-chat", kind: String = "audio") -> [String: Any] {
            ["type": "event", "event": "delta.presentation", "payload": ["session_id": session, "message_id": id, "reply_to_message_id": parent, "kind": kind, "data": ["audio": ["path": "synthetic.mp3", "mime": "audio/mpeg"]]]]
        }
        let text: [String: Any] = ["type": "event", "event": "delta.message_done", "payload": ["session_id": "synthetic-chat", "message_id": "text-reply", "reply_to_message_id": "synthetic-user", "display_text": "Hello."]]
        XCTAssertEqual(try turn.feed(text).first?.text, "Hello.")
        XCTAssertTrue(try turn.feed(card("text-reply")).isEmpty)
        XCTAssertTrue(turn.acceptsAudioPresentation(card("text-reply")))
        let separate = card("audio-reply", parent: "text-reply")
        XCTAssertEqual(try turn.feed(separate).first?.text, "Voice note")
        XCTAssertTrue(turn.acceptsAudioPresentation(separate))
        XCTAssertTrue(try turn.feed(card("foreign", parent: "unrelated-user")).isEmpty)
        XCTAssertFalse(turn.acceptsAudioPresentation(card("text-reply", parent: "unrelated-user")))
        XCTAssertFalse(turn.acceptsAudioPresentation(card("text-reply", session: "other-chat")))
        XCTAssertTrue(try turn.feed(card("image", kind: "image")).isEmpty)
        XCTAssertFalse(turn.acceptsAudioPresentation(card("text-reply", kind: "image")))
        let early = TurnAccumulator(sessionID: "synthetic-chat")
        XCTAssertTrue(try early.feed(separate).isEmpty)
        let ack: [String: Any] = ["session_id": "synthetic-chat", "message_id": "synthetic-user", "is_thread": true]
        // A card parented directly to the accepted user can arrive before acknowledgement.
        let directCard = card("early-audio")
        let beforeAck = TurnAccumulator(sessionID: "synthetic-chat")
        XCTAssertTrue(try beforeAck.feed(directCard).isEmpty)
        XCTAssertEqual(try beforeAck.acknowledge(ack).first?.text, "Voice note")
        XCTAssertTrue(beforeAck.acceptsAudioPresentation(directCard))
    }
    func testAudioPresentationKeepsBoundedSourceMetadataForPrivatePhoneRetries() throws {
        let payload: [String: Any] = ["kind": "audio", "data": ["audio": ["path": "/tmp/synthetic-voice.mp3", "mime": "audio/mpeg", "byte_len": 64, "variants": ["original": "synthetic-original.mp3"]]], "resources": ["files": [["path": "/tmp/synthetic-voice.mp3", "url": "https://media.example.invalid/synthetic.mp3"]]]]
        let reference = try MuseAudioPresentation(payload: payload)
        let restored = try JSONDecoder().decode(MuseAudioPresentation.self, from: JSONEncoder().encode(reference))
        XCTAssertEqual(restored, reference)
        XCTAssertEqual(restored.pathKind, "absolute path")
        XCTAssertNotNil(restored.resources)
        XCTAssertEqual(restored.mime, "audio/mpeg")
        XCTAssertNoThrow(try restored.validate())
        let audio = try XCTUnwrap(JSONSerialization.jsonObject(with: restored.audioMetadata) as? [String: Any])
        XCTAssertNotNil(audio["variants"])
        var denied = restored; denied.accessDenied = true
        XCTAssertEqual(try JSONDecoder().decode(MuseAudioPresentation.self, from: JSONEncoder().encode(denied)).accessDenied, true)
        for value in ["text/html", "video/mp4", "application/json"] {
            XCTAssertThrowsError(try MuseAudioPresentation(payload: ["kind": "audio", "data": ["audio": ["path": "synthetic", "mime": value]]]).validate())
        }
        XCTAssertThrowsError(try MuseAudioPresentation(payload: ["kind": "audio", "data": ["audio": ["path": "synthetic.mp3", "mime": "audio/mpeg", "missing": true]]]).validate())
        XCTAssertThrowsError(try MuseAudioPresentation(payload: ["kind": "audio", "data": ["audio": ["path": "synthetic.mp3", "mime": "audio/mpeg", "byte_len": ReplyAudio.maximumBytes + 1]]]).validate())
    }
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
