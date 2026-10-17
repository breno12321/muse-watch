import SwiftUI

struct HomeView: View {
    @Environment(MuseStore.self) private var store
    @State private var composer: ComposerRoute?
    @State private var queuedChat: UUID?
    @State private var destination: ComposerRoute?
    @State private var greeting = false
    @State private var handledLaunch = false
    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ConnectionLabel()
                Button { withAnimation(.spring(duration: 0.4)) { greeting.toggle() } } label: {
                    AvatarView(size: 60).rotationEffect(.degrees(greeting ? -6 : 0))
                }.buttonStyle(.plain).accessibilityLabel("Say hello to your Muse")
                VStack(spacing: 3) {
                    Text(store.personName.isEmpty ? "Hello there." : "Hey, \(store.personName).").font(.system(.headline, design: .rounded, weight: .semibold))
                    Text(greeting ? "Here when you need me." : "Here for the little things.")
                        .font(.system(size: 11)).foregroundStyle(MuseStyle.secondary).multilineTextAlignment(.center)
                }
                if let id = store.mainID {
                    Button { composer = ComposerRoute(id: id) } label: {
                        Label(store.draft == nil ? "Talk to \(store.museName)" : "Review voice note", systemImage: store.draft == nil ? "mic.fill" : "waveform")
                            .font(.system(.body, design: .rounded, weight: .semibold)).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(!store.paired).accessibilityIdentifier("talkToCal")
                    NavigationLink { ChatView(id: id) } label: {
                        HStack { Text("Continue chat"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(.system(size: 13, weight: .medium)).padding(.horizontal, 5)
                    }.buttonStyle(.plain).padding(.top, 2).accessibilityIdentifier("continueChat")
                } else {
                    Text("Open Muse Watch on your iPhone to connect.").font(.caption2).foregroundStyle(MuseStyle.secondary).multilineTextAlignment(.center)
                    Button("Sync with iPhone") { store.refresh() }.buttonStyle(.borderedProminent)
                }
            }.padding(.horizontal, 9).padding(.bottom, 14)
        }
        .navigationTitle("muse").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $composer, onDismiss: {
            if let id = queuedChat { queuedChat = nil; destination = ComposerRoute(id: id) }
        }) { route in
            ComposerView(conversationID: route.id, onQueued: { queuedChat = $0 })
        }
        .navigationDestination(item: $destination) { route in ChatView(id: route.id) }
        .task {
            #if DEBUG
            guard !handledLaunch, let id = store.mainID else { return }
            handledLaunch = true
            // Test destinations must be pushed or presented from a real home screen.
            if ProcessInfo.processInfo.arguments.contains("--screen-chat") { destination = ComposerRoute(id: id) }
            else if ProcessInfo.processInfo.arguments.contains("--screen-voice") { composer = ComposerRoute(id: id) }
            #endif
        }
    }
}

struct ChatsView: View {
    @Environment(MuseStore.self) private var store
    var body: some View {
        List {
            Text("Pick up where you left off.").font(.caption2).foregroundStyle(MuseStyle.secondary).listRowBackground(Color.clear)
            ForEach(store.conversations) { chat in
                NavigationLink { ChatView(id: chat.id) } label: {
                    MuseRow(title: chat.title, subtitle: chat.messages.last?.text ?? "Start a conversation", symbol: chat.symbol)
                }.listRowBackground(MuseStyle.bubble)
            }
            ConnectionLabel().listRowBackground(Color.clear)
        }.navigationTitle("Chats")
    }
}

struct ComposerRoute: Identifiable, Hashable { let id: UUID }

#if DEBUG
#Preview("Cal · Home") {
    NavigationStack { HomeView() }
        .environment(MuseStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MuseHomePreview")))
        .environment(AudioController())
        .tint(MuseStyle.accent).preferredColorScheme(.dark)
}
#Preview("Your Muse · Sections") {
    NavigationStack { SectionsView() }
        .environment(MuseStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MuseSectionsPreview")))
        .environment(AudioController())
        .tint(MuseStyle.accent).preferredColorScheme(.dark)
}
#endif
