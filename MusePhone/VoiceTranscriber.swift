import Foundation
import Speech

enum VoiceTranscriptionError: LocalizedError {
    case permission, unavailable, empty, timeout, cancelled, recognition(Int)
    var errorDescription: String? {
        switch self {
        case .permission: "Open Muse Watch on iPhone → Settings → Enable transcription. Allow Speech Recognition, then retry. Your recording is saved and nothing was sent."
        case .unavailable: "On-device transcription is unavailable for this language. Choose another voice language in iPhone Settings and retry. Your recording is saved; nothing was sent."
        case .empty: "No speech was recognized. Your recording is saved; nothing was sent. Check the voice language and tap Retry saved voice notes."
        case .timeout: "Transcription took too long. Open Muse Watch on iPhone and retry the saved voice note. Nothing was sent."
        case .cancelled: "Transcription paused. Open Muse Watch on iPhone and retry the saved voice note. Nothing was sent."
        case .recognition: "Couldn’t transcribe this recording. Your recording is saved; nothing was sent. Check the voice language and tap Retry saved voice notes on iPhone."
        }
    }
    var diagnostic: String {
        switch self {
        case .permission: "permission required"
        case .unavailable: "on-device recognizer unavailable"
        case .empty: "no speech recognized"
        case .timeout: "deadline exceeded"
        case .cancelled: "cancelled"
        case .recognition(let code): "recognizer error code \(code)"
        }
    }
}

/// Processes a saved Watch WAV locally. Never falls back to a network recognizer.
@MainActor final class VoiceTranscriber {
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var deadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<String, Error>?
    private var generation: UUID?

    static var authorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    static var permissionDenied: Bool {
        [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus())
    }
    static var locales: [Locale] {
        SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
    }
    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }
    func transcribe(_ url: URL, locale: String) async throws -> String {
        guard Self.authorized else { throw VoiceTranscriptionError.permission }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { throw VoiceTranscriptionError.unavailable }
        try Task.checkCancellation()
        let id = UUID()
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.addsPunctuation = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation; generation = id
                recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let finalText = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                    let errorCode = error.map { ($0 as NSError).code }
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        if let finalText {
                            let value = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                            self.finish(value.isEmpty ? .failure(VoiceTranscriptionError.empty) : .success(value))
                        } else if let errorCode { self.finish(.failure(VoiceTranscriptionError.recognition(errorCode))) }
                    }
                }
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(45)) } catch { return }
                    guard self?.generation == id else { return }
                    self?.finish(.failure(VoiceTranscriptionError.timeout))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == id else { return }
                self?.cancel()
            }
        }
    }
    func cancel() { finish(.failure(VoiceTranscriptionError.cancelled)) }
    private func finish(_ result: Result<String, Error>) {
        let waiting = continuation
        continuation = nil; generation = nil
        deadline?.cancel(); deadline = nil
        recognition?.cancel(); recognition = nil; recognizer = nil
        waiting?.resume(with: result)
    }
}
