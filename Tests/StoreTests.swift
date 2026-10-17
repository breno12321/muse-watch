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
        var transcribed = voiceSnapshot; transcribed.revision = 3
        let voiceIndex = transcribed.messages.firstIndex { $0.id == voiceMessage.id }!
        transcribed.messages[voiceIndex].text = "Please say hello."
        store.receive(transcribed)
        let transcriptRestored = MuseStore(directory: directory, connectivity: false)
        let transcribedNote = transcriptRestored.conversation(chat.id)?.messages.first { $0.id == voiceMessage.id }
        precondition(transcribedNote?.text == "Please say hello." && transcribedNote?.audioFile == recording)
        precondition(transcriptRestored.conversation(chat.id)?.messages.filter { $0.id == voiceMessage.id }.count == 1)
        precondition(audioTime(61.9) == "1:01")
        print("PASS: offline queue survives restart; real cached replies/bookmarks survive; no demo data; missing recording retained; voice transcript and local playback survive sync/relaunch without duplicates")
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
        // Watch list preferences survive snapshots/relaunch without deleting phone/Muse history.
        let listDirectory = directory.appendingPathComponent("ChatActions")
        let list = MuseStore(directory: listDirectory, connectivity: false)
        let anotherChat = RelayChat(title: "Another chat", symbol: "bubble", exists: true)
        var listSnapshot = snapshot; listSnapshot.chats.append(anotherChat)
        list.receive(listSnapshot); list.read(anotherChat.id)
        list.togglePinned(chat.id)
        precondition(list.orderedChats.first?.id == chat.id && list.activeChatID == anotherChat.id)
        let listRestored = MuseStore(directory: listDirectory, connectivity: false)
        precondition(listRestored.isPinned(chat.id) && listRestored.orderedChats.first?.id == chat.id)
        listRestored.togglePinned(chat.id)
        precondition(!listRestored.isPinned(chat.id) && listRestored.orderedChats.first?.id == anotherChat.id)
        listRestored.togglePinned(anotherChat.id)
        listRestored.toggleSaved(reply.id, in: chat.id)
        precondition(listRestored.deleteChat(anotherChat.id))
        precondition(listRestored.selectedChatID == nil && listRestored.voiceChatID == chat.id && !listRestored.isPinned(anotherChat.id))
        precondition(listRestored.deleteChat(chat.id) && listRestored.savedMessages.isEmpty && listRestored.voiceChatID == nil)
        listSnapshot.revision = 4
        listRestored.receive(listSnapshot)
        precondition(listRestored.conversations.isEmpty && listSnapshot.messages.count == 1)
        let deletedRestored = MuseStore(directory: listDirectory, connectivity: false)
        precondition(deletedRestored.conversations.isEmpty)
        let sentToDeleted = await deletedRestored.send("Do not resurrect this chat", to: chat.id)
        precondition(!sentToDeleted)
        let replacement = deletedRestored.createChat()!
        precondition(deletedRestored.voiceChatID == replacement)
        precondition(deletedRestored.deleteChat(replacement)) // Empty local chats stay removed on sync too.
        deletedRestored.receive(listSnapshot)
        precondition(deletedRestored.conversations.isEmpty)
        deletedRestored.receive(other) // Identical UUID in another account must not inherit deletion/pinning.
        precondition(deletedRestored.conversation(chat.id) != nil && !deletedRestored.isPinned(chat.id))
        let guards = MuseStore(directory: directory.appendingPathComponent("DeletionGuards"), connectivity: false)
        guards.receive(snapshot)
        try Data([0, 1]).write(to: guards.audioURL("keep-draft.wav"))
        guards.keepDraft(VoiceDraft(file: "keep-draft.wav", duration: 2, conversationID: chat.id))
        precondition(!guards.deleteChat(chat.id) && guards.draft != nil)
        precondition(FileManager.default.fileExists(atPath: guards.audioURL("keep-draft.wav").path))
        guards.discardDraft()
        let pending = await guards.send("Pending offline", to: chat.id)
        precondition(pending && !guards.deleteChat(chat.id))
        var sendingSnapshot = snapshot; sendingSnapshot.revision = 2
        sendingSnapshot.messages.append(RelayMessage(id: "sending", chatID: chat.id, role: "user", text: "On phone", delivery: .sending))
        let sendingList = MuseStore(directory: directory.appendingPathComponent("SendingChat"), connectivity: false)
        sendingList.receive(sendingSnapshot)
        precondition(!sendingList.deleteChat(chat.id))
        // A failed disk write cannot silently hide a chat or lose its selection/pin.
        let failureDirectory = directory.appendingPathComponent("FailedDeletion")
        let failureList = MuseStore(directory: failureDirectory, connectivity: false)
        failureList.receive(snapshot); failureList.read(chat.id); failureList.togglePinned(chat.id)
        let failureArchive = failureDirectory.appendingPathComponent("muse-live-watch.json")
        try FileManager.default.moveItem(at: failureArchive, to: failureDirectory.appendingPathComponent("preserved.json"))
        try FileManager.default.createDirectory(at: failureArchive, withIntermediateDirectories: true)
        precondition(!failureList.deleteChat(chat.id) && failureList.conversation(chat.id) != nil && failureList.isPinned(chat.id) && failureList.activeChatID == chat.id)
        failureList.togglePinned(chat.id)
        precondition(failureList.isPinned(chat.id))
        // New preferences are optional in archives from an older installation.
        var oldPreferences = try JSONSerialization.jsonObject(with: Data(contentsOf: listDirectory.appendingPathComponent("muse-live-watch.json"))) as! [String: Any]
        oldPreferences.removeValue(forKey: "pinnedChatIDs"); oldPreferences.removeValue(forKey: "deletedChatIDs")
        try JSONSerialization.data(withJSONObject: oldPreferences).write(to: listDirectory.appendingPathComponent("muse-live-watch.json"))
        precondition(MuseStore(directory: listDirectory, connectivity: false).error == nil)
        print("PASS: pinned ordering, unpin, durable Watch-only deletion, sync/relaunch, last-chat replacement, draft/outbox/sending guards, write rollback and legacy/account isolation")
        let renameDirectory = directory.appendingPathComponent("WatchNames")
        let names = MuseStore(directory: renameDirectory, connectivity: false)
        names.receive(snapshot)
        precondition(names.renameChat(chat.id, title: "  Watch ideas  "))
        precondition(names.conversation(chat.id)?.title == "Watch ideas" && names.conversation(chat.id)?.messages.count == snapshot.messages.count)
        struct RenameArchive: Decodable { let pendingRenames: [UUID: ChatRename]?; let outbox: [RelayRequest] }
        let namesURL = renameDirectory.appendingPathComponent("muse-live-watch.json")
        func readNameArchive() throws -> RenameArchive { try JSONDecoder().decode(RenameArchive.self, from: Data(contentsOf: namesURL)) }
        let firstNameArchive = try readNameArchive(); precondition(firstNameArchive.outbox.isEmpty)
        let namesRestored = MuseStore(directory: renameDirectory, connectivity: false)
        precondition(namesRestored.conversation(chat.id)?.title == "Watch ideas")
        precondition(namesRestored.renameChat(chat.id, title: "Latest Watch name"))
        var unacknowledged = snapshot; unacknowledged.revision = 2
        namesRestored.receive(unacknowledged)
        precondition(namesRestored.conversation(chat.id)?.title == "Latest Watch name")
        let nameEdit = try readNameArchive().pendingRenames![chat.id]!
        precondition(nameEdit.revision == 2)
        var nameAck = snapshot; nameAck.revision = 3
        try nameEdit.apply(to: &nameAck.chats, account: nameAck.account)
        namesRestored.receive(nameAck)
        let receivedNameArchive = try readNameArchive(); precondition(receivedNameArchive.pendingRenames?.isEmpty == true)
        precondition(namesRestored.conversation(chat.id)?.title == "Latest Watch name")
        try nameAck.chats[0].rename("Changed on iPhone"); nameAck.revision = 4
        namesRestored.receive(nameAck)
        precondition(namesRestored.conversation(chat.id)?.title == "Changed on iPhone")
        let namedEmpty = namesRestored.createChat()!
        precondition(namesRestored.renameChat(namedEmpty, title: "Empty named chat"))
        let emptyEdit = try readNameArchive().pendingRenames![namedEmpty]!
        precondition(emptyEdit.newChat?.id == namedEmpty)
        var emptyAck = nameAck; emptyAck.revision = 5
        try emptyEdit.apply(to: &emptyAck.chats, account: emptyAck.account)
        namesRestored.receive(emptyAck)
        let emptyNameArchive = try readNameArchive(); precondition(emptyNameArchive.pendingRenames?.isEmpty == true)
        precondition(namesRestored.conversation(namedEmpty)?.title == "Empty named chat")
        precondition(namesRestored.renameChat(chat.id, title: "Still pending"))
        namesRestored.receive(other)
        let changedAccountNameArchive = try readNameArchive(); precondition(changedAccountNameArchive.pendingRenames?.isEmpty == true)
        precondition(namesRestored.conversation(chat.id)?.title == chat.title)
        precondition(!namesRestored.renameChat(chat.id, title: "\n"))
        precondition(namesRestored.conversation(chat.id)?.title == chat.title)
        // Reuse the failed-write store: a rename must roll back its pending override too.
        precondition(!failureList.renameChat(chat.id, title: "Must not leak into UI"))
        precondition(failureList.conversation(chat.id)?.title == chat.title)
        print("PASS: offline Watch renames, durable edit queue, snapshot acknowledgements, phone edits, empty-chat adoption, no message posts, rollback and account isolation")
        let earlierDirectory = directory.appendingPathComponent("EarlierChats")
        let earlier = MuseStore(directory: earlierDirectory, connectivity: false)
        let idea = RelayChat(title: "Ideas", symbol: "lightbulb", exists: true)
        var earlierSnapshot = snapshot
        earlierSnapshot.chats += [idea, RelayChat(title: "Goals", symbol: "checkmark.circle"), RelayChat(title: "Check-in", symbol: "sparkles")]
        earlierSnapshot.messages.append(RelayMessage(id: "earlier-reply", chatID: idea.id, role: "muse", text: "Preserved earlier history"))
        earlier.receive(earlierSnapshot)
        precondition(earlier.orderedChats.map(\.id) == [chat.id] && earlier.conversations.count == 4)
        precondition(earlier.conversation(idea.id)?.messages.count == 1)
        earlier.toggleSaved("earlier-reply", in: idea.id)
        precondition(earlier.savedMessages.contains { $0.id == "earlier-reply" })
        earlier.read(idea.id)
        precondition(earlier.activeChatID == chat.id)
        earlier.keepDraft(VoiceDraft(file: "earlier-draft.wav", duration: 2, conversationID: idea.id))
        precondition(earlier.voiceChatID == idea.id && earlier.orderedChats.contains { $0.id == idea.id })
        earlier.discardDraft()
        precondition(!earlier.orderedChats.contains { $0.id == idea.id })
        let earlierQueued = await earlier.send("Keep a pending send visible", to: idea.id)
        precondition(earlierQueued && earlier.orderedChats.contains { $0.id == idea.id })
        let earlierRequest = earlier.conversation(idea.id)!.messages.last!
        earlierSnapshot.revision = 2
        earlierSnapshot.messages.append(RelayMessage(id: earlierRequest.id, requestID: UUID(uuidString: earlierRequest.id), chatID: idea.id, role: "user", text: earlierRequest.text, delivery: .complete))
        earlier.receive(earlierSnapshot)
        precondition(!earlier.orderedChats.contains { $0.id == idea.id })
        precondition(earlier.renameChat(idea.id, title: "My restored conversation"))
        precondition(earlier.orderedChats.contains { $0.id == idea.id })
        let earlierRestored = MuseStore(directory: earlierDirectory, connectivity: false)
        precondition(earlierRestored.conversation(idea.id)?.messages.count == 2 && earlierRestored.orderedChats.contains { $0.id == idea.id })
        print("PASS: earlier starter chats leave the main list without losing history/bookmarks; drafts and pending sends stay visible; renaming restores a chat")
        let corrupted = directory.appendingPathComponent("muse-live-watch.json")
        let bad = Data("not json".utf8); try bad.write(to: corrupted)
        let broken = MuseStore(directory: directory, connectivity: false)
        precondition(broken.error != nil); broken.persist()
        let preserved = try Data(contentsOf: corrupted); precondition(preserved == bad)
        print("PASS: stale snapshots rejected; account isolation; corrupt history preserved")
    }
}
