import Foundation
import CoreML

enum LabError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct VoicePack {
    let data: [Float]
    static func load(name: String, assets: URL) throws -> VoicePack {
        guard name == "af_heart" else { throw LabError.invalid("Unsupported voice.") }
        let bytes = try Data(contentsOf: assets.appendingPathComponent(name + ".bin"))
        guard bytes.count == 510 * 256 * 4 else { throw LabError.invalid("Invalid voice shape.") }
        var floats = [Float](repeating: 0, count: 510 * 256)
        _ = floats.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        guard floats.allSatisfy(\.isFinite) else { throw LabError.invalid("Invalid voice values.") }
        return VoicePack(data: floats)
    }
    // Python reference indexes by phoneme count - 1, excluding BOS/EOS.
    func styleS(forTokenCount count: Int) -> [Float] { row(count, offset: 128) }
    func styleTimbre(forTokenCount count: Int) -> [Float] { row(count, offset: 0) }
    private func row(_ count: Int, offset: Int) -> [Float] {
        let start = min(max(count - 1, 0), 509) * 256 + offset
        return Array(data[start..<start + 128])
    }
}
struct Vocab {
    let map: [String: Int]
    static func load(assets: URL) throws -> Vocab {
        Vocab(map: try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: assets.appendingPathComponent("vocab.json"))))
    }
    func tokens(for phonemes: String) throws -> [Int32] {
        // Iterate Unicode scalars: Portuguese nasalization may form combining graphemes.
        let ids = try phonemes.unicodeScalars.map { scalar -> Int32 in
            guard let id = map[String(scalar)], id > 0, id < 1000 else { throw LabError.invalid("Unmapped phoneme; refusing to silently omit speech.") }
            return Int32(id)
        }
        guard !ids.isEmpty, ids.count <= 510 else { throw LabError.invalid("Phoneme length outside model bounds.") }
        return [0] + ids + [0]
    }
}

// Input tensors are contiguous. Output conversion honors Core ML strides.
func makeFloatArray(_ values: [Float], shape: [Int]) -> MLMultiArray { makeArray(values.map(NSNumber.init), shape: shape, type: .float32) }
func makeFloat16Array(_ values: [Float], shape: [Int]) -> MLMultiArray { makeArray(values.map(NSNumber.init), shape: shape, type: .float16) }
func makeInt32Array(_ values: [Int32], shape: [Int]) -> MLMultiArray { makeArray(values.map(NSNumber.init), shape: shape, type: .int32) }
private func makeArray(_ values: [NSNumber], shape: [Int], type: MLMultiArrayDataType) -> MLMultiArray {
    precondition(shape.reduce(1, *) == values.count)
    let result = try! MLMultiArray(shape: shape.map(NSNumber.init), dataType: type)
    for (i, value) in values.enumerated() { result[i] = value }
    return result
}
func toFloats(_ array: MLMultiArray) -> [Float] { (0..<array.count).map { array[$0].floatValue } }
