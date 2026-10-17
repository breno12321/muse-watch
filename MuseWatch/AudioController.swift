import AVFoundation
import Observation
import WatchKit

@MainActor @Observable
final class AudioController: NSObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    var recording = false
    var requestingPermission = false
    var elapsed: TimeInterval = 0
    var level: Float = 0
    var playingFile: String?
    var playbackElapsed: TimeInterval = 0
    var playbackDuration: TimeInterval = 0
    var error: String?
    var finishedDraft: VoiceDraft?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var pausedFile: String?
    private var playbackMeter: Task<Void, Never>?
    private var playbackGeneration = UUID()
    private var recordingGeneration = UUID()
    private var meterTask: Task<Void, Never>?
    private var conversationID: UUID?
    private var fileName: String?

    func start(in id: UUID, directory: URL) async {
        guard !recording, !requestingPermission else { return }
        let generation = UUID(); recordingGeneration = generation
        stopPlayback(); error = nil; finishedDraft = nil; requestingPermission = true
        defer { if recordingGeneration == generation { requestingPermission = false } }
        let allowed = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in continuation.resume(returning: granted) }
        }
        guard recordingGeneration == generation, !Task.isCancelled else { return }
        guard allowed else { error = "Microphone access is off. Allow Muse Watch in your device’s microphone privacy settings to record a voice note."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default)
            try await session.activate()
            guard recordingGeneration == generation, !Task.isCancelled else { releaseSession(); return }
            let name = UUID().uuidString + ".wav"
            let recorder = try AVAudioRecorder(url: directory.appendingPathComponent(name), settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
            ])
            self.recorder = recorder; fileName = name; conversationID = id
            recorder.delegate = self; recorder.isMeteringEnabled = true
            guard recorder.record(forDuration: 60) else { throw CocoaError(.fileWriteUnknown) }
            elapsed = 0; recording = true
            WKInterfaceDevice.current().play(.start)
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.recording, let recorder = self.recorder else { return }
                    self.elapsed = recorder.currentTime
                    recorder.updateMeters()
                    self.level = max(0.05, pow(10, recorder.averagePower(forChannel: 0) / 30))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } catch { self.error = "Couldn’t start recording. \(error.localizedDescription)"; releaseSession() }
    }
    func stop() {
        recordingGeneration = UUID(); requestingPermission = false
        guard recording else { return }
        let duration = recorder?.currentTime ?? elapsed
        recording = false; meterTask?.cancel(); recorder?.stop()
        WKInterfaceDevice.current().play(.stop)
        finish(duration: duration)
    }
    private func finish(duration: TimeInterval) {
        guard let fileName, let conversationID else { return }
        if duration >= 0.3 {
            finishedDraft = VoiceDraft(file: fileName, duration: duration, conversationID: conversationID)
        } else {
            if let url = recorder?.url { try? FileManager.default.removeItem(at: url) }
            error = "That was a little short. Record for at least a moment."
        }
        self.fileName = nil; recorder = nil; releaseSession()
    }
    func play(_ file: String, url: URL) {
        guard !recording, !requestingPermission else { return }
        if playingFile == file {
            player?.pause(); playingFile = nil; pausedFile = file; playbackMeter?.cancel(); releaseSession(); return
        }
        let resume = pausedFile == file && player != nil
        if !resume { stopPlayback() }
        let generation = playbackGeneration
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await AVAudioSession.sharedInstance().activate()
                    guard self.playbackGeneration == generation else { return }
                    if !resume { self.player = try AVAudioPlayer(contentsOf: url); self.player?.delegate = self }
                    guard self.player?.play() == true else { throw CocoaError(.fileReadUnknown) }
                    self.playingFile = file; self.pausedFile = nil; self.playbackDuration = self.player?.duration ?? 0
                    self.playbackMeter = Task { [weak self] in
                        while !Task.isCancelled {
                            guard let self, self.playingFile == file else { return }
                            self.playbackElapsed = self.player?.currentTime ?? 0
                            try? await Task.sleep(for: .milliseconds(200))
                        }
                    }
                } catch { self.stopPlayback(); self.error = "Couldn’t play this audio. \(error.localizedDescription)" }
            }
        } catch { self.error = error.localizedDescription }
    }
    func stopPlayback() {
        playbackGeneration = UUID(); playbackMeter?.cancel(); playbackMeter = nil
        player?.stop(); player = nil; playingFile = nil; pausedFile = nil
        playbackElapsed = 0; playbackDuration = 0; releaseSession()
    }
    private func releaseSession() { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recording else { return }
            self.recording = false; self.meterTask?.cancel()
            if flag { self.finish(duration: self.elapsed) }
            else {
                try? FileManager.default.removeItem(at: recorder.url)
                self.fileName = nil; self.recorder = nil
                self.error = "Recording was interrupted. Please try again."; self.releaseSession()
            }
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if self.player === player { self.stopPlayback() } }
    }
}

private extension AVAudioSession {
    func activate() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            activate(options: []) { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: CocoaError(.featureUnsupported)) }
            }
        }
    }
}
