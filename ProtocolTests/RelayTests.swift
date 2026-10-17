import XCTest
import CryptoKit
@testable import MuseCore

final class RelayTests: XCTestCase {
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
        XCTAssertEqual(object["output_modality"] as? String, "text")
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
