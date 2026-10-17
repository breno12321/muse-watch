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
        // New chats and their first voice note survive offline sync races and relaunch.
        let chatDirectory = directory.appendingPathComponent("NewChats")
        let chats = MuseStore(directory: chatDirectory, connectivity: false)
        chats.receive(snapshot)
        let firstID = chats.createChat()!
        precondition(firstID != chat.id && chats.conversation(firstID)?.messages.isEmpty == true)
        let firstTitle = chats.conversation(firstID)!.title
        try Data([0, 1]).write(to: chats.audioURL("new-chat.wav"))
        chats.keepDraft(VoiceDraft(file: "new-chat.wav", duration: 2, conversationID: firstID))
        let secondID = chats.createChat()!
        precondition(firstID != secondID && chats.conversation(secondID)?.title != firstTitle)
        precondition(chats.activeChatID == secondID && chats.voiceChatID == firstID) // Draft keeps its original destination.
        let firstVoiceQueued = await chats.sendVoice()
        precondition(firstVoiceQueued)
        precondition(chats.activeChatID == firstID && chats.draft == nil)
        var phoneBeforeAdoption = snapshot; phoneBeforeAdoption.revision = 2
        chats.receive(phoneBeforeAdoption)
        precondition(chats.conversation(firstID)?.messages.last?.delivery == .queued)
        let relaunched = MuseStore(directory: chatDirectory, connectivity: false)
        precondition(relaunched.activeChatID == firstID && relaunched.conversation(secondID) != nil)
        struct PendingArchive: Decodable { let outbox: [RelayRequest] }
        let archiveURL = chatDirectory.appendingPathComponent("muse-live-watch.json")
        let queued = try JSONDecoder().decode(PendingArchive.self, from: Data(contentsOf: archiveURL)).outbox
        precondition(queued.count == 1 && queued[0].chatID == firstID && queued[0].newChat?.id == firstID)
        let introduction = try queued[0].chatToInsert(in: snapshot.chats)!
        var phoneAfterAdoption = snapshot; phoneAfterAdoption.revision = 3
        var acceptedChat = introduction; acceptedChat.exists = true
        phoneAfterAdoption.chats.append(acceptedChat)
        phoneAfterAdoption.messages.append(RelayMessage(id: queued[0].id.uuidString, requestID: queued[0].id, chatID: firstID, role: "user", text: "Voice note", delivery: .complete))
        relaunched.receive(phoneAfterAdoption)
        precondition(relaunched.conversations.filter { $0.id == firstID }.count == 1)
        precondition(relaunched.conversation(firstID)?.messages.last?.audioFile == "new-chat.wav")
        let followUpQueued = await relaunched.send("Continue the new chat", to: firstID)
        precondition(followUpQueued)
        let subsequent = try JSONDecoder().decode(PendingArchive.self, from: Data(contentsOf: archiveURL)).outbox
        precondition(subsequent.count == 1 && subsequent[0].newChat == nil)
        relaunched.read(chat.id)
        precondition(MuseStore(directory: chatDirectory, connectivity: false).activeChatID == chat.id)
        relaunched.receive(other)
        precondition(relaunched.selectedChatID == nil && relaunched.conversation(firstID) == nil && relaunched.conversation(secondID) == nil)
        // Existing installations can open their old archive before the new optional fields existed.
        var legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as! [String: Any]
        legacy.removeValue(forKey: "localChats"); legacy.removeValue(forKey: "selectedChatID")
        try JSONSerialization.data(withJSONObject: legacy).write(to: archiveURL)
        precondition(MuseStore(directory: chatDirectory, connectivity: false).error == nil)
        print("PASS: independent chats, offline first voice note, sync races, draft destination, selection, adoption, legacy archive and account isolation")
        let replyDirectory = directory.appendingPathComponent("Replies")
        let audioStore = MuseStore(directory: replyDirectory, connectivity: false)
        audioStore.receive(snapshot)
        let bytes = Data([0x49, 0x44, 0x33, 4] + Array(repeating: UInt8(0), count: 60))
        let descriptor = try ReplyAudio(data: bytes, duration: 2)
        let asset = ReplyAudioTransfer(account: snapshot.account, chatID: chat.id, messageID: "spoken-reply", audio: descriptor)
        let temporary = directory.appendingPathComponent("incoming.mp3")
        try bytes.write(to: temporary)
        audioStore.receiveReplyAudio(asset, from: temporary) // File can arrive before its snapshot.
        var speech = RelayMessage(id: "spoken-reply", chatID: chat.id, role: "muse", text: "**Here is my reply.**")
        speech.replyAudio = descriptor; speech.replyAudioState = .ready
        var speechSnapshot = snapshot; speechSnapshot.revision = 2; speechSnapshot.messages.append(speech)
        speechSnapshot.chats[0].serverTitle = "Muse topic"
        try speechSnapshot.chats[0].rename("My voice notes")
        audioStore.receive(speechSnapshot)
        let spoken = audioStore.conversation(chat.id)!.messages.last!
        precondition(spoken.audioFile == descriptor.filename && spoken.text == speech.text && spoken.replyAudioState == .ready)
        precondition(audioStore.conversation(chat.id)?.title == "My voice notes")
        let audioRestored = MuseStore(directory: replyDirectory, connectivity: false)
        precondition(audioRestored.conversation(chat.id)?.messages.last?.audioFile == descriptor.filename)
        let storedAudio = try Data(contentsOf: audioRestored.audioURL(descriptor.filename))
        precondition(storedAudio == bytes)
        let missingStore = MuseStore(directory: directory.appendingPathComponent("MissingAudio"), connectivity: false)
        missingStore.receive(speechSnapshot)
        precondition(missingStore.conversation(chat.id)?.messages.last?.audioFile == nil)
        precondition(missingStore.conversation(chat.id)?.messages.last?.replyAudioState == .preparing)
        try bytes.write(to: temporary)
        let foreignAsset = ReplyAudioTransfer(account: "foreign-account", chatID: chat.id, messageID: "spoken-reply", audio: descriptor)
        missingStore.receiveReplyAudio(foreignAsset, from: temporary)
        precondition(!FileManager.default.fileExists(atPath: missingStore.audioURL(descriptor.filename).path))
        audioRestored.receive(other)
        precondition(!FileManager.default.fileExists(atPath: audioRestored.audioURL(descriptor.filename).path))
        print("PASS: reply audio arrives before metadata, preserves Markdown, replays from disk, respects account scope, displays sync state and uses custom chat names")
        let corrupted = directory.appendingPathComponent("muse-live-watch.json")
        let bad = Data("not json".utf8); try bad.write(to: corrupted)
        let broken = MuseStore(directory: directory, connectivity: false)
        precondition(broken.error != nil); broken.persist()
        let preserved = try Data(contentsOf: corrupted); precondition(preserved == bad)
        print("PASS: stale snapshots rejected; account isolation; corrupt history preserved")
    }
}
