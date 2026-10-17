// Adapted from Meta's muse-gadget-sdk pairing.py and ble_framing.py (Apache-2.0).
import Foundation
import CryptoKit

public final class BLEChunks {
    private var buffer = Data(), total = 0, next = 0
    public init() {}
    public func reset() { buffer = Data(); total = 0; next = 0 }
    public func feed(_ packet: Data) throws -> Data? {
        let bytes = [UInt8](packet)
        guard bytes.count >= 3, bytes[0] == 0xfe else {
            guard packet.count <= 8192 else { throw MuseError.invalid("BLE message exceeds limit.") }; return packet
        }
        let index = Int(bytes[1]), count = Int(bytes[2])
        if index == 0 || count != total { reset(); total = count }
        guard count > 0, index == next, index < total, buffer.count + bytes.count - 3 <= 8192 else { reset(); throw MuseError.invalid("Invalid BLE fragment sequence.") }
        buffer.append(contentsOf: bytes.dropFirst(3)); next += 1
        guard next == total else { return nil }
        let result = buffer; reset(); return result
    }
    public static func encode(_ data: Data, maximumPacket: Int) throws -> [Data] {
        let usable = min(maximumPacket, 160) - 3
        guard usable > 0 else { throw MuseError.invalid("Bluetooth packet size is too small.") }
        let count = max(1, (data.count + usable - 1) / usable)
        guard count <= 255 else { throw MuseError.invalid("BLE response exceeds fragment limit.") }
        return (0..<count).map { i in
            Data([0xfe, UInt8(i), UInt8(count)]) + data.dropFirst(i * usable).prefix(usable)
        }
    }
}

public final class PairingV5 {
    public enum State { case idle, waiting, ready, provisioning }
    public private(set) var state: State = .idle
    public private(set) var sessionID = ""
    public private(set) var generation = UUID()
    public let identity: GadgetIdentity
    private let sdkToken: String
    private let version: String
    private let clock: () -> Date
    private var deadline = Date.distantPast
    private var rx: SymmetricKey?, tx: SymmetricKey?
    private var rxCounter: UInt64 = 0, txCounter: UInt64 = 0
    public init(identity: GadgetIdentity, sdkToken: String, version: String = "1.0.0", clock: @escaping () -> Date = Date.init) {
        self.identity = identity; self.sdkToken = sdkToken; self.version = version; self.clock = clock
    }
    public func reset() { state = .idle; rx = nil; tx = nil; sessionID = ""; rxCounter = 0; txCounter = 0; generation = UUID() }
    public var deviceInfo: [String: Any] { [
        "type": "device_info", "node_id": identity.nodeID, "device_id": identity.deviceID,
        "mac": identity.mac, "version": version, "model": "hatch_link", "pairing_protocol": 5,
        "pairing_auth": "none", "pairing_auth_epoch": 0, "pairing_policy": "confirm_app", "build_sha": ""
    ] }
    public static func transcript(identity: GadgetIdentity, version: String, mobilePub: String, devicePub: String, mobileNonce: String, deviceNonce: String, policy: String = "confirm_app") -> String {
        ["hatch-link-pairing-v5", "version=5", "initiator_role=mobile", "responder_role=link",
         "device_id=\(identity.deviceID)", "node_id=\(identity.nodeID)", "mac=\(identity.mac)",
         "model=hatch_link", "firmware_version=\(version)", "selected_cipher_suite=p256-hkdf-sha256-aes-gcm-v1",
         "pairing_auth=none", "pairing_auth_epoch=0", "pairing_policy=\(policy)", "confirm_timeout_seconds=\(policy == "confirm_press" ? 60 : 0)",
         "mobile_pub=\(mobilePub)", "device_pub=\(devicePub)", "mobile_nonce=\(mobileNonce)", "device_nonce=\(deviceNonce)"].joined(separator: "\n")
    }
    public static func derive(secret: Data, mobileNonce: Data, deviceNonce: Data, transcriptHash: Data) -> (rx: Data, tx: Data, session: Data) {
        let salt = sha256(mobileNonce + deviceNonce + transcriptHash)
        let prk = hmac(salt, secret)
        let sessionSecret = hkdfExpand(prk, info: Data("hatch-link ble setup v1".utf8))
        return (hkdfExpand(sessionSecret, info: Data("mobile->device".utf8)), hkdfExpand(sessionSecret, info: Data("device->mobile".utf8)), sha256(Data("hatch-link session id v1".utf8) + transcriptHash + secret).prefix(16))
    }
    public func hello(_ message: [String: Any], privateKey: P256.KeyAgreement.PrivateKey? = nil, nonce: Data? = nil) throws -> [String: Any] {
        reset()
        guard let number = message["version"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue == 5, number.doubleValue == 5,
              message["pairing_auth"] as? String == "none", message["pairing_policy"] as? String == "confirm_app",
              let pubText = message["mobile_pub"] as? String, let nonceText = message["mobile_nonce"] as? String else { throw MuseError.invalid("error_pairing_invalid_hello") }
        let pub = try Data(base64URL: pubText), mobileNonce = try Data(base64URL: nonceText)
        guard pub.count == 65, pub.first == 4, mobileNonce.count == 16 else { throw MuseError.invalid("error_pairing_invalid_hello") }
        let key = privateKey ?? P256.KeyAgreement.PrivateKey()
        let deviceNonce = try nonce ?? Data.random(16)
        let devicePub = key.publicKey.x963Representation.base64URL
        let text = Self.transcript(identity: identity, version: version, mobilePub: pubText, devicePub: devicePub, mobileNonce: nonceText, deviceNonce: deviceNonce.base64URL)
        let hash = sha256(Data(text.utf8))
        let shared = try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: pub))
        let keys = Self.derive(secret: shared.withUnsafeBytes { Data($0) }, mobileNonce: mobileNonce, deviceNonce: deviceNonce, transcriptHash: hash)
        rx = SymmetricKey(data: keys.rx); tx = SymmetricKey(data: keys.tx); sessionID = keys.session.base64URL
        state = .waiting; deadline = clock().addingTimeInterval(60)
        return ["type": "pairing_ready", "version": 5, "device_id": identity.deviceID, "node_id": identity.nodeID,
                "mac": identity.mac, "model": "hatch_link", "firmware_version": version,
                "pairing_auth": "none", "pairing_auth_epoch": 0, "pairing_policy": "confirm_app",
                "device_pub": devicePub, "device_nonce": deviceNonce.base64URL,
                "transcript_hash": hash.base64URL, "session_id": sessionID]
    }
    private func check() throws {
        guard state != .idle, clock() <= deadline else { reset(); throw MuseError.invalid("error_pairing_decrypt") }
    }
    public func decrypt(_ envelope: [String: Any]) throws -> [String: Any] {
        do {
            try check()
            guard let rx, envelope["session_id"] as? String == sessionID,
                  let counterText = envelope["counter"] as? String, !counterText.isEmpty, counterText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let counter = UInt64(counterText), counter == rxCounter, counter < UInt64.max,
                  let cipherText = envelope["ciphertext"] as? String, let tagText = envelope["tag"] as? String else { throw MuseError.invalid("error_pairing_decrypt") }
            let ciphertext = try Data(base64URL: cipherText), tag = try Data(base64URL: tagText)
            let nonce = try AES.GCM.Nonce(data: Data([0,0,0,0]) + Data.bigEndian(counter))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let aad = Data("hatch-link ble setup v1|\(sessionID)|m2d|\(counter)".utf8)
            let value = try jsonObject(AES.GCM.open(box, using: rx, authenticating: aad))
            rxCounter += 1
            return value
        } catch { reset(); throw MuseError.invalid("error_pairing_decrypt") }
    }
    public func confirm(_ command: [String: Any]) throws {
        try check()
        guard state == .waiting, rxCounter == 1, command.count == 1, command["action"] as? String == "pairing_client_finished" else {
            reset(); throw MuseError.invalid("error_pairing_decrypt")
        }
        state = .ready; deadline = clock().addingTimeInterval(120)
    }
    public func beginProvisioning() throws -> UUID {
        try check()
        guard state == .ready else { throw MuseError.invalid("error_pairing_confirm_required") }
        state = .provisioning; deadline = clock().addingTimeInterval(120); return generation
    }
    public func validProvisioning(_ token: UUID) -> Bool { state == .provisioning && token == generation && clock() <= deadline }
    public func encrypt(_ message: [String: Any]) throws -> [String: Any] {
        try check()
        guard let tx, txCounter < UInt64.max else { throw MuseError.invalid("error_pairing_decrypt") }
        let count = txCounter
        let nonce = try AES.GCM.Nonce(data: Data([1,0,0,0]) + Data.bigEndian(count))
        let box = try AES.GCM.seal(jsonData(message), using: tx, nonce: nonce, authenticating: Data("hatch-link ble setup v1|\(sessionID)|d2m|\(count)".utf8))
        txCounter += 1
        return ["type": "pairing_encrypted", "session_id": sessionID, "counter": String(count), "ciphertext": box.ciphertext.base64URL, "tag": box.tag.base64URL]
    }
    public func status(_ text: String) throws -> [String: Any] {
        var value: [String: Any] = ["type": "status", "status": text]
        if text == "pairing_confirmed" { value["sdk_token"] = sdkToken }
        return try encrypt(value)
    }
}
