// Protocol adaptations: Copyright (c) Meta Platforms, Inc. and affiliates.
// Licensed under Apache-2.0; see ThirdParty/MuseGadgetSDK-LICENSE.
import Foundation
import CryptoKit
import Security

public enum MuseError: LocalizedError, Equatable, Sendable {
    case invalid(String), expiredSetup, rejectedCredentials, network(String), interrupted, conversationUnavailable, savedReplyUnavailable
    public var isSavedReplyUnavailable: Bool { self == .conversationUnavailable || self == .savedReplyUnavailable }
    public static func subscriptionError(status: UInt64, scoped: Bool) -> MuseError? {
        if status == 401 || status == 403 { return .rejectedCredentials }
        if status == 404, scoped { return .conversationUnavailable }
        return status >= 400 ? .network("Muse chat subscription returned HTTP \(status).") : nil
    }
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .expiredSetup: return "This setup request expired. Create a new request on your iPhone."
        case .rejectedCredentials: return "Muse rejected this connection. Pair again using the official Muse app."
        case .network(let reason): return reason
        case .interrupted: return "The connection was interrupted. Delivery may be uncertain."
        case .conversationUnavailable: return "Muse could not reopen this saved conversation. Read its earlier replies in Muse."
        case .savedReplyUnavailable: return "The earlier reply could not be recovered. Read it in Muse; your message will not be resent."
        }
    }
}
public func jsonData(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}
public func jsonObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= 4 * 1024 * 1024,
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MuseError.invalid("Invalid protocol message.")
    }
    return object
}
public extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init(base64URL text: String, maximum: Int = 16384) throws {
        guard !text.isEmpty, text.count <= maximum, text.count % 4 != 1,
              text.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let data = Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - text.count % 4) % 4)) else {
            throw MuseError.invalid("Invalid encoded protocol data.")
        }
        self = data
    }
    static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw MuseError.invalid("Could not generate secure randomness.") }
        return Data(bytes)
    }
    static func bigEndian(_ value: UInt64) -> Data { Swift.withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    static func littleEndian(_ value: UInt64) -> Data { Swift.withUnsafeBytes(of: value.littleEndian) { Data($0) } }
}
public func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
public func hmac(_ key: Data, _ data: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))) }
public func hkdfExpand(_ key: Data, info: Data, count: Int = 32) -> Data {
    var previous = Data(), output = Data(); var i: UInt8 = 1
    while output.count < count { previous = hmac(key, previous + info + Data([i])); output += previous; i += 1 }
    return output.prefix(count)
}
public struct GadgetIdentity: Codable, Equatable, Sendable {
    public let mac: String
    public init(mac: String) { self.mac = mac }
    public static func generate() throws -> Self {
        var bytes = [UInt8](try Data.random(6)); bytes[0] = (bytes[0] & 0xfc) | 2
        return Self(mac: bytes.map { String(format: "%02x", $0) }.joined(separator: ":"))
    }
    public var suffix: String { String(mac.replacingOccurrences(of: ":", with: "").suffix(6)) }
    public var nodeID: String { "homelink-" + suffix }
    public var deviceID: String { "hatch-link:" + mac }
    public var bluetoothName: String { "MuseGadget" + suffix.uppercased() }
    public func validate() throws {
        guard mac.range(of: #"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$"#, options: .regularExpression) != nil else { throw MuseError.invalid("Invalid paired device identity.") }
    }
}
