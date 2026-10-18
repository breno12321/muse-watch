import Foundation
import AVFoundation

public struct SpeechOutput: Sendable { public let file: URL; public let duration: Double }

public actor SpeechWorker {
    private let assets: URL
    private let directory: URL
    private var engine: KokoroEngine?
    private var phonemizer: EnglishPhonemizer?
    public init(assets: URL, directory: URL) { self.assets = assets; self.directory = directory }
    public func releaseModels() { engine = nil; phonemizer = nil }
    public func generate(text: String, cacheKey: String) throws -> SpeechOutput {
        try Task.checkCancellation()
        guard cacheKey.count == 64, cacheKey.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw SpeechFailure.assets }
        let folder = directory.appendingPathComponent(cacheKey, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        #endif
        let output = folder.appendingPathComponent("speech.m4a")
        if let cached = try? Self.inspect(output) { return cached }
        try? FileManager.default.removeItem(at: output)
        if phonemizer == nil { phonemizer = try EnglishPhonemizer() }
        let chunks = try phonemizer!.chunks(text)
        if engine == nil { engine = try KokoroEngine(assets: assets) }
        let voice = try VoicePack.load(name: "af_heart", assets: assets)
        var samples: [Float] = []
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let checkpoint = folder.appendingPathComponent("chunk-\(index).pcm")
            let audio: [Float]
            if let bytes = try? Data(contentsOf: checkpoint), !bytes.isEmpty, bytes.count % 4 == 0, bytes.count <= 24000 * 300 * 4 {
                audio = bytes.withUnsafeBytes { raw in stride(from: 0, to: raw.count, by: 4).map { raw.loadUnaligned(fromByteOffset: $0, as: Float.self) } }
            } else {
                audio = try engine!.synthesize(phonemes: chunk, voice: voice).audio
                try audio.withUnsafeBytes { Data($0) }.write(to: checkpoint, options: .atomic)
            }
            let silence = index < chunks.count - 1 ? 2400 : 0
            guard audio.allSatisfy(\.isFinite), samples.count + audio.count + silence <= 24000 * 300 else { throw SpeechFailure.tooLong }
            samples += audio; samples += Array(repeating: 0, count: silence)
        }
        try Task.checkCancellation()
        let temporary = folder.appendingPathComponent("encoding.m4a")
        try? FileManager.default.removeItem(at: temporary)
        try Self.encode(samples, to: temporary)
        _ = try Self.inspect(temporary)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: output)
        // Completed PCM is expendable once the bounded encoded file exists.
        for index in chunks.indices { try? FileManager.default.removeItem(at: folder.appendingPathComponent("chunk-\(index).pcm")) }
        return SpeechOutput(file: output, duration: Double(samples.count) / 24000)
    }
    private static func inspect(_ url: URL) throws -> SpeechOutput {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 3 * 1024 * 1024 else { throw SpeechFailure.tooLong }
        let player = try AVAudioPlayer(contentsOf: url)
        guard player.duration.isFinite, player.duration > 0, player.duration <= 300.1 else { throw SpeechFailure.tooLong }
        return SpeechOutput(file: url, duration: player.duration)
    }
    private static func encode(_ samples: [Float], to url: URL) throws {
        guard !samples.isEmpty else { throw SpeechFailure.empty }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000])
        try file.write(from: buffer)
    }
}
