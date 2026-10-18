import CoreML
import Foundation

/// Try CPU+ANE first; an unsupported stage may use CPU only, never GPU.
final class KokoroStage {
    private let url: URL
    private var model: MLModel
    private(set) var usesCPUFallback = false
    init(url: URL) throws {
        self.url = url
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuAndNeuralEngine
        do { model = try MLModel(contentsOf: url, configuration: configuration) }
        catch {
            configuration.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: url, configuration: configuration); usesCPUFallback = true
        }
    }
    func prediction(from features: MLFeatureProvider) throws -> MLFeatureProvider {
        do { return try model.prediction(from: features) }
        catch {
            guard !usesCPUFallback else { throw error }
            try Task.checkCancellation()
            let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
            model = try MLModel(contentsOf: url, configuration: configuration); usesCPUFallback = true
            return try model.prediction(from: features)
        }
    }
}
