import Foundation

/// Private iPhone metadata from a correlated audio presentation. Never included in Watch snapshots.
public struct MuseAudioPresentation: Codable, Equatable, Sendable {
    public let path: String
    public let mime: String
    public let bytes: Int?
    public let resources: Data?
    public let audioMetadata: Data
    public var accessDenied: Bool? = nil
    public init(payload: [String: Any]) throws {
        guard payload["kind"] as? String == "audio", let data = payload["data"] as? [String: Any],
              let audio = data["audio"] as? [String: Any] else { throw RelayError.invalid }
        // Retain an early/incomplete card privately; validate again before any retrieval.
        path = audio["path"] as? String ?? ""; mime = audio["mime"] as? String ?? ""
        bytes = (audio["byte_len"] as? NSNumber)?.intValue
        audioMetadata = try JSONSerialization.data(withJSONObject: audio)
        guard audioMetadata.count <= 16384 else { throw RelayError.invalid }
        if let resources = payload["resources"], JSONSerialization.isValidJSONObject(resources) {
            let encoded = try JSONSerialization.data(withJSONObject: resources)
            guard encoded.count <= 131072 else { throw RelayError.invalid }; self.resources = encoded
        } else { resources = nil }
    }
    public func validate() throws {
        let audio = try JSONSerialization.jsonObject(with: audioMetadata) as? [String: Any]
        guard audio?["missing"] as? Bool != true, !path.isEmpty, path.utf8.count <= 4096,
              !path.unicodeScalars.contains(where: { $0.value < 32 }),
              ["audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/wav", "audio/ogg"].contains(mime) else { throw RelayError.invalid }
        if let bytes { guard bytes > 0, bytes <= ReplyAudio.maximumBytes else { throw RelayError.invalid } }
    }
    public var mimeLabel: String { ["audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/wav", "audio/ogg"].contains(mime) ? mime : "other MIME" }
    public func fetchPath() throws -> String {
        try validate()
        let metadata = try JSONSerialization.jsonObject(with: audioMetadata) as? [String: Any]
        let original = (metadata?["variants"] as? [String: Any])?["original"] as? String
        for candidate in [path, original].compactMap({ $0 }) {
            var value = candidate
            if value.hasPrefix("sandbox://") { value.removeFirst("sandbox://".count) }
            if value.hasPrefix("/") { value.removeFirst() }
            let segments = value.components(separatedBy: "/")
            guard segments.count >= 2, segments[0] == "workspace", value.utf8.count <= 4096,
                  ["mp3", "wav", "m4a", "mp4", "ogg", "opus", "flac", "aac"].contains(URL(fileURLWithPath: value).pathExtension.lowercased()) else { continue }
            var safe = true
            for segment in segments {
                var decoded = segment
                for _ in 0..<6 {
                    if decoded.isEmpty || [".", ".."].contains(decoded) || decoded.contains("/") || decoded.contains("\\") || decoded.unicodeScalars.contains(where: { $0.value < 32 }) { safe = false; break }
                    guard let next = decoded.removingPercentEncoding, next != decoded else { break }
                    decoded = next
                }
                if decoded.isEmpty || [".", ".."].contains(decoded) || decoded.contains("/") || decoded.contains("\\") || decoded.unicodeScalars.contains(where: { $0.value < 32 }) { safe = false }
                if let next = decoded.removingPercentEncoding, next != decoded { safe = false }
            }
            guard safe else { continue }
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let encoded = segments.compactMap { $0.addingPercentEncoding(withAllowedCharacters: allowed) }
            guard encoded.count == segments.count else { continue }
            return "/" + encoded.joined(separator: "/")
        }
        throw RelayError.invalid
    }
    public var pathKind: String {
        if path.isEmpty { return "missing path" }
        guard let scheme = URLComponents(string: path)?.scheme else { return path.hasPrefix("/") ? "absolute path" : "relative path" }
        return ["https", "http", "file", "resource", "blob"].contains(scheme) ? scheme : "other scheme"
    }
}
