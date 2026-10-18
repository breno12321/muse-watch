import Foundation
import NaturalLanguage
import Misaki

public enum SpeechFailure: String, Error, LocalizedError {
    case englishOnly, empty, tooLong, pronunciation, assets
    public var errorDescription: String? {
        switch self {
        case .englishOnly: "Audio supports English replies only."
        case .empty: "This reply has no readable text for audio."
        case .tooLong: "This reply is too long for audio. Your text is saved."
        case .pronunciation: "Some text in this reply cannot be spoken in English."
        case .assets: "Audio resources are unavailable. Reinstall Muse Watch on iPhone."
        }
    }
}

struct SpeechText {
    static func clean(_ markdown: String) -> String {
        var fence: Character?, lines: [String] = []
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if fence == nil { fence = trimmed.first } else if fence == trimmed.first { fence = nil }
                continue
            }
            if fence == nil { lines.append(line) }
        }
        var text = lines.joined(separator: "\n")
        for (pattern, replacement) in [
            (#"!\[([^\]]*)\]\([^)]*\)"#, "$1"), (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),
            (#"https?://\S+"#, " "), (#"(?m)^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+|\d+[.)]\s+)"#, ""),
            (#"[`*_~]"#, ""), (#"\s+"#, " ")
        ] { text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func validate(_ text: String) throws {
        guard !text.isEmpty else { throw SpeechFailure.empty }
        guard text.utf8.count <= 64000 else { throw SpeechFailure.tooLong }
        // Short names/greetings are ambiguous. Reject confidently non-English prose.
        if text.split(whereSeparator: { $0.isWhitespace }).count >= 4 {
            let recognizer = NLLanguageRecognizer(); recognizer.processString(text)
            let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            if let dominant = recognizer.dominantLanguage, dominant != .english,
               (hypotheses[dominant] ?? 0) >= 0.8, (hypotheses[.english] ?? 0) < 0.2 { throw SpeechFailure.englishOnly }
        }
    }
}

final class EnglishPhonemizer {
    private let english: G2P
    // Kokoro-compatible American English letter names; unknown words remain audible.
    private static let letters = Dictionary(uniqueKeysWithValues: zip(Array("abcdefghijklmnopqrstuvwxyz"),
        ["ˈA", "bˈi", "sˈi", "dˈi", "ˈi", "ˈɛf", "ʤˈi", "ˈAʧ", "ˈI", "ʤˈA", "kˈA", "ˈɛl", "ˈɛm", "ˈɛn", "ˈO", "pˈi", "kjˈu", "ˈɑɹ", "ˈɛs", "tˈi", "jˈu", "vˈi", "dˈʌbəlju", "ˈɛks", "wˈI", "zˈi"]))
    init() throws { english = try G2P() }
    func phonemes(_ text: String) throws -> String {
        let result = english(text, preprocess: false)
        return try result.tokens.map { token in
            if let phonemes = token.phonemes, !phonemes.contains("❓") { return phonemes + token.whitespace }
            let folded = token.text.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US")).lowercased()
            let characters = folded.filter { !"'’‐-".contains($0) }
            guard !characters.isEmpty, characters.allSatisfy({ Self.letters[$0] != nil }) else { throw SpeechFailure.pronunciation }
            return characters.compactMap { Self.letters[$0] }.joined(separator: " ") + token.whitespace
        }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func chunks(_ markdown: String) throws -> [String] {
        guard markdown.utf8.count <= 64000 else { throw SpeechFailure.tooLong }
        let text = SpeechText.clean(markdown); try SpeechText.validate(text)
        let tokenizer = NLTokenizer(unit: .sentence); tokenizer.string = text
        var chunks: [String] = []
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            try Task.checkCancellation()
            let sentence = String(text[range]), spoken = try phonemes(sentence)
            if spoken.unicodeScalars.count <= 200 { if !spoken.isEmpty { chunks.append(spoken) }; continue }
            var pending = ""
            // Split phoneme output on word boundaries, including spelled unknown words.
            for word in spoken.split(separator: " ") {
                guard word.unicodeScalars.count <= 200 else { throw SpeechFailure.tooLong }
                let candidate = pending.isEmpty ? String(word) : pending + " " + word
                if candidate.unicodeScalars.count > 200 { chunks.append(pending); pending = String(word) }
                else { pending = candidate }
            }
            if !pending.isEmpty { chunks.append(pending) }
        }
        guard !chunks.isEmpty else { throw SpeechFailure.empty }
        return chunks
    }
}
