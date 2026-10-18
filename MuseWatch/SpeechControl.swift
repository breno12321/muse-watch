import SwiftUI

struct SpeechControl: View {
    let message: Message
    let conversationID: UUID
    @Environment(MuseStore.self) private var store
    @Environment(AudioController.self) private var audio
    private var isPending: Bool { message.speechPending != nil && !message.speechRejected }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let file = message.speechFile, !isPending {
                Button {
                    store.protectedSpeechFile = file
                    audio.play(file, url: store.audioURL(file))
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: audio.playingFile == file ? "pause.fill" : "play.fill")
                        Text(audio.playingFile == file ? "Pause audio" : (audio.playbackFile == file ? "Resume audio" : "Play audio"))
                        Spacer(minLength: 0)
                        Text(audioTime(message.localSpeech?.audio?.duration ?? 0)).monospacedDigit().font(.caption2)
                    }.frame(minHeight: 36)
                }.accessibilityIdentifier("playGeneratedSpeech")
                if audio.playbackFile == file {
                    ProgressView(value: min(audio.playbackElapsed, max(audio.playbackDuration, 1)), total: max(audio.playbackDuration, 1)).tint(MuseStyle.accent)
                    Text("\(audioTime(audio.playbackElapsed)) / \(audioTime(audio.playbackDuration))").monospacedDigit().font(.caption2)
                }
            } else if isPending {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if let pending = message.speechPending, context.date.timeIntervalSince(pending.createdAt) > 45 {
                        Text("Open Muse Watch on iPhone to continue.").font(.caption2).foregroundStyle(.orange)
                        Button("Retry connection") { store.retryPendingSpeech(message) }.frame(minHeight: 36)
                    } else { waiting("Waiting for iPhone…") }
                }
            } else if let status = message.localSpeech, status.pending {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if context.date.timeIntervalSince(status.updatedAt) > 45 {
                        Text("Open Muse Watch on iPhone to continue.").font(.caption2).foregroundStyle(.orange)
                        Button("Retry audio") { store.generateSpeech(message, in: conversationID) }.frame(minHeight: 36)
                    } else { waiting(status.phase == .generating ? "Generating on iPhone…" : "Queued on iPhone…") }
                }
            } else {
                if message.speechRejected {
                    Text("Sync with iPhone, then retry audio.").font(.caption2).foregroundStyle(.orange)
                } else if let detail = message.localSpeech?.detail {
                    Text(detail).font(.caption2).foregroundStyle(.orange)
                } else if message.localSpeech?.phase == .ready {
                    Text("Sending to Watch…").font(.caption2).foregroundStyle(MuseStyle.secondary)
                }
                if message.localSpeech?.retryable != false || message.speechRejected {
                    Button {
                        store.generateSpeech(message, in: conversationID)
                    } label: {
                        Label(message.localSpeech == nil && !message.speechRejected ? "Generate audio" : "Retry audio", systemImage: "waveform")
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    }.accessibilityIdentifier("generateSpeech")
                }
            }
            Text("English · Generated on iPhone").font(.system(size: 9)).foregroundStyle(MuseStyle.secondary)
        }
        .font(.caption).buttonStyle(.plain)
        .disabled(audio.recording || audio.requestingPermission)
    }
    private func waiting(_ label: String) -> some View {
        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(label) }
            .font(.caption2).foregroundStyle(MuseStyle.secondary).accessibilityElement(children: .combine)
    }
}
