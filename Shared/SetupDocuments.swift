import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let museRequest = UTType(exportedAs: "dev.breno.musewatch.setup-request", conformingTo: .json)
    static let musePair = UTType(exportedAs: "dev.breno.musewatch.setup-credentials", conformingTo: .json)
}
struct SetupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.museRequest, .musePair, .json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents, bytes.count <= 131072 else { throw MuseError.invalid("Invalid setup file.") }; data = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
func readSetupFile(_ url: URL) throws -> Data {
    guard url.isFileURL else { throw MuseError.invalid("Choose a local setup file.") }
    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size > 0, size <= 131072 else { throw MuseError.invalid("Setup file is empty or too large.") }
    return try Data(contentsOf: url)
}
