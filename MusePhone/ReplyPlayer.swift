import AVFoundation
import Observation

@MainActor @Observable
final class ReplyPlayer: NSObject, AVAudioPlayerDelegate {
    var playingID: UUID?
    var error: String?
    private var loadedID: UUID?
    private var player: AVAudioPlayer?
    func toggle(_ audio: ReplyAudio, url: URL) {
        if playingID == audio.id { player?.pause(); playingID = nil; return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            if loadedID != audio.id {
                player?.stop(); player = try AVAudioPlayer(contentsOf: url); player?.delegate = self; loadedID = audio.id
            }
            guard player?.play() == true else { throw CocoaError(.fileReadUnknown) }
            playingID = audio.id; error = nil
        } catch { stop(); self.error = "Couldn’t play this reply." }
    }
    func stop() {
        player?.stop(); player = nil; loadedID = nil; playingID = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if self.player === player { self.stop() } }
    }
}
