import Foundation

public enum TextPayload {
    public static func body(_ text: String, deviceID: String, sessionID: String, voiceReply: Bool = false) throws -> Data {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16384 else {
            throw MuseError.invalid("Enter a message of up to 16 KiB.")
        }
        return try jsonData(["message": text, "output_modality": voiceReply ? "voice" : "text", "device_id": deviceID, "session_id": sessionID])
    }
}
