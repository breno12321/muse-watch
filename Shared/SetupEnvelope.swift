import Foundation
import CryptoKit
import Security

public struct SetupRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let recipientPublicKey: Data
    public init(publicKey: Data, now: Date = .now) {
        version = 1; id = UUID(); createdAt = now; expiresAt = now.addingTimeInterval(600); recipientPublicKey = publicKey
    }
    public func validate(now: Date = .now) throws {
        guard version == 1, recipientPublicKey.count == 32, createdAt <= now.addingTimeInterval(30), expiresAt > createdAt,
              expiresAt.timeIntervalSince(createdAt) <= 600 else { throw MuseError.invalid("Invalid setup request.") }
        guard now < expiresAt else { throw MuseError.expiredSetup }
    }
}
public struct DeviceCredentials: Codable, Equatable, Sendable {
    public var identity: GadgetIdentity
    public var sdkToken: String
    public var accessToken: String
    public var refreshToken: String
    public var username: String
    public var apiURL: String
    public var noiseHost: String
    public var savedAt: Date
    public init(identity: GadgetIdentity, sdkToken: String, provision: [String: Any]) throws {
        self.identity = identity; self.sdkToken = sdkToken
        accessToken = provision["access_token"] as? String ?? ""
        refreshToken = provision["refresh_token"] as? String ?? ""
        username = provision["username"] as? String ?? ""
        apiURL = provision["api_url_v2"] as? String ?? ""
        noiseHost = provision["noise_host"] as? String ?? ""
        savedAt = .now
        guard provision["token_type"] as? String == "device" else { throw MuseError.invalid("Muse supplied an unsupported credential type.") }
        try validate()
    }
    public func validate() throws {
        try identity.validate()
        guard sdkToken.hasPrefix("mgst_"), sdkToken.utf8.count <= 2048,
              !accessToken.isEmpty, !refreshToken.isEmpty, accessToken.count <= 32768, refreshToken.count <= 32768 else { throw MuseError.invalid("Incomplete Muse device credentials.") }
        // Never send credentials to arbitrary hosts embedded in an imported setup file.
        guard apiURL.isEmpty || apiURL == "https://api.muse.ai" || apiURL == "https://api.muse.ai/" else { throw MuseError.invalid("Unrecognized Muse API host.") }
        guard noiseHost.isEmpty || noiseHost == "hatch.metaaivm.com" else { throw MuseError.invalid("Unrecognized Muse transport host.") }
    }
}
public struct SetupEnvelope: Codable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let expiresAt: Date
    public let senderPublicKey: Data
    public let sealedCredentials: Data
    private static func context(_ request: SetupRequest) throws -> Data { try { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(request) }() }
    private static func key(_ shared: SharedSecret, request: SetupRequest) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(request.id.uuidString.utf8), sharedInfo: Data("Muse Watch setup v1".utf8), outputByteCount: 32)
    }
    public static func seal(_ credentials: DeviceCredentials, for request: SetupRequest, now: Date = .now) throws -> Self {
        try request.validate(now: now); try credentials.validate()
        let sender = Curve25519.KeyAgreement.PrivateKey()
        let shared = try sender.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: request.recipientPublicKey))
        let box = try AES.GCM.seal(JSONEncoder().encode(credentials), using: key(shared, request: request), authenticating: context(request))
        guard let combined = box.combined else { throw MuseError.invalid("Couldn’t encrypt setup file.") }
        return Self(version: 1, requestID: request.id, expiresAt: request.expiresAt, senderPublicKey: sender.publicKey.rawRepresentation, sealedCredentials: combined)
    }
    public func open(request: SetupRequest, privateKey: Data, now: Date = .now) throws -> DeviceCredentials {
        try request.validate(now: now)
        guard version == 1, requestID == request.id, expiresAt == request.expiresAt, senderPublicKey.count == 32, sealedCredentials.count <= 131072 else { throw MuseError.invalid("This setup file belongs to a different request.") }
        let recipient = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        guard recipient.publicKey.rawRepresentation == request.recipientPublicKey else { throw MuseError.invalid("This setup file belongs to a different iPhone.") }
        let shared = try recipient.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: senderPublicKey))
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealedCredentials), using: Self.key(shared, request: request), authenticating: Self.context(request))
        let credentials = try JSONDecoder().decode(DeviceCredentials.self, from: plain)
        try credentials.validate(); return credentials
    }
}

public enum SecureStore {
    public static func read(_ account: String) throws -> Data? {
        var query = base(account); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw MuseError.invalid("Keychain access failed (\(status)).") }
        return data
    }
    public static func save(_ data: Data, account: String) throws {
        let query = base(account)
        let changes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(changes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw MuseError.invalid("Couldn’t save credentials in Keychain (\(added)).") }; return
        }
        guard status == errSecSuccess else { throw MuseError.invalid("Couldn’t update Keychain (\(status)).") }
    }
    public static func delete(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw MuseError.invalid("Couldn’t remove Keychain item (\(status)).") }
    }
    private static func base(_ account: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.breno.musewatch.auth", kSecAttrAccount as String: account] }
}
