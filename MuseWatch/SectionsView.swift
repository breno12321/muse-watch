import SwiftUI

enum MuseSection: String, CaseIterable, Identifiable {
    case feed = "Check-in", ideas = "Ideas", goals = "Goals", library = "Library"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .feed: "sparkles"; case .ideas: "lightbulb"; case .goals: "checkmark.circle"; case .library: "bookmark" }
    }
    var subtitle: String {
        switch self { case .feed: "A moment with your Muse"; case .ideas: "Explore something together"; case .goals: "Find your next small step"; case .library: "Messages you’ve saved" }
    }
    var prompt: String {
        switch self {
        case .feed: "Give me a short personal check-in based on what you know about me."
        case .ideas: "Suggest one thoughtful idea for me to explore today, based on our conversations."
        case .goals: "Help me review my current goals and choose one small next step."
        case .library: ""
        }
    }
}
struct SectionsView: View {
    @State private var handledLaunch = false
    @State private var showInitialGoals = false
    var body: some View {
        List {
            ForEach(MuseSection.allCases) { section in
                NavigationLink { SectionDetailView(section: section) } label: { MuseRow(title: section.rawValue, subtitle: section.subtitle, symbol: section.symbol) }.listRowBackground(MuseStyle.bubble)
            }
            NavigationLink { AboutView() } label: { Label("Connection & about", systemImage: "info.circle").font(.caption2) }.listRowBackground(Color.clear)
        }.navigationTitle("Your Muse")
        .navigationDestination(isPresented: $showInitialGoals) { SectionDetailView(section: .goals) }
        .task {
            #if DEBUG
            guard !handledLaunch else { return }; handledLaunch = true
            showInitialGoals = ProcessInfo.processInfo.arguments.contains("--screen-goals")
            #endif
        }
    }
}
struct SectionDetailView: View {
    let section: MuseSection
    @Environment(MuseStore.self) private var store
    @State private var openChat = false
    private var chatID: UUID? { store.conversations.first { $0.title == section.rawValue }?.id }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if section == .library {
                    if store.savedMessages.isEmpty { Text("Tap the bookmark beside a chat message to keep it here.").font(.caption).foregroundStyle(MuseStyle.secondary) }
                    ForEach(store.savedMessages) { message in
                        if let chat = store.conversations.first(where: { $0.messages.contains(where: { $0.id == message.id }) }) { MessageBubble(message: message, conversationID: chat.id) }
                    }
                } else {
                    Image(systemName: section.symbol).font(.title2).foregroundStyle(MuseStyle.accent)
                    Text(section.subtitle).font(.headline)
                    Text("A conversation with \(store.museName), kept together here.").font(.caption2).foregroundStyle(MuseStyle.secondary)
                    if let id = chatID {
                        Button("Ask \(store.museName)") { Task { if await store.send(section.prompt, to: id) { openChat = true } } }.buttonStyle(.borderedProminent).disabled(!store.paired || store.sending.contains(id))
                        NavigationLink("Continue conversation") { ChatView(id: id) }
                    } else { Text("Open Muse Watch on your iPhone to sync.").font(.caption2) }
                }
            }.padding(.horizontal, 7).padding(.bottom, 14)
        }.navigationTitle(section.rawValue).navigationBarTitleDisplayMode(.inline)
        .watchEdgeBack()
        .navigationDestination(isPresented: $openChat) { if let id = chatID { ChatView(id: id) } }
    }
}
struct AboutView: View {
    @Environment(MuseStore.self) private var store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AvatarView(size: 52)
                Text("Muse, a little closer.").font(.headline)
                Text(store.phoneReachable ? "Your iPhone is reachable." : "Your iPhone is unavailable. Notes wait safely on this Watch.")
                Text(store.connectionStatus)
                if let date = store.lastSynced { Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))") }
                Button("Sync with iPhone") { store.refresh() }
                Text("Your Watch chats, voice notes, and Muse’s replies use the paired iPhone’s internet. Keep the iPhone app open if a reply takes longer than its background time allows.")
                Text("Ideas and Goals are conversations with Muse. Library contains your saved Watch messages. Earlier account chats and iOS section lists aren’t automatically imported.")
                Text("Choose a Muse avatar and name in the iPhone companion.")
            }.font(.caption2).foregroundStyle(MuseStyle.secondary).padding(8)
        }.navigationTitle("Connection")
        .watchEdgeBack()
    }
}
