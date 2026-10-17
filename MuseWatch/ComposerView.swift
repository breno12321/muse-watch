import SwiftUI

struct ComposerView: View {
    let conversationID: UUID
    var onQueued: ((UUID) -> Void)? = nil
    @Environment(MuseStore.self) private var store
    @Environment(AudioController.self) private var audio
    @Environment(\.dismiss) private var dismiss
    @State private var sending = false
    @State private var attemptedStart = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    if let draft = store.draft {
                        AvatarView(size: 32)
                        Text("Ready when you are.").font(.system(size: 14, weight: .semibold, design: .rounded))
                        Button { audio.play(draft.file, url: store.audioURL(draft.file)) } label: {
                            Label(audioTime(draft.duration), systemImage: audio.playingFile == draft.file ? "pause.fill" : "play.fill")
                                .monospacedDigit().frame(maxWidth: .infinity)
                        }.accessibilityLabel("Preview voice note")
                        if draft.conversationID != conversationID {
                            Text("Draft for \(store.conversation(draft.conversationID)?.title ?? "another chat")").font(.caption2).foregroundStyle(MuseStyle.secondary)
                        }
                        Button {
                            audio.stopPlayback(); sending = true
                            Task {
                                let queued = await store.sendVoice(); sending = false
                                if queued { onQueued?(draft.conversationID); dismiss() }
                            }
                        } label: {
                            if sending { ProgressView() } else { Label("Send voice note", systemImage: "arrow.up") }
                        }.buttonStyle(.borderedProminent).disabled(sending || !store.paired).accessibilityIdentifier("sendVoiceNote")
                        Button("Discard", role: .destructive) { audio.stopPlayback(); store.discardDraft() }.disabled(sending)
                    } else {
                        Text(audio.recording ? "I’m listening." : "Ready when you are.")
                            .font(.system(size: 14, weight: .semibold, design: .rounded)).multilineTextAlignment(.center)
                        if audio.recording {
                            WaveformView(level: audio.level).frame(height: 36).padding(.vertical, 5)
                            Text(audioTime(audio.elapsed)).monospacedDigit().font(.system(.title2, design: .rounded))
                                .contentTransition(.numericText())
                        } else if audio.requestingPermission {
                            ProgressView("Starting…").font(.caption2).padding(.vertical, 12)
                        } else {
                            Text("A thought, an idea, anything.").font(.caption2).foregroundStyle(MuseStyle.secondary)
                        }
                        Button {
                            if audio.recording { finishRecording() }
                            else { Task { await audio.start(in: conversationID, directory: store.audioURL("")) } }
                        } label: {
                            Label(audio.recording ? "Stop recording" : "Start recording", systemImage: audio.recording ? "stop.fill" : "mic.fill")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).tint(audio.recording ? .red : MuseStyle.accent)
                            .disabled(audio.requestingPermission).accessibilityIdentifier("toggleRecording")
                        Text(audio.recording ? "Up to 60 seconds. Review before sending." : "Microphone access is needed to record.")
                            .font(.system(size: 10)).foregroundStyle(MuseStyle.secondary).multilineTextAlignment(.center)
                    }
                    Text("Through your iPhone to Muse").font(.system(size: 10)).foregroundStyle(MuseStyle.secondary)
                }.padding(.horizontal, 7).padding(.bottom, 12)
            }.navigationTitle(audio.recording ? "Recording" : "Voice note").navigationBarTitleDisplayMode(.inline)
        }.interactiveDismissDisabled(audio.recording || sending)
            .task {
                guard !attemptedStart else { return }; attemptedStart = true
                if store.draft == nil { await audio.start(in: conversationID, directory: store.audioURL("")) }
            }
            .onDisappear { finishRecording(); audio.stopPlayback() }
    }
    private func finishRecording() {
        audio.stop()
        if let draft = audio.finishedDraft { store.keepDraft(draft); audio.finishedDraft = nil }
    }
}

struct WaveformView: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<21) { index in
                    let wave = 0.5 + 0.5 * sin(time * 8 + Double(index) * 0.65)
                    let envelope = 1 - abs(Double(index - 10)) / 14
                    let amplitude = min(1, max(0, Double(level)))
                    Capsule().fill(MuseStyle.accent.opacity(0.65 + wave * 0.35))
                        .frame(width: 3, height: 4 + (5 + amplitude * 27) * wave * envelope)
                }
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Recording audio")
    }
}
