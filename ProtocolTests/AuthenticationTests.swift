import XCTest
import CryptoKit
@testable import MuseCore

final class AuthenticationTests: XCTestCase {
    func fixture() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "link_pairing_v5", withExtension: "json", subdirectory: "Fixtures"))
        let document = try jsonObject(Data(contentsOf: url))
        return try XCTUnwrap((document["vectors"] as? [[String: Any]])?.first { $0["name"] as? String == "community_app_v5" })
    }
    func hex(_ string: String) -> Data { Data(stride(from: 0, to: string.count, by: 2).map { i in let a = string.index(string.startIndex, offsetBy: i); let b = string.index(a, offsetBy: 2); return UInt8(string[a..<b], radix: 16)! }) }
    func credentials() throws -> DeviceCredentials {
        try DeviceCredentials(identity: GadgetIdentity(mac: "02:00:00:00:00:01"), sdkToken: "mgst_SYNTHETIC_TEST_ONLY", provision: ["access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "token_type": "device"])
    }
    func testPairingAgainstPublishedCommunityAppVector() throws {
        let v = try fixture(), identity = GadgetIdentity(mac: "02:00:00:00:00:01")
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(v["device_private_scalar_hex"] as! String))
        let pairing = PairingV5(identity: identity, sdkToken: "mgst_TEST")
        let ready = try pairing.hello(["version": 5, "pairing_auth": "none", "pairing_policy": "confirm_app", "mobile_pub": v["mobile_pub"]!, "mobile_nonce": v["mobile_nonce"]!], privateKey: key, nonce: Data(base64URL: v["device_nonce"] as! String))
        XCTAssertEqual(ready["transcript_hash"] as? String, v["transcript_hash"] as? String)
        XCTAssertEqual(ready["session_id"] as? String, v["session_id"] as? String)
        let envelope: [String: Any] = ["session_id": v["session_id"]!, "counter": "0", "ciphertext": v["client_finished_ciphertext"]!, "tag": v["client_finished_tag"]!]
        let command = try pairing.decrypt(envelope); try pairing.confirm(command)
        XCTAssertEqual(pairing.state, .ready)
        let confirmation = try pairing.status("pairing_confirmed")
        let tx = SymmetricKey(data: hex(v["mobile_rx_key_hex"] as! String))
        let nonce = try AES.GCM.Nonce(data: Data([1,0,0,0]) + Data.bigEndian(0))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(base64URL: confirmation["ciphertext"] as! String), tag: Data(base64URL: confirmation["tag"] as! String))
        let opened = try jsonObject(AES.GCM.open(box, using: tx, authenticating: Data("hatch-link ble setup v1|\(pairing.sessionID)|d2m|0".utf8)))
        XCTAssertEqual(opened["sdk_token"] as? String, "mgst_TEST")
        XCTAssertThrowsError(try pairing.decrypt(envelope)); XCTAssertEqual(pairing.state, .idle)
    }
    func testPairingRejectsExpiredAndInvalidHello() throws {
        let v = try fixture(); var now = Date()
        let pairing = PairingV5(identity: GadgetIdentity(mac: "02:00:00:00:00:01"), sdkToken: "mgst_TEST", clock: { now })
        XCTAssertThrowsError(try pairing.hello(["version": true]))
        _ = try pairing.hello(["version": 5, "pairing_auth": "none", "pairing_policy": "confirm_app", "mobile_pub": v["mobile_pub"]!, "mobile_nonce": v["mobile_nonce"]!])
        now = now.addingTimeInterval(61)
        XCTAssertThrowsError(try pairing.status("pairing_confirmed")); XCTAssertEqual(pairing.state, .idle)
    }
    func testEncryptedHandoffRejectsTamperingWrongRecipientAndExpiry() throws {
        let key = Curve25519.KeyAgreement.PrivateKey(), now = Date()
        let request = SetupRequest(publicKey: key.publicKey.rawRepresentation, now: now)
        let original = try credentials()
        let envelope = try SetupEnvelope.seal(original, for: request, now: now)
        XCTAssertEqual(try envelope.open(request: request, privateKey: key.rawRepresentation, now: now), original)
        XCTAssertThrowsError(try envelope.open(request: request, privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, now: now))
        XCTAssertThrowsError(try envelope.open(request: request, privateKey: key.rawRepresentation, now: now.addingTimeInterval(601)))
        var object = try jsonObject(JSONEncoder().encode(envelope))
        var bytes = envelope.sealedCredentials; bytes[bytes.startIndex] ^= 1
        object["sealedCredentials"] = bytes.base64EncodedString()
        let altered = try JSONDecoder().decode(SetupEnvelope.self, from: jsonData(object))
        XCTAssertThrowsError(try altered.open(request: request, privateKey: key.rawRepresentation, now: now))
        let other = SetupRequest(publicKey: key.publicKey.rawRepresentation, now: now)
        XCTAssertThrowsError(try envelope.open(request: other, privateKey: key.rawRepresentation, now: now))
    }
    func testBLEBackpressureFramingAndMalformedChunks() throws {
        let data = Data(repeating: 27, count: 8192)
        let chunks = try BLEChunks.encode(data, maximumPacket: 160), assembler = BLEChunks()
        var result: Data?; for chunk in chunks { result = try assembler.feed(chunk) }
        XCTAssertEqual(result, data)
        XCTAssertThrowsError(try assembler.feed(Data([0xfe, 1, 2, 9])))
        XCTAssertNil(try assembler.feed(Data([0xfe, 0, 2, 9])))
        XCTAssertThrowsError(try assembler.feed(Data([0xfe, 0, 0])))
    }
    func testLiveReplyShapeWithEmptyParentFallsBackAndCompletes() throws {
        let turn = TurnAccumulator(sessionID: "owned-chat")
        _ = try turn.acknowledge(["result": ["session_id": "owned-chat", "is_thread": true, "message_id": "accepted-user"]])
        func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var payload: [String: Any] = ["session_id": "owned-chat", "message_id": "assistant", "reply_to_message_id": ""]
            payload.merge(extra) { _, value in value }
            return ["type": "event", "event": name, "payload": payload]
        }
        XCTAssertEqual(try turn.feed(event("delta.message_start")), [.init(id: "assistant", text: "", done: false)])
        XCTAssertEqual(try turn.feed(event("delta.text_append", ["parent_message_id": "assistant", "text": "Hello"])), [.init(id: "assistant", text: "Hello", done: false)])
        let transcript: [String: Any] = ["messages": [["id": "assistant", "role": "assistant", "content": [["type": "text", "text": "Hello!"]]]]]
        XCTAssertEqual(try turn.feed(event("delta.message_done", ["transcript": transcript])), [.init(id: "assistant", text: "Hello!", done: true)])
        // An empty primary field must still fall back to a nonempty foreign parent.
        var foreign = event("delta.text_append", ["parent_message_id": "someone-else", "text": "wrong"])
        var payload = foreign["payload"] as! [String: Any]; payload["message_id"] = "foreign"; foreign["payload"] = payload
        XCTAssertTrue(try turn.feed(foreign).isEmpty)
    }
    func testReplyCorrelationBuffersUntilAcknowledgementAndRejectsOtherChats() throws {
        let turn = TurnAccumulator(sessionID: "watch-test")
        let event: [String: Any] = ["type": "event", "event": "delta.message_done", "payload": ["session_id": "watch-test", "message_id": "assistant1", "parent_message_id": "user1", "display_text": "A real response"]]
        XCTAssertTrue(try turn.feed(event).isEmpty)
        let replies = try turn.acknowledge(["result": ["session_id": "watch-test", "is_thread": true, "message_id": "user1"]])
        XCTAssertEqual(replies.first?.text, "A real response"); XCTAssertEqual(replies.first?.done, true)
        XCTAssertTrue(try turn.feed(event).isEmpty)
        let unrelated: [String: Any] = ["type": "event", "event": "delta.message_done", "payload": ["session_id": "main", "message_id": "other", "display_text": "Unrelated"]]
        XCTAssertTrue(try turn.feed(unrelated).isEmpty)
        XCTAssertThrowsError(try TurnAccumulator(sessionID: "watch").acknowledge(["message_id": "id"]))
    }
    func testProtocolRejectsOverflowAndTruncation() throws {
        XCTAssertThrowsError(try Proto.decode(Data([0x0a, 0xff])))
        XCTAssertThrowsError(try Proto.decode(Data(repeating: 0xff, count: 11)))
        XCTAssertThrowsError(try Proto.decode(Data([0])))
    }
    func testUUIDChatCorrelationAcceptsCanonicalCaseButKeepsOtherChatsSeparate() throws {
        let id = "12345678-ABCD-1234-1234-123456789ABC"
        let turn = TurnAccumulator(sessionID: id)
        _ = try turn.acknowledge(["session_id": id.lowercased(), "is_thread": true, "message_id": "user1"])
        let replies = try turn.feed(["type": "event", "event": "delta.message_done", "payload": ["session_id": id.lowercased(), "message_id": "assistant1", "parent_message_id": "user1", "display_text": "Hello"]])
        XCTAssertEqual(replies.first?.text, "Hello")
        XCTAssertThrowsError(try TurnAccumulator(sessionID: "Chat").acknowledge(["session_id": "chat", "is_thread": true, "message_id": "user1"]))
        XCTAssertThrowsError(try TurnAccumulator(sessionID: id).acknowledge(["session_id": UUID().uuidString, "is_thread": true, "message_id": "user1"]))
    }
    func testHandoffSurvivesSeparateFileEncodersAndRejectsUnknownHosts() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let request = SetupRequest(publicKey: key.publicKey.rawRepresentation)
        let importedRequest = try JSONDecoder().decode(SetupRequest.self, from: JSONEncoder().encode(request))
        let original = try credentials()
        let envelope = try SetupEnvelope.seal(original, for: importedRequest)
        let importedEnvelope = try JSONDecoder().decode(SetupEnvelope.self, from: JSONEncoder().encode(envelope))
        XCTAssertEqual(try importedEnvelope.open(request: request, privateKey: key.rawRepresentation), original)
        var invalid = try credentials(); invalid.apiURL = "https://example.com"
        XCTAssertThrowsError(try SetupEnvelope.seal(invalid, for: request))
        invalid = try credentials(); invalid.noiseHost = "example.com"
        XCTAssertThrowsError(try invalid.validate())
    }
    func testNoiseChunkOverflowFailsClosed() throws {
        let transport = NoiseTransport(send: NoiseCipher(), receive: NoiseCipher())
        let overflow = Proto.int(1, 1) + Proto.int(2, UInt64.max) + Proto.int(3, 1)
        XCTAssertThrowsError(try transport.decode(overflow))
        XCTAssertThrowsError(try transport.decode(Data()))
    }
}

extension AuthenticationTests {
    func testOutgoingSubscriptionAndCancellationMatchSDK() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "request_reference", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try jsonObject(Data(contentsOf: url))
        let transport = NoiseTransport(send: NoiseCipher(), receive: NoiseCipher())
        let request = try transport.request(path: "/chat/subscribe", body: Data("{\"session_id\":\"side\"}".utf8), headers: [("Content-Type", "application/json"), ("Accept", "application/x-ndjson")])
        let requestPayload = try XCTUnwrap(Proto.decode(XCTUnwrap(request.frames.first)).first { $0.number == 4 }?.bytes)
        XCTAssertEqual(requestPayload, hex(fixture["subscribe"] as! String))
        let reset = try transport.reset(stream: 2)
        let resetPayload = try XCTUnwrap(Proto.decode(XCTUnwrap(reset.first)).first { $0.number == 4 }?.bytes)
        XCTAssertEqual(resetPayload, hex(fixture["reset"] as! String))
    }
    func testPiPythonExportsOpenInSwift() throws {
        struct Fixture: Decodable {
            let request: SetupRequest
            let envelope: SetupEnvelope
            let privateKey: Data
            let context: Data
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: "pi_handoff", withExtension: "json", subdirectory: "Fixtures"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        XCTAssertEqual(fixtures.count, 5)
        for fixture in fixtures {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(fixture.request), fixture.context)
            let value = try fixture.envelope.open(request: fixture.request, privateKey: fixture.privateKey,
                now: fixture.request.createdAt.addingTimeInterval(1))
            XCTAssertEqual(value.accessToken, "synthetic-access")
            XCTAssertEqual(value.identity.nodeID, "homelink-000001")
        }
    }
    func testNoiseHandshakeAndTransportAgainstPinnedPythonSDK() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "noise_reference", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try jsonObject(Data(contentsOf: url))
        let handshake = NoiseHandshake()
        XCTAssertEqual(try handshake.message1(key: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))), hex(fixture["message1"] as! String))
        try handshake.message2(hex(fixture["message2"] as! String))
        XCTAssertEqual(try handshake.message3(key: Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 4, count: 32))), hex(fixture["message3"] as! String))
        let split = try handshake.split(), plain = Data("sdk nonce compatibility".utf8)
        XCTAssertEqual(try split.send.encrypt(plain), hex(fixture["client0"] as! String))
        XCTAssertEqual(try split.send.encrypt(plain), hex(fixture["client1"] as! String))
        let transport = NoiseTransport(send: split.send, receive: split.receive)
        let packet = try XCTUnwrap(transport.decode(hex(fixture["server_response"] as! String)))
        XCTAssertEqual(packet.streamID, 7); XCTAssertEqual(packet.status, 200)
        XCTAssertEqual(packet.data, Data("{\"ok\":true}".utf8)); XCTAssertTrue(packet.ended)
        XCTAssertThrowsError(try transport.decode(Data([0, 1, 2])))
        XCTAssertThrowsError(try transport.decode(hex(fixture["server_response"] as! String)))
    }
}
