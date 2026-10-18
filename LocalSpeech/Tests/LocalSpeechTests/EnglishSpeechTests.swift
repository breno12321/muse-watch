import XCTest
@testable import LocalSpeech

final class EnglishSpeechTests: XCTestCase {
    func testMarkdownKeepsProseAndLabels() {
        XCTAssertEqual(SpeechText.clean("# Hello\n**Read** [this](https://example.com).\n```swift\ncode()\n```\nNext."), "Hello Read this. Next.")
        XCTAssertEqual(SpeechText.clean("Hello.\n~~~swift\nunclosed()"), "Hello.")
        XCTAssertEqual(SpeechText.clean("Visit https://example.com now."), "Visit now.")
    }
    func testUnknownNameIsSpelledWithoutDroppingKnownWords() throws {
        let phonemizer = try EnglishPhonemizer()
        let name = try phonemizer.phonemes("Breno")
        XCTAssertFalse(name.isEmpty); XCTAssertFalse(name.contains("❓"))
        XCTAssertTrue(name.contains("bˈi")); XCTAssertTrue(name.contains("ˈɛn"))
        XCTAssertTrue(try phonemizer.phonemes("Hello Breno.").contains(name))
        XCTAssertFalse(try phonemizer.phonemes("Qxzvpl").contains("❓"))
    }
    func testNumbersCurrencyAndChunkBounds() throws {
        let phonemizer = try EnglishPhonemizer()
        for text in ["It costs $25.50 at 3:30 PM.", "There are 1,234 items.", "Hello Breno, your next train leaves at 9:15."] {
            let chunks = try phonemizer.chunks(text)
            XCTAssertFalse(chunks.isEmpty); XCTAssertFalse(chunks.joined().contains("❓"))
        }
        let long = try phonemizer.chunks(String(repeating: "A comfortable sentence with an unfamiliar Qxzvpl name, ", count: 40) + "done.")
        XCTAssertGreaterThan(long.count, 1)
        XCTAssertTrue(long.allSatisfy { $0.unicodeScalars.count <= 200 })
    }
    func testUnsupportedAndEmptyTextFailsClearly() throws {
        let phonemizer = try EnglishPhonemizer()
        XCTAssertThrowsError(try phonemizer.chunks("```swift\nprint(1)\n```"))
        XCTAssertThrowsError(try phonemizer.chunks("Esta resposta está inteiramente em português e não deve ser lida em inglês."))
        XCTAssertThrowsError(try phonemizer.chunks(String(repeating: "word ", count: 14000)))
        XCTAssertThrowsError(try phonemizer.phonemes("你好"))
    }
    func testVoiceIndexAndStrictVocabulary() throws {
        let voice = VoicePack(data: (0..<(510 * 256)).map(Float.init))
        XCTAssertEqual(voice.styleTimbre(forTokenCount: 10)[0], 9 * 256)
        XCTAssertEqual(voice.styleS(forTokenCount: 10)[0], 9 * 256 + 128)
        XCTAssertThrowsError(try Vocab(map: ["a": 1]).tokens(for: "a?"))
    }
    func testActualSynthesisAndCache() async throws {
        guard let path = ProcessInfo.processInfo.environment["KOKORO_TEST_ASSETS"] else { throw XCTSkip("Set KOKORO_TEST_ASSETS to compiled local models for synthesis verification.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = SpeechWorker(assets: URL(fileURLWithPath: path), directory: directory)
        let key = String(repeating: "a", count: 64)
        let first = try await worker.generate(text: "Hello Breno. Your coffee costs $3.50. Have a lovely morning!", cacheKey: key)
        XCTAssertGreaterThan(first.duration, 1); XCTAssertLessThan(first.duration, 60)
        let bytes = try Data(contentsOf: first.file)
        let second = try await worker.generate(text: "Hello Breno. Your coffee costs $3.50. Have a lovely morning!", cacheKey: key)
        XCTAssertEqual(bytes, try Data(contentsOf: second.file))
        await worker.releaseModels()
    }
}
