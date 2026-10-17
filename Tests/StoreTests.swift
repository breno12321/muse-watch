import Foundation

@main struct StoreTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MuseLiveTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MuseStore(directory: directory, connectivity: false)
        precondition(store.conversations.isEmpty) // Never introduce sample messages into the live app.
        let chat = RelayChat(title: "Cal", symbol: "bubble", exists: true)
        let reply = RelayMessage(id: "real-reply", chatID: chat.id, role: "muse", text: "A real reply")
        let snapshot = RelaySnapshot(account: "account", revision: 1, paired: true, status: "Ready", museName: "Cal", personName: "You", chats: [chat], messages: [reply], updatedAt: .now)
        store.receive(snapshot)
        store.toggleSaved(reply.id, in: chat.id)
        await store.send("A message while offline", to: chat.id)
        let restored = MuseStore(directory: directory, connectivity: false)
        precondition(restored.savedMessages.first?.id == reply.id)
        precondition(restored.conversation(chat.id)?.messages.last?.delivery == .queued)
        precondition(restored.conversation(chat.id)?.messages.filter { $0.role == .muse }.count == 1) // No fabricated reply.
        store.keepDraft(VoiceDraft(file: "missing.wav", duration: 3, conversationID: chat.id))
        let sent = await store.sendVoice()
        precondition(!sent && store.draft != nil)
        store.error = nil; store.discardDraft()
        // A Muse reply shares the voice request ID for correlation, but must display its text.
        let recording = "voice.wav"
        try Data([0, 1]).write(to: store.audioURL(recording))
        store.keepDraft(VoiceDraft(file: recording, duration: 3, conversationID: chat.id))
        let queuedVoice = await store.sendVoice()
        precondition(queuedVoice)
        let voiceMessage = store.conversation(chat.id)!.messages.last!
        var voiceSnapshot = snapshot; voiceSnapshot.revision = 2
        voiceSnapshot.messages += [
            RelayMessage(id: voiceMessage.id, requestID: UUID(uuidString: voiceMessage.id), chatID: chat.id, role: "user", text: "Voice note", duration: 3, delivery: .complete),
            RelayMessage(id: "voice-reply", requestID: UUID(uuidString: voiceMessage.id), chatID: chat.id, role: "muse", text: "I heard your recording.")
        ]
        store.receive(voiceSnapshot)
        precondition(store.conversation(chat.id)?.messages.first { $0.id == voiceMessage.id }?.audioFile == recording)
        precondition(store.conversation(chat.id)?.messages.first { $0.id == "voice-reply" }?.audioFile == nil)
        precondition(store.conversation(chat.id)?.messages.first { $0.id == "voice-reply" }?.text == "I heard your recording.")
        precondition(audioTime(61.9) == "1:01")
        print("PASS: offline queue survives restart; real cached replies/bookmarks survive; no demo data; missing recording retained; voice replies render text")
        // Old snapshots never overwrite a newer server delivery receipt.
        var newer = snapshot; newer.revision = 3
        newer.messages.append(RelayMessage(id: "next", chatID: chat.id, role: "muse", text: "New reply"))
        restored.receive(newer); restored.receive(snapshot)
        precondition(restored.conversation(chat.id)?.messages.contains { $0.id == "next" } == true)
        // Account changes clear the old mirror and pending submissions.
        var other = snapshot; other.account = "another-account"; other.revision = 1; other.messages = []
        restored.receive(other)
        precondition(restored.savedMessages.isEmpty && restored.conversation(chat.id)?.messages.isEmpty == true)
        let corrupted = directory.appendingPathComponent("muse-live-watch.json")
        let bad = Data("not json".utf8); try bad.write(to: corrupted)
        let broken = MuseStore(directory: directory, connectivity: false)
        precondition(broken.error != nil); broken.persist()
        let preserved = try Data(contentsOf: corrupted); precondition(preserved == bad)
        print("PASS: stale snapshots rejected; account isolation; corrupt history preserved")
    }
}
