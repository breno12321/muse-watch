import Foundation

public enum VoicePayload {
    public static let maximumBytes = 2 * 1024 * 1024
    public static func validateWAV(_ data: Data) throws {
        guard data.count >= 44, data.count <= maximumBytes,
              String(data: data.prefix(4), encoding: .ascii) == "RIFF",
              String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE" else { throw MuseError.invalid("Record a WAV voice note of up to 60 seconds.") }
        let bytes = [UInt8](data)
        func word(_ offset: Int, _ count: Int) -> Int { (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) } }
        var offset = 12, validFormat = false, audioBytes = 0
        while offset + 8 <= bytes.count {
            let name = String(bytes: bytes[offset..<offset + 4], encoding: .ascii)
            let length = word(offset + 4, 4); let start = offset + 8
            guard length <= bytes.count - start else { throw MuseError.invalid("The recording is incomplete.") }
            if name == "fmt " {
                guard length >= 16 else { throw MuseError.invalid("The recording format is incomplete.") }
                validFormat = word(start, 2) == 1 && word(start + 2, 2) == 1 && word(start + 4, 4) == 16000 && word(start + 14, 2) == 16
            }
            if name == "data" { audioBytes += length }
            offset = start + length + length % 2
        }
        guard validFormat, audioBytes >= 9600, audioBytes <= 16000 * 2 * 61 else { throw MuseError.invalid("Use mono 16 kHz, 16-bit WAV audio, between a moment and 60 seconds.") }
    }
    public static func body(_ data: Data, text: String, deviceID: String, sessionID: String) throws -> Data {
        try validateWAV(data)
        return try jsonData(["message": text, "device_id": deviceID, "session_id": sessionID, "output_modality": "text", "items": [["type": "file", "mime_type": "audio/wav", "filename": "voice_note.wav", "data_base64": data.base64EncodedString()]]])
    }
}
