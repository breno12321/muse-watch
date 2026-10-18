// Adapted from laishere/kokoro-coreml, Apache-2.0. See NOTICE.md.
import Foundation
import CoreML

struct StageTimings: Codable {
    var cpuFallbackStages: [String] = []
    var albertMs: Double = 0
    var postAlbertMs: Double = 0
    var alignmentMs: Double = 0
    var prosodyMs: Double = 0
    var noiseMs: Double = 0
    var vocoderMs: Double = 0
    var tailMs: Double = 0
    var totalMs: Double {
        albertMs + postAlbertMs + alignmentMs + prosodyMs + noiseMs + vocoderMs + tailMs
    }
}

struct SynthResult {
    let audio: [Float]
    let stages: StageTimings
    let tEnc: Int     // input_ids count (phonemes + 2 BOS/EOS)
    let tA: Int       // acoustic frames
    var audioSec: Double { Double(audio.count) / 24000.0 }
    var speed: Double { audioSec / (stages.totalMs / 1000.0) }
}

enum KokoroError: Error, LocalizedError {
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name): return "Model not found: \(name)"
        }
    }
}

final class KokoroEngine {
    private let albert: KokoroStage
    private let postAlbert: KokoroStage
    private let alignment: KokoroStage
    private let prosody: KokoroStage
    private let noise: KokoroStage
    private let vocoder: KokoroStage
    private let tail: KokoroStage
    let vocab: Vocab

    init(assets: URL) throws {
        func load(_ name: String) throws -> KokoroStage {
            let url = assets.appendingPathComponent(name + ".mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw KokoroError.modelNotFound(name)
            }
            return try KokoroStage(url: url)
        }
        self.albert = try load("KokoroAlbert")
        self.postAlbert = try load("KokoroPostAlbert")
        self.alignment = try load("KokoroAlignment")
        self.prosody = try load("KokoroProsody")
        self.noise = try load("KokoroNoise")
        self.vocoder = try load("KokoroVocoder")
        self.tail = try load("KokoroTail")
        self.vocab = try Vocab.load(assets: assets)
    }

    func synthesize(phonemes: String, voice: VoicePack, speed: Float = 1.0) throws -> SynthResult {
        try Task.checkCancellation()
        let inputIds = try vocab.tokens(for: phonemes)
        let T = inputIds.count
        let styleS = voice.styleS(forTokenCount: T - 2)
        let styleTimbre = voice.styleTimbre(forTokenCount: T - 2)
        let mask = [Int32](repeating: 1, count: T)

        var stages = StageTimings()

        // 1. ALBERT
        var t0 = CFAbsoluteTimeGetCurrent()
        let o1 = try albert.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": makeInt32Array(inputIds, shape: [1, T]),
            "attention_mask": makeInt32Array(mask, shape: [1, T]),
        ]))
        let bertDur = o1.featureValue(for: "bert_dur")!.multiArrayValue!
        stages.albertMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        try Task.checkCancellation()
        // 2. PostAlbert
        t0 = CFAbsoluteTimeGetCurrent()
        let o2 = try postAlbert.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "bert_dur": bertDur,
            "input_ids": makeInt32Array(inputIds, shape: [1, T]),
            "style_s": makeFloat16Array(styleS, shape: [1, 128]),
            "speed": makeFloat16Array([speed], shape: [1]),
            "attention_mask": makeInt32Array(mask, shape: [1, T]),
        ]))
        let durationArr = o2.featureValue(for: "duration")!.multiArrayValue!
        let dArr = o2.featureValue(for: "d")!.multiArrayValue!
        let tEnArr = o2.featureValue(for: "t_en")!.multiArrayValue!
        stages.postAlbertMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        try Task.checkCancellation()
        // 3. Alignment
        t0 = CFAbsoluteTimeGetCurrent()
        let durFloats = toFloats(durationArr)
        var predDur = [Int32](repeating: 0, count: T)
        for i in 0..<T { predDur[i] = max(1, Int32(durFloats[i].rounded())) }

        guard predDur.reduce(0, +) <= 2000 else { throw LabError.invalid("Acoustic frame limit exceeded; split the sentence.") }
        let o3 = try alignment.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "pred_dur": makeInt32Array(predDur, shape: [1, T]),
            "d": dArr,
            "t_en": tEnArr,
        ]))
        let enArr = o3.featureValue(for: "en")!.multiArrayValue!
        let asrArr = o3.featureValue(for: "asr")!.multiArrayValue!
        stages.alignmentMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        try Task.checkCancellation()
        // 4. Prosody
        t0 = CFAbsoluteTimeGetCurrent()
        let o4 = try prosody.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "en": enArr,
            "style_s": makeFloat16Array(styleS, shape: [1, 128]),
        ]))
        let f0Arr = o4.featureValue(for: "F0")!.multiArrayValue!
        let nArr = o4.featureValue(for: "N")!.multiArrayValue!
        stages.prosodyMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        try Task.checkCancellation()
        // 5. Noise (fp32)
        t0 = CFAbsoluteTimeGetCurrent()
        let f0Floats = toFloats(f0Arr)
        let o5 = try noise.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "F0_curve": makeFloatArray(f0Floats, shape: [1, f0Floats.count]),
            "style_timbre": makeFloatArray(styleTimbre, shape: [1, 128]),
        ]))
        let xs0 = o5.featureValue(for: "x_source_0")!.multiArrayValue!
        let xs1 = o5.featureValue(for: "x_source_1")!.multiArrayValue!
        stages.noiseMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        try Task.checkCancellation()
        // 6. Vocoder (dual output: anchor + x_pre on ANE)
        t0 = CFAbsoluteTimeGetCurrent()
        let o6 = try vocoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "asr": asrArr,
            "F0_curve": f0Arr,
            "N_pred": nArr,
            "x_source_0": xs0,
            "x_source_1": xs1,
            "style_timbre": makeFloat16Array(styleTimbre, shape: [1, 128]),
        ]))
        stages.vocoderMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        try Task.checkCancellation()
        // 7. Tail (fp32 conv_post + exp + sin + iSTFT). Discard vocoder anchor.
        t0 = CFAbsoluteTimeGetCurrent()
        let xPre = o6.featureValue(for: "x_pre")!.multiArrayValue!
        let xPreFloats = toFloats(xPre)
        let xPreF32 = makeFloatArray(xPreFloats, shape: [1, 128, xPre.shape[2].intValue])
        let oTail = try tail.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "x_pre": xPreF32,
        ]))
        let audio = toFloats(oTail.featureValue(for: "audio")!.multiArrayValue!)
        guard !audio.isEmpty, audio.allSatisfy(\.isFinite) else { throw LabError.invalid("Invalid model audio.") }
        stages.tailMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        stages.cpuFallbackStages = [("albert", albert), ("postAlbert", postAlbert), ("alignment", alignment), ("prosody", prosody), ("noise", noise), ("vocoder", vocoder), ("tail", tail)].filter { $0.1.usesCPUFallback }.map { $0.0 }
        let tA = asrArr.shape.last?.intValue ?? 0
        return SynthResult(audio: audio, stages: stages, tEnc: T, tA: tA)
    }
}
