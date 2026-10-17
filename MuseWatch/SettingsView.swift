import SwiftUI

struct SavedMessagesView: View {
    @Environment(MuseStore.self) private var store
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if store.savedMessages.isEmpty {
                    Text("Tap the bookmark beside a message to save it here.")
                        .font(.caption).foregroundStyle(MuseStyle.secondary)
                }
                ForEach(store.savedMessages) { message in
                    if let chat = store.conversations.first(where: { $0.messages.contains(where: { $0.id == message.id }) }) {
                        MessageBubble(message: message, conversationID: chat.id)
                    }
                }
            }.padding(.horizontal, 5).padding(.bottom, 12)
        }.navigationTitle("Saved messages").navigationBarTitleDisplayMode(.inline)
        .watchEdgeBack()
    }
}

struct AboutView: View {
    @Environment(MuseStore.self) private var store
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                AvatarView(size: 44)
                NavigationLink { SavedMessagesView() } label: {
                    Label("Saved messages", systemImage: "bookmark")
                }
                Text(store.phoneReachable ? "Your iPhone is reachable." : "Notes wait safely on your Watch until your iPhone is available.")
                Text(store.connectionStatus)
                if let date = store.lastSynced { Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))") }
                Button("Sync with iPhone") { store.refresh() }
                Text("Voice notes and replies use your paired iPhone’s internet. Open the iPhone app for longer replies.")
                Text("Choose your Muse name and avatar on iPhone. Earlier account history isn’t automatically imported.")
            }.font(.caption2).foregroundStyle(MuseStyle.secondary).padding(8)
        }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .watchEdgeBack()
    }
}
