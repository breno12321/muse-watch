import XCTest
import CryptoKit
@testable import MuseCore

final class RelayTests: XCTestCase {
    func testVoiceTranscriptIsDurableAndCannotFallBackToCaptionOrRepostAcceptedTurn() throws {
        let voice = RelayRequest(account: "test", chatID: UUID(), text: "Caption is not the transcript", audioSHA256: String(repeating: "a", count: 64), duration: 2)
        var journal = RelayJournal()
        try journal.receive(voice)
        XCTAssertThrowsError(try journal.entries[0].outgoingText())
        XCTAssertThrowsError(try journal.saveTranscript(" \n ", for: voice.id))
        try journal.saveTranscript("  Please say hello. \n", for: voice.id)
        var saved = try JSONDecoder().decode(RelayJournal.self, from: JSONEncoder().encode(journal))
        XCTAssertEqual(try saved.entries[0].outgoingText(), "Please say hello.")
        XCTAssertFalse(try saved.receive(voice)) // Transcription never mutates the deduplication request.
        saved.entries[0].delivery = .sending
        XCTAssertThrowsError(try saved.saveTranscript("Changed text", for: voice.id))
        saved.recoverInterrupted(); saved.retryTranscriptions()
        XCTAssertEqual(saved.entries[0].delivery, .uncertain)
        XCTAssertFalse(saved.entries[0].canPrepare)
        saved.entries[0].acceptedID = "synthetic-accepted-message"
        saved.recoverInterrupted()
        XCTAssertFalse(saved.entries[0].canPrepare)
        XCTAssertEqual(saved.entries[0].delivery, .replyUnavailable)
    }
    func testBlockedTranscriptionSurvivesRelaunchAndDoesNotBlockTypedRequests() throws {
        let voice = RelayRequest(account: "test", chatID: UUID(), text: "", audioSHA256: String(repeating: "b", count: 64), duration: 2)
        let typed = RelayRequest(account: "test", chatID: UUID(), text: "Typed message")
        var journal = RelayJournal()
        try journal.receive(voice); try journal.receive(typed)
        journal.entries[0].transcriptionBlocked = true
        var restored = try JSONDecoder().decode(RelayJournal.self, from: JSONEncoder().encode(journal))
        restored.recoverInterrupted()
        XCTAssertEqual(restored.entries.first(where: \.canPrepare)?.id, typed.id)
        XCTAssertEqual(try restored.entries[1].outgoingText(), "Typed message")
        restored.retryTranscriptions()
        XCTAssertEqual(restored.entries.first(where: \.canPrepare)?.id, voice.id)
        restored.entries[0].delivery = .connecting
        try restored.saveTranscript("Recognized speech", for: voice.id)
        restored.recoverInterrupted()
        XCTAssertEqual(restored.entries[0].delivery, .received)
        XCTAssertEqual(try restored.entries[0].outgoingText(), "Recognized speech")
        // Archives written before transcription remain readable.
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
        var entries = raw["entries"] as! [[String: Any]]
        entries[0].removeValue(forKey: "transcript"); entries[0].removeValue(forKey: "transcriptionBlocked"); raw["entries"] = entries
        let legacy = try JSONDecoder().decode(RelayJournal.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(legacy.entries[0].transcript)
        XCTAssertTrue(legacy.entries[0].canPrepare)
        var upgrade = legacy; upgrade.recoverInterrupted()
        XCTAssertEqual(upgrade.entries[0].voiceReply, false)
    }
    func testTranscriptPayloadContainsOnlyTextInputAndStillRequestsVoiceReply() throws {
        let body = try TextPayload.body("Please say hello.", deviceID: "test-device", sessionID: "test-chat", voiceReply: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["message", "device_id", "session_id", "output_modality"])
        XCTAssertEqual(object["message"] as? String, "Please say hello.")
        XCTAssertEqual(object["output_modality"] as? String, "voice")
        XCTAssertNil(object["items"])
        let textReply = try TextPayload.body("Please say hello.", deviceID: "test-device", sessionID: "test-chat", voiceReply: false)
        let textObject = try XCTUnwrap(JSONSerialization.jsonObject(with: textReply) as? [String: Any])
        XCTAssertEqual(textObject["output_modality"] as? String, "text")
        XCTAssertNil(textObject["items"])
        XCTAssertThrowsError(try TextPayload.body("  ", deviceID: "test", sessionID: "test"))
        XCTAssertThrowsError(try TextPayload.body(String(repeating: "a", count: 16385), deviceID: "test", sessionID: "test"))
    }
    func testOptionalVoiceInstructionIsDurableTextAndDoesNotChangeDeduplicationRequest() throws {
        let request = RelayRequest(account: "test", chatID: UUID(), text: "Please say hello.")
        var journal = RelayJournal(); try journal.receive(request)
        journal.entries[0].voiceReply = false; journal.entries[0].askForVoiceNote = true
        let restored = try JSONDecoder().decode(RelayJournal.self, from: JSONEncoder().encode(journal))
        XCTAssertEqual(restored.entries[0].voiceReply, false)
        XCTAssertEqual(restored.entries[0].askForVoiceNote, true)
        XCTAssertEqual(try restored.entries[0].outgoingText(), request.text)
        let outgoing = try restored.entries[0].outgoingText(includeVoiceRequest: true)
        XCTAssertEqual(outgoing, request.text + "\n\n" + JournalEntry.voiceNoteInstruction)
        let body = try TextPayload.body(outgoing, deviceID: "test", sessionID: "test", voiceReply: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["output_modality"] as? String, "text")
        XCTAssertNil(object["items"])
        XCTAssertFalse(try journal.receive(request))
        journal.entries[0].askForVoiceNote = false
        XCTAssertEqual(try journal.entries[0].outgoingText(), request.text)
    }
    func testOnlyScoped404IsAnUnavailableSavedConversation() {
        XCTAssertEqual(MuseError.subscriptionError(status: 404, scoped: true), .conversationUnavailable)
        XCTAssertFalse(MuseError.subscriptionError(status: 404, scoped: false)!.isSavedReplyUnavailable)
        XCTAssertEqual(MuseError.subscriptionError(status: 401, scoped: true), .rejectedCredentials)
        XCTAssertEqual(MuseError.subscriptionError(status: 403, scoped: false), .rejectedCredentials)
        XCTAssertFalse(MuseError.subscriptionError(status: 503, scoped: true)!.isSavedReplyUnavailable)
        XCTAssertNil(MuseError.subscriptionError(status: 200, scoped: true))
    }
    func testUnavailableSavedReplyStopsRecoveryAcrossRelaunchWithoutReposting() throws {
        let request = RelayRequest(account: "test", chatID: UUID(), text: "Already accepted")
        let next = RelayRequest(account: "test", chatID: UUID(), text: "Next request")
        var journal = RelayJournal()
        try journal.receive(request); try journal.receive(next)
        journal.entries[0].acceptedID = "accepted-message"
        journal.entries[0].delivery = .replyUnavailable
        XCTAssertTrue(journal.entries[0].canRecoverReply)
        journal.stopReplyRecovery(request.id, detail: MuseError.conversationUnavailable.localizedDescription)
        var restored = try JSONDecoder().decode(RelayJournal.self, from: JSONEncoder().encode(journal))
        restored.recoverInterrupted()
        XCTAssertFalse(restored.entries[0].canRecoverReply)
        XCTAssertEqual(restored.entries[0].acceptedID, "accepted-message")
        XCTAssertEqual(restored.entries[0].delivery, .replyUnavailable)
        XCTAssertEqual(restored.entries[1].delivery, .received)
        XCTAssertFalse(try restored.receive(request))
        XCTAssertEqual(restored.entries.count, 2)
        // Older archives lack the optional stop marker and retain recoverable accepted replies.
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
        var entries = raw["entries"] as! [[String: Any]]; entries[0].removeValue(forKey: "recoveryStopped"); raw["entries"] = entries
        let legacy = try JSONDecoder().decode(RelayJournal.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertTrue(legacy.entries[0].canRecoverReply)
    }
    func testOnlyUntitledOriginalStarterPairsLeaveTheMainChatList() throws {
        for (title, symbol) in [("Check-in", "sparkles"), ("Ideas", "lightbulb"), ("Goals", "checkmark.circle")] {
            var legacy = RelayChat(title: title, symbol: symbol, exists: true)
            XCTAssertTrue(legacy.isLegacyStarter)
            try legacy.rename("My \(title)")
            XCTAssertFalse(legacy.isLegacyStarter)
            var topic = RelayChat(title: title, symbol: symbol)
            topic.serverTitle = "Actual conversation topic"
            XCTAssertFalse(topic.isLegacyStarter)
            XCTAssertFalse(RelayChat(title: title, symbol: "bubble.left.and.bubble.right").isLegacyStarter)
        }
        XCTAssertFalse(RelayChat(title: "Chat 1", symbol: "bubble.left.and.bubble.right").isLegacyStarter)
    }
    func testFirstMessageIntroducesAnIndependentChatWithoutReplacingExistingSessions() throws {
        let existing = RelayChat(title: "Muse", symbol: "bubble", exists: true)
        let first = RelayChat.fresh(in: [existing])
        let second = RelayChat.fresh(in: [existing, first])
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.title, second.title)
        let request = RelayRequest(account: "test-account", chatID: first.id, text: "A new conversation", newChat: first)
        let transferred = try JSONDecoder().decode(RelayRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(try transferred.chatToInsert(in: [existing]), first)
        var adopted = first; adopted.exists = true
        XCTAssertNil(try transferred.chatToInsert(in: [existing, adopted]))
        var journal = RelayJournal()
        XCTAssertTrue(try journal.receive(transferred))
        XCTAssertFalse(try journal.receive(transferred))
        XCTAssertEqual(journal.entries.count, 1)
    }
    func testChatIntroductionRejectsWrongIDsExistingSessionClaimsAndInvalidTitles() throws {
        let chat = RelayChat.fresh(in: [])
        XCTAssertThrowsError(try RelayRequest(account: "test", chatID: UUID(), text: "Hello", newChat: chat).validate())
        var invalid = chat; invalid.exists = true
        XCTAssertThrowsError(try RelayRequest(account: "test", chatID: chat.id, text: "Hello", newChat: invalid).validate())
        invalid = chat; invalid.title = "  "
        XCTAssertThrowsError(try RelayRequest(account: "test", chatID: chat.id, text: "Hello", newChat: invalid).validate())
        invalid.title = String(repeating: "a", count: 81)
        XCTAssertThrowsError(try RelayRequest(account: "test", chatID: chat.id, text: "Hello", newChat: invalid).validate())
    }
    func testLegacyRequestsRemainValidOnlyForKnownChats() throws {
        let chat = RelayChat(title: "Existing", symbol: "bubble", exists: true)
        let request = RelayRequest(account: "test", chatID: chat.id, text: "Continue")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        object.removeValue(forKey: "newChat")
        let oldRequest = try JSONDecoder().decode(RelayRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(oldRequest.newChat)
        XCTAssertNil(try oldRequest.chatToInsert(in: [chat]))
        XCTAssertThrowsError(try oldRequest.chatToInsert(in: []))
    }
    func testImmediateAudioIsCompleteAndVerifiedBeforeSubmission() throws {
        let audio = wav(seconds: 4)
        let hash = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
        let request = RelayRequest(account: "owned-account", chatID: UUID(), text: "", audioSHA256: hash, duration: 4)
        var assembly = try VoiceChunkAssembly(request: request, totalBytes: audio.count)
        let first = Data(audio.prefix(VoiceChunkAssembly.chunkBytes))
        XCTAssertNil(try assembly.append(index: 0, chunk: first))
        XCTAssertNil(try assembly.append(index: 0, chunk: first)) // Transport retry is idempotent.
        XCTAssertThrowsError(try assembly.append(index: 2, chunk: first)) // A gap cannot form a valid upload.
        var completed: Data?
        for offset in stride(from: VoiceChunkAssembly.chunkBytes, to: audio.count, by: VoiceChunkAssembly.chunkBytes) {
            completed = try assembly.append(index: offset / VoiceChunkAssembly.chunkBytes, chunk: audio.subdata(in: offset..<min(audio.count, offset + VoiceChunkAssembly.chunkBytes)))
            if offset + VoiceChunkAssembly.chunkBytes < audio.count { XCTAssertNil(completed) }
        }
        XCTAssertEqual(completed, audio)
        try VoicePayload.validateWAV(XCTUnwrap(completed))
    }
    func testImmediateAudioRejectsCorruptionAndOversizedAllocation() throws {
        let audio = wav()
        let request = RelayRequest(account: "owned-account", chatID: UUID(), text: "", audioSHA256: String(repeating: "0", count: 64), duration: 1)
        XCTAssertThrowsError(try VoiceChunkAssembly(request: request, totalBytes: 2 * 1024 * 1024 + 1))
        var assembly = try VoiceChunkAssembly(request: request, totalBytes: audio.count)
        let first = Data(audio.prefix(VoiceChunkAssembly.chunkBytes))
        XCTAssertNil(try assembly.append(index: 0, chunk: first))
        XCTAssertThrowsError(try assembly.append(index: 0, chunk: Data(repeating: 1, count: first.count)))
        XCTAssertThrowsError(try assembly.append(index: 1, chunk: Data(audio.dropFirst(VoiceChunkAssembly.chunkBytes))))
    }
    func testDuplicateTransportDeliveryAndCrashRecoveryNeverResubmit() throws {
        let request = RelayRequest(account: "owned-account", chatID: UUID(), text: "Hello")
        var journal = RelayJournal()
        XCTAssertTrue(try journal.receive(request))
        XCTAssertFalse(try journal.receive(request))
        let conflicting = RelayRequest(id: request.id, account: request.account, chatID: request.chatID, text: "Different content", createdAt: request.createdAt)
        XCTAssertThrowsError(try journal.receive(conflicting))
        journal.entries[0].delivery = .sending
        var restored = try JSONDecoder().decode(RelayJournal.self, from: JSONEncoder().encode(journal))
        restored.recoverInterrupted()
        XCTAssertEqual(restored.entries[0].delivery, .uncertain)
        XCTAssertFalse(try restored.receive(request))
        XCTAssertEqual(restored.entries.count, 1)
        // A failed connection before submission may safely be retried.
        restored.entries[0].delivery = .connecting; restored.recoverInterrupted()
        XCTAssertEqual(restored.entries[0].delivery, .received)
        restored.entries[0].delivery = .accepted; restored.entries[0].acceptedID = "server-accepted"
        restored.recoverInterrupted()
        XCTAssertEqual(restored.entries[0].delivery, .replyUnavailable)
        XCTAssertFalse(try restored.receive(request))
        restored.entries[0].delivery = .connecting; restored.recoverInterrupted()
        XCTAssertEqual(restored.entries[0].delivery, .replyUnavailable)
    }
    func testRestoredAcknowledgementOnlyAcceptsItsSavedChat() throws {
        let accumulator = try TurnAccumulator(resumingSessionID: "saved-chat", acceptedMessageID: "accepted-user")
        let event: [String: Any] = ["type": "event", "event": "delta.message_done", "payload": ["session_id": "saved-chat", "message_id": "assistant", "reply_to_message_id": "accepted-user", "display_text": "Recovered response"]]
        XCTAssertEqual(try accumulator.feed(event).first?.text, "Recovered response")
        var foreign = event; var payload = event["payload"] as! [String: Any]; payload["session_id"] = "other-chat"; foreign["payload"] = payload
        XCTAssertTrue(try accumulator.feed(foreign).isEmpty)
    }
    func testWatchContextStaysBelowConnectivityLimitWithLongUnicodeReplies() throws {
        let chat = RelayChat(title: "Muse", symbol: "bubble")
        let messages = (0..<100).map { RelayMessage(id: "\($0)", chatID: chat.id, role: "muse", text: String(repeating: "🪷", count: 20000)) }
        let snapshot = RelaySnapshot(account: "test", revision: 1, paired: true, status: "Ready", museName: "Muse", personName: "You", chats: [chat], messages: messages, updatedAt: .now)
        let data = try snapshot.contextData()
        XCTAssertLessThanOrEqual(data.count, 55000)
        let decoded = try JSONDecoder().decode(RelaySnapshot.self, from: data)
        XCTAssertEqual(decoded.messages.last?.id, "99")
        XCTAssertLessThan(decoded.messages.count, 100)
    }
    func wav(seconds: Int = 1) -> Data {
        let count = seconds * 32000
        func u16(_ value: UInt16) -> Data { Data([UInt8(value & 255), UInt8(value >> 8)]) }
        func u32(_ value: UInt32) -> Data { Data((0..<4).map { UInt8((value >> ($0 * 8)) & 255) }) }
        let parts: [Data] = [Data("RIFF".utf8), u32(UInt32(36 + count)), Data("WAVEfmt ".utf8), u32(16), u16(1), u16(1), u32(16000), u32(32000), u16(2), u16(16), Data("data".utf8), u32(UInt32(count)), Data(repeating: 0, count: count)]
        return parts.reduce(into: Data()) { $0.append($1) }
    }
    func testVoiceUploadMatchesSDKShapeAndRejectsCorruptRecordings() throws {
        let audio = wav(seconds: 60)
        let body = try VoicePayload.body(audio, text: "", deviceID: "device", sessionID: "owned-chat")
        let object = try jsonObject(body)
        XCTAssertEqual(object["output_modality"] as? String, "voice")
        XCTAssertEqual(object["session_id"] as? String, "owned-chat")
        let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["mime_type"] as? String, "audio/wav")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(item["data_base64"] as? String)), audio)
        XCTAssertGreaterThan(body.count, 128 * 1024) // Must use streamed upload on the live transport.
        XCTAssertThrowsError(try VoicePayload.validateWAV(Data(audio.prefix(100))))
        XCTAssertThrowsError(try VoicePayload.validateWAV(wav(seconds: 70)))
        var stereo = wav(); stereo[22] = 2
        XCTAssertThrowsError(try VoicePayload.validateWAV(stereo))
    }
}
