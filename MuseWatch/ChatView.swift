import SwiftUI

struct ChatView: View {
    let id: UUID
    @Environment(MuseStore.self) private var store
    @State private var composer: ComposerRoute?
    @State private var queuedChat: UUID?
    @State private var destination: ComposerRoute?
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.conversation(id)?.messages.isEmpty == true {
                        Text("Tap the microphone to share a thought. Your Muse replies here.").font(.caption2).foregroundStyle(MuseStyle.secondary).padding(.vertical)
                    }
                    ForEach(store.conversation(id)?.messages ?? []) { message in
                        MessageBubble(message: message, conversationID: id).id(message.id)
                    }
                    if store.sending.contains(id) {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Waiting for \(store.museName)…").font(.caption2) }
                            .foregroundStyle(MuseStyle.secondary).accessibilityLabel("Waiting for your Muse")
                    }
                    Color.clear.frame(height: 1).id("latest")
                }.padding(.horizontal, 3).padding(.bottom, 4)
            }
            .task {
                store.read(id)
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo("latest", anchor: .bottom)
            }
            .onChange(of: store.conversation(id)?.messages.count) { _, _ in withAnimation { proxy.scrollTo("latest", anchor: .bottom) } }
        }
        .navigationTitle(store.conversation(id)?.title ?? "Chat").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .watchEdgeBack(enabled: composer == nil)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { composer = ComposerRoute(id: id) } label: {
                    Image(systemName: store.draft == nil ? "mic.fill" : "waveform")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                }.disabled(!store.paired)
                    .accessibilityLabel(store.draft == nil ? "Record a voice message" : "Review voice note")
                    .accessibilityIdentifier("recordVoice")
            }
        }
        .sheet(item: $composer, onDismiss: {
            if let target = queuedChat {
                queuedChat = nil
                if target != id { destination = ComposerRoute(id: target) }
            }
        }) { route in ComposerView(conversationID: route.id, onQueued: { queuedChat = $0 }) }
        .navigationDestination(item: $destination) { route in ChatView(id: route.id) }
    }
}

struct MessageBubble: View {
    let message: Message
    let conversationID: UUID
    @Environment(MuseStore.self) private var store
    @Environment(AudioController.self) private var audio
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(message.role == .muse ? store.museName.uppercased() : "YOU").font(.system(size: 9, weight: .semibold)).tracking(1)
                Spacer()
                Button { store.toggleSaved(message.id, in: conversationID) } label: {
                    Image(systemName: message.saved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 12)).frame(width: 28, height: 28)
                }.buttonStyle(.plain).accessibilityLabel(message.saved ? "Unsave message" : "Save message to Saved messages")
            }.foregroundStyle(MuseStyle.secondary)
            if message.role == .muse, !message.text.isEmpty {
                MuseRichText(text: message.text).font(.system(size: 15))
            }
            if message.role == .user, message.audioFile != nil, message.text != "Voice note", !message.text.isEmpty {
                Text(verbatim: message.text).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            }
            if let file = message.audioFile, message.role == .user {
                Button { audio.play(file, url: store.audioURL(file)) } label: {
                    HStack {
                        Image(systemName: audio.playingFile == file ? "pause.fill" : "play.fill")
                        Image(systemName: "waveform").font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            if message.role == .muse { Text(audio.playingFile == file ? "Pause reply" : "Play reply").font(.caption) }
                            Text(audio.playingFile == file ? "\(audioTime(audio.playbackElapsed)) / \(audioTime(message.duration ?? 0))" : audioTime(message.duration ?? 0)).monospacedDigit().font(.caption2)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("\(audio.playingFile == file ? "Pause" : "Play") \(message.role == .muse ? "Muse reply" : "voice note"), \(audioTime(message.duration ?? 0))")
                    .accessibilityIdentifier(message.role == .muse ? "playMuseReply" : "playVoiceNote")
                if audio.playingFile == file {
                    ProgressView(value: min(audio.playbackElapsed, max(audio.playbackDuration, 1)), total: max(audio.playbackDuration, 1)).tint(MuseStyle.accent)
                }
            } else if message.role == .user {
                Text(verbatim: message.text).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true)
            }
            if let delivery = message.delivery {
                Text(delivery.label).font(.system(size: 10)).foregroundStyle(delivery == .uncertain || delivery == .failed ? .orange : MuseStyle.secondary)
            }
            if let detail = message.detail, message.role == .user { Text(detail).font(.system(size: 11)).foregroundStyle(.orange) }
            Text(message.date, style: .time).font(.system(size: 9)).foregroundStyle(MuseStyle.secondary)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.role == .user ? MuseStyle.userBubble : MuseStyle.bubble, in: RoundedRectangle(cornerRadius: 17))
            .padding(.leading, message.role == .user ? 10 : 0)

    }
}
