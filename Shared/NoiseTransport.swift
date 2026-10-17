// Adapted from Meta's muse-gadget-sdk noise package (Apache-2.0).
import Foundation
import CryptoKit

public final class NoiseCipher {
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0
    private var dead = false
    public init(key: Data? = nil) { self.key = key.map { SymmetricKey(data: $0) } }
    public func encrypt(_ data: Data, aad: Data = Data()) throws -> Data { try crypt(data, aad: aad, decrypt: false) }
    public func decrypt(_ data: Data, aad: Data = Data()) throws -> Data { try crypt(data, aad: aad, decrypt: true) }
    private func crypt(_ data: Data, aad: Data, decrypt: Bool) throws -> Data {
        guard !dead else { throw MuseError.invalid("Noise cipher is closed.") }
        guard let key else { return data }
        do {
            guard nonce < (1 << 53) - 1 else { throw MuseError.invalid("Noise nonce exhausted.") }
            let value = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + Data.bigEndian(nonce))
            let output: Data
            if decrypt {
                guard data.count >= 16 else { throw MuseError.invalid("Invalid Noise ciphertext.") }
                output = try AES.GCM.open(AES.GCM.SealedBox(nonce: value, ciphertext: data.dropLast(16), tag: data.suffix(16)), using: key, authenticating: aad)
            } else {
                let box = try AES.GCM.seal(data, using: key, nonce: value, authenticating: aad)
                output = box.ciphertext + box.tag
            }
            nonce += 1; return output
        } catch { dead = true; throw error }
    }
}
public final class NoiseHandshake {
    private var chaining = Data("Noise_XX_25519_AESGCM_SHA256".utf8)
    private var hash = Data()
    private var cipher = NoiseCipher()
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private var stage = 0
    public init() {
        chaining += Data(repeating: 0, count: 32 - chaining.count); hash = sha256(chaining)
    }
    private func mixHash(_ data: Data) { hash = sha256(hash + data) }
    private func mixKey(_ data: Data) {
        let seed = hmac(chaining, data)
        chaining = hmac(seed, Data([1]))
        cipher = NoiseCipher(key: hmac(seed, chaining + Data([2])))
    }
    private func dh(_ key: Curve25519.KeyAgreement.PrivateKey, _ remote: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let secret = try key.sharedSecretFromKeyAgreement(with: remote).withUnsafeBytes { Data($0) }
        guard secret.contains(where: { $0 != 0 }) else { throw MuseError.invalid("Invalid Noise peer key.") }; return secret
    }
    private func seal(_ data: Data) throws -> Data { let value = try cipher.encrypt(data, aad: hash); mixHash(value); return value }
    private func open(_ data: Data) throws -> Data { let value = try cipher.decrypt(data, aad: hash); mixHash(data); return value }
    public func message1(key: Curve25519.KeyAgreement.PrivateKey? = nil) throws -> Data {
        guard stage == 0 else { throw MuseError.invalid("Invalid Noise handshake state.") }; stage = -1
        let key = key ?? Curve25519.KeyAgreement.PrivateKey(); ephemeral = key
        let pub = key.publicKey.rawRepresentation; mixHash(pub); _ = try seal(Data()); stage = 1; return pub
    }
    public func message2(_ data: Data) throws {
        guard stage == 1, let ephemeral, data.count >= 96, data.count <= 65536 else { throw MuseError.invalid("Invalid Noise handshake response.") }; stage = -1
        let remote = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: data.prefix(32)); remoteEphemeral = remote
        mixHash(remote.rawRepresentation); mixKey(try dh(ephemeral, remote))
        let staticKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: open(data.dropFirst(32).prefix(48)))
        mixKey(try dh(ephemeral, staticKey)); _ = try open(data.dropFirst(80)); stage = 2
    }
    public func message3(key: Curve25519.KeyAgreement.PrivateKey? = nil) throws -> Data {
        guard stage == 2, let remoteEphemeral else { throw MuseError.invalid("Invalid Noise handshake state.") }; stage = -1
        let key = key ?? Curve25519.KeyAgreement.PrivateKey()
        let encodedKey = try seal(key.publicKey.rawRepresentation)
        mixKey(try dh(key, remoteEphemeral)); let result = try encodedKey + seal(Data()); stage = 3; return result
    }
    public func split() throws -> (send: NoiseCipher, receive: NoiseCipher) {
        guard stage == 3 else { throw MuseError.invalid("Incomplete Noise handshake.") }; stage = -1
        let seed = hmac(chaining, Data()); let first = hmac(seed, Data([1])); let second = hmac(seed, first + Data([2]))
        ephemeral = nil; remoteEphemeral = nil; chaining = Data(); hash = Data()
        return (NoiseCipher(key: first), NoiseCipher(key: second))
    }
}

// Minimal bounded protobuf codec for the SDK's public service-envelope format.
public enum Proto {
    public struct Field { public let number: Int; public let value: UInt64?; public let bytes: Data? }
    public static func varint(_ input: UInt64) -> Data {
        var value = input, data = Data()
        repeat { var byte = UInt8(value & 127); value >>= 7; if value > 0 { byte |= 128 }; data.append(byte) } while value > 0
        return data
    }
    public static func int(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    public static func bytes(_ field: Int, _ data: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(data.count)) + data }
    public static func string(_ field: Int, _ text: String) -> Data { bytes(field, Data(text.utf8)) }
    public static func decode(_ data: Data) throws -> [Field] {
        guard data.count <= 16 * 1024 * 1024 else { throw MuseError.invalid("Protocol envelope exceeds limit.") }
        let bytes = [UInt8](data); var index = 0; var fields: [Field] = []
        func read() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard index < bytes.count else { throw MuseError.invalid("Truncated protocol field.") }
                let byte = bytes[index]; index += 1
                guard shift < 63 || byte <= 1 else { throw MuseError.invalid("Protocol integer overflow.") }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw MuseError.invalid("Invalid protocol integer.")
        }
        while index < bytes.count {
            let key = try read(); let number = Int(key >> 3)
            guard number > 0, fields.count < 65536 else { throw MuseError.invalid("Invalid protocol field.") }
            switch key & 7 {
            case 0: fields.append(Field(number: number, value: try read(), bytes: nil))
            case 2:
                let count = try read(); guard count <= UInt64(bytes.count - index) else { throw MuseError.invalid("Truncated protocol payload.") }
                fields.append(Field(number: number, value: nil, bytes: Data(bytes[index..<index + Int(count)]))); index += Int(count)
            case 1, 5:
                let count = key & 7 == 1 ? 8 : 4
                guard index + count <= bytes.count else { throw MuseError.invalid("Truncated protocol field.") }; index += count
            default: throw MuseError.invalid("Unsupported protocol field.")
            }
        }
        return fields
    }
}
public struct ServicePacket {
    public let streamID: UInt64
    public let kind: Int
    public let status: UInt64
    public let data: Data
    public let ended: Bool
}
public final class NoiseTransport {
    private let send: NoiseCipher, receive: NoiseCipher
    private var stream: UInt64 = 0, chunkID: UInt64 = 0
    private struct Assembly { var parts: [Int: Data] = [:]; let total: Int; let started = Date(); var bytes = 0 }
    private var assemblies: [UInt64: Assembly] = [:]
    private var dead = false
    public init(send: NoiseCipher, receive: NoiseCipher) { self.send = send; self.receive = receive }
    public func request(path: String, body: Data = Data(), streaming: Bool = false, headers: [(String, String)] = [], method: String = "POST") throws -> (id: UInt64, frames: [Data]) {
        guard ["POST", "GET"].contains(method) else { throw MuseError.invalid("Unsupported request method.") }
        stream += 1
        var request = Proto.string(1, method) + Proto.string(2, path)
        for (name, value) in headers { request += Proto.bytes(3, Proto.string(1, name) + Proto.string(2, value)) }
        if !body.isEmpty { request += Proto.bytes(4, body) }
        if !streaming { request += Proto.int(5, 1) }
        return (stream, try encode(stream: stream, kind: 2, data: request))
    }
    public func body(stream: UInt64, data: Data, ended: Bool = false) throws -> [Data] {
        try encode(stream: stream, kind: 4, data: Proto.bytes(1, data) + (ended ? Proto.int(2, 1) : Data()))
    }
    public func reset(stream: UInt64) throws -> [Data] {
        try encode(stream: stream, kind: 5, data: Proto.int(1, 1)) // SDK ResetCode.CANCELLED
    }
    private func encode(stream: UInt64, kind: Int, data: Data) throws -> [Data] {
        guard !dead else { throw MuseError.interrupted }
        let envelope = Proto.bytes(2, Proto.int(1, stream) + Proto.bytes(kind, data)); chunkID += 1
        let count = max(1, (envelope.count + 65488) / 65489)
        guard count <= 256 else { throw MuseError.invalid("Request exceeds transport limits.") }
        return try (0..<count).map { i in
            try send.encrypt(Proto.int(1, chunkID) + Proto.int(2, UInt64(i)) + Proto.int(3, UInt64(count)) + Proto.bytes(4, Data(envelope.dropFirst(i * 65489).prefix(65489))))
        }
    }
    public func decode(_ ciphertext: Data) throws -> ServicePacket? {
        guard !dead else { throw MuseError.interrupted }
        do {
            let fields = try Proto.decode(receive.decrypt(ciphertext))
            let id = fields.first { $0.number == 1 }?.value ?? 0
            guard let index = Int(exactly: fields.first { $0.number == 2 }?.value ?? 0),
                  let total = Int(exactly: fields.first { $0.number == 3 }?.value ?? 1) else { throw MuseError.invalid("Noise chunk index overflow.") }
            let data = fields.first { $0.number == 4 }?.bytes ?? Data()
            guard total > 0, total <= 256, index >= 0, index < total, data.count <= 65489 else { throw MuseError.invalid("Invalid Noise chunk.") }
            assemblies = assemblies.filter { Date().timeIntervalSince($0.value.started) <= 60 }
            guard assemblies[id] != nil || assemblies.count < 16 else { throw MuseError.invalid("Too many pending Noise assemblies.") }
            var a = assemblies[id] ?? Assembly(total: total)
            guard a.total == total, a.parts[index] == nil, a.bytes + data.count <= 16 * 1024 * 1024 else { throw MuseError.invalid("Invalid Noise assembly.") }
            a.parts[index] = data; a.bytes += data.count; assemblies[id] = a
            guard a.parts.count == total else { return nil }
            assemblies.removeValue(forKey: id)
            var envelope = Data(); for i in 0..<total { guard let part = a.parts[i] else { throw MuseError.invalid("Incomplete Noise assembly.") }; envelope += part }
            guard let service = try Proto.decode(envelope).first(where: { $0.number == 1 })?.bytes else { throw MuseError.invalid("Invalid service response.") }
            let frame = try Proto.decode(service)
            guard let streamID = frame.first(where: { $0.number == 1 })?.value,
                  let payload = frame.last(where: { (2...5).contains($0.number) }), let raw = payload.bytes, payload.number != 2 else { throw MuseError.invalid("Invalid service frame.") }
            let body = try Proto.decode(raw)
            let kind = payload.number
            return ServicePacket(streamID: streamID, kind: kind,
                status: kind == 3 ? body.first(where: { $0.number == 1 })?.value ?? 0 : 0,
                data: body.first(where: { $0.number == (kind == 3 ? 3 : 1) })?.bytes ?? Data(),
                ended: kind == 5 || body.first(where: { $0.number == (kind == 3 ? 4 : 2) })?.value == 1)
        } catch { dead = true; throw error }
    }
}
