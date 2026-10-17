import SwiftUI

struct HomeView: View {
    @Environment(MuseStore.self) private var store
    @State private var composer: ComposerRoute?
    @State private var queuedChat: UUID?
    @State private var destination: ComposerRoute?
    @State private var showChats = false
    @State private var handledLaunch = false
    var body: some View {
        ScrollView {
            VStack(spacing: 7) {
                HStack(spacing: 8) {
                    AvatarView(size: 38)
                    Text(store.museName).font(.system(.headline, design: .rounded, weight: .semibold)).lineLimit(1)
                }
                if let id = store.voiceChatID {
                    Button { composer = ComposerRoute(id: id) } label: {
                        Label(store.draft == nil ? "Voice note" : "Review voice note", systemImage: store.draft == nil ? "mic.fill" : "waveform")
                            .font(.system(.body, design: .rounded, weight: .semibold)).frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).disabled(!store.paired).accessibilityIdentifier("talkToCal")
                    Text("To \(store.conversation(id)?.title ?? "your chat")")
                        .font(.caption2).foregroundStyle(MuseStyle.secondary).lineLimit(1)
                } else {
                    Text(store.paired ? "Open Chats to start a new conversation." : "Open Muse Watch on your iPhone to connect.").font(.caption2).foregroundStyle(MuseStyle.secondary).multilineTextAlignment(.center)
                    if !store.paired { Button("Sync with iPhone") { store.refresh() }.buttonStyle(.borderedProminent) }
                }
                NavigationLink { ChatsView() } label: {
                    Label("Chats", systemImage: "bubble.left.and.bubble.right").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).accessibilityIdentifier("openChats")
                ConnectionLabel()
            }.padding(.horizontal, 9).padding(.bottom, 14)
        }
        .navigationTitle("muse").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { AboutView() } label: {
                    Image(systemName: "gearshape").symbolRenderingMode(.monochrome).foregroundStyle(.white)
                }
                    .accessibilityLabel("Connection and settings")
            }
        }
        .sheet(item: $composer, onDismiss: {
            if let id = queuedChat { queuedChat = nil; destination = ComposerRoute(id: id) }
        }) { route in
            ComposerView(conversationID: route.id, onQueued: { queuedChat = $0 })
        }
        .navigationDestination(item: $destination) { route in ChatView(id: route.id) }
        .navigationDestination(isPresented: $showChats) { ChatsView() }
        .task {
            #if DEBUG
            guard !handledLaunch else { return }
            handledLaunch = true
            if ProcessInfo.processInfo.arguments.contains("--screen-chats") { showChats = true }
            guard let id = store.voiceChatID else { return }
            // Test destinations must be pushed or presented from a real home screen.
            if ProcessInfo.processInfo.arguments.contains("--screen-chat") { destination = ComposerRoute(id: id) }
            else if ProcessInfo.processInfo.arguments.contains("--screen-voice") { composer = ComposerRoute(id: id) }
            #endif
        }
    }
}

struct ChatsView: View {
    @Environment(MuseStore.self) private var store
    @State private var destination: ComposerRoute?
    @State private var deleting: Conversation?
    @State private var renaming: Conversation?
    var body: some View {
        List {
            Button {
                if let id = store.createChat() { destination = ComposerRoute(id: id) }
            } label: { Label("New chat", systemImage: "plus.bubble") }
                .disabled(!store.paired).accessibilityIdentifier("newChat")
                .listRowBackground(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MuseStyle.bubble))
            ForEach(store.orderedChats) { chat in
                NavigationLink { ChatView(id: chat.id) } label: {
                    MuseRow(title: chat.title, subtitle: chat.messages.last?.text ?? "Start with a voice note", symbol: store.isPinned(chat.id) ? "pin.fill" : chat.symbol)
                }.listRowBackground(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(MuseStyle.bubble))
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    pinButton(chat)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    deleteButton(chat)
                    Button { renaming = chat } label: { Label("Rename", systemImage: "pencil") }
                        .tint(.blue).accessibilityIdentifier("renameWatchChat")
                    pinButton(chat)
                }
            }
        }.navigationTitle("Chats")
        .watchEdgeBack()
        .navigationDestination(item: $destination) { route in ChatView(id: route.id) }
        .sheet(item: $renaming) { chat in WatchRenameChatView(chatID: chat.id, initialTitle: chat.title) }
        .confirmationDialog("Delete chat from Watch?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible, presenting: deleting) { chat in
            Button("Delete from Watch", role: .destructive) { store.deleteChat(chat.id); deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { _ in
            Text("Your iPhone and Muse copies stay available.")
        }
    }
    private func pinButton(_ chat: Conversation) -> some View {
        Button { store.togglePinned(chat.id) } label: {
            Label(store.isPinned(chat.id) ? "Unpin" : "Pin", systemImage: store.isPinned(chat.id) ? "pin.slash" : "pin")
        }.tint(.orange).accessibilityIdentifier("pinChat")
    }
    private func deleteButton(_ chat: Conversation) -> some View {
        Button(role: .destructive) {
            if let reason = store.deletionBlockReason(chat.id) { store.error = reason }
            else { deleting = chat }
        } label: { Label("Delete", systemImage: "trash") }
            .accessibilityIdentifier("deleteChat")
    }
}

struct WatchRenameChatView: View {
    let chatID: UUID
    @Environment(MuseStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var error: String?
    init(chatID: UUID, initialTitle: String) { self.chatID = chatID; _title = State(initialValue: initialTitle) }
    var body: some View {
        NavigationStack {
            Form {
                TextField("Chat name", text: $title).autocorrectionDisabled().onSubmit { save() }
                    .accessibilityIdentifier("watchChatNameField")
                Button("Save name") { save() }.foregroundStyle(.white).buttonStyle(.borderedProminent)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 80)
                    .accessibilityIdentifier("saveWatchChatName")
                if let error { Text(error).font(.caption2).foregroundStyle(.red) }
                Text("Tap the name to dictate. Saves on Watch and syncs to iPhone when available.")
                    .font(.caption2).foregroundStyle(MuseStyle.secondary)
            }.navigationTitle("Rename chat")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
    private func save() {
        if store.renameChat(chatID, title: title) { dismiss() }
        else { error = store.error ?? "Couldn’t save this chat name."; store.error = nil }
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
#Preview("Chats") {
    NavigationStack { ChatsView() }
        .environment(MuseStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MuseChatsPreview")))
        .environment(AudioController())
        .tint(MuseStyle.accent).preferredColorScheme(.dark)
}
#endif
