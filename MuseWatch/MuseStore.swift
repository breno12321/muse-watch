import Foundation
import Observation
import CryptoKit

@MainActor @Observable
final class MuseStore {
    static let shared = MuseStore()
    var conversations: [Conversation] = []
    var draft: VoiceDraft?
    var error: String?
    var phoneReachable = false
    var paired = false
    var museName = "Cal"
    var personName = "Breno"
    var connectionStatus = "Open Muse Watch on your iPhone"
    var lastSynced: Date?
    var avatarVersion = UUID()
    private(set) var selectedChatID: UUID?
    private let directory: URL
    private let file: URL
    private let relay: RelayConnectivity?
    private var snapshot: RelaySnapshot?
    private var outbox: [RelayRequest] = []
    private var localChats: [RelayChat] = []
    private var replyAudioFiles: [String: ReplyAudioTransfer] = [:]
    private var bookmarks = Set<String>()
    private var audioFiles: [String: String] = [:]
    private var canPersist = true
    private struct Saved: Codable {
        var snapshot: RelaySnapshot?; var outbox: [RelayRequest]; var bookmarks: Set<String>; var audioFiles: [String: String]; var draft: VoiceDraft?
        var localChats: [RelayChat]?; var selectedChatID: UUID?
        var replyAudioFiles: [String: ReplyAudioTransfer]?
    }
    init(directory: URL? = nil, connectivity: Bool = true) {
        self.directory = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        file = self.directory.appendingPathComponent("muse-live-watch.json")
        relay = connectivity ? RelayConnectivity() : nil
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file))
                snapshot = saved.snapshot; outbox = saved.outbox; bookmarks = saved.bookmarks; audioFiles = saved.audioFiles; draft = saved.draft
                localChats = saved.localChats ?? []; selectedChatID = saved.selectedChatID
                replyAudioFiles = saved.replyAudioFiles ?? [:]
                rebuild()
            }
        } catch { canPersist = false; self.error = "Your saved Watch history could not be opened. It has been preserved." }
        relay?.onSnapshot = { [weak self] value in self?.receive(value) }
        relay?.onStatus = { [weak self] value in self?.phoneReachable = value; self?.flush() }
        relay?.onReceipt = { [weak self] id in self?.acknowledgePhone(id) }
        relay?.onReplyAudio = { [weak self] asset, url in self?.receiveReplyAudio(asset, from: url) }
        relay?.onAsset = { [weak self] kind, url, account in
            guard let self, kind == "avatar", self.snapshot?.account == account else { try? FileManager.default.removeItem(at: url); return }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 1024 * 1024 else { return }
                try data.write(to: self.avatarURL, options: .atomic); try? FileManager.default.removeItem(at: url); self.avatarVersion = UUID()
            } catch { self.error = "Couldn’t save your Muse avatar." }
        }
    }
    var mainID: UUID? { conversations.first?.id }
    var activeChatID: UUID? {
        if let selectedChatID, conversation(selectedChatID) != nil { return selectedChatID }
        return mainID
    }
    var voiceChatID: UUID? { draft?.conversationID ?? activeChatID }
    var savedMessages: [Message] { conversations.flatMap(\.messages).filter(\.saved) }
    var sending: Set<UUID> { Set(conversations.filter { $0.messages.contains { $0.role == .user && $0.delivery?.terminal == false } }.map(\.id)) }
    var avatarURL: URL { directory.appendingPathComponent("muse-avatar.jpg") }
    func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }
    func audioURL(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func refresh() { relay?.refresh(); flush() }
    func receive(_ value: RelaySnapshot) {
        guard value.version == 1, canPersist else { return }
        if let old = snapshot, old.account == value.account, value.revision < old.revision { return }
        if let old = snapshot, !old.account.isEmpty, old.account != value.account, !value.account.isEmpty {
            try? FileManager.default.copyItem(at: file, to: directory.appendingPathComponent("previous-account-\(UUID().uuidString).json"))
            for asset in replyAudioFiles.values { try? FileManager.default.removeItem(at: audioURL(asset.audio.filename)) }
            outbox = []; bookmarks = []; audioFiles = [:]; draft = nil; snapshot = nil; localChats = []; selectedChatID = nil; replyAudioFiles = [:]
            try? FileManager.default.removeItem(at: avatarURL); avatarVersion = UUID()
        }
        var incoming = value
        localChats.removeAll { chat in value.chats.contains(where: { $0.id == chat.id }) }
        incoming.chats += localChats
        let present = Set(incoming.messages.map(\.id))
        incoming.messages += (snapshot?.messages ?? []).filter { message in !present.contains(message.id) && incoming.chats.contains(where: { $0.id == message.chatID }) }
        incoming.messages.sort { $0.date < $1.date }
        snapshot = incoming
        let receivedIDs = Set(value.messages.compactMap(\.requestID))
        outbox.removeAll { receivedIDs.contains($0.id) }
        rebuild(); persist(); flush()
    }
    private func rebuild() {
        guard let snapshot else { return }
        paired = snapshot.paired; museName = snapshot.museName; personName = snapshot.personName
        connectionStatus = snapshot.status; lastSynced = snapshot.updatedAt
        conversations = snapshot.chats.map { chat in
            Conversation(id: chat.id, title: chat.displayTitle, symbol: chat.symbol, messages: snapshot.messages.filter { $0.chatID == chat.id }.map { value in
                let asset = value.replyAudio.flatMap { replyAudioFiles[$0.id.uuidString] }
                let cached = value.role == "muse" && asset?.account == snapshot.account && asset?.chatID == chat.id && asset?.messageID == value.id && asset?.audio == value.replyAudio && asset.map { FileManager.default.fileExists(atPath: audioURL($0.audio.filename).path) } == true
                return Message(id: value.id, role: value.role == "user" ? .user : .muse, text: value.text, date: value.date, audioFile: value.role == "user" ? value.requestID.flatMap { audioFiles[$0.uuidString] } : (cached ? value.replyAudio?.filename : nil), duration: value.role == "muse" ? value.replyAudio?.duration : value.duration, saved: bookmarks.contains(value.id), delivery: value.delivery, detail: value.detail, replyAudio: value.replyAudio, replyAudioState: value.replyAudio == nil ? value.replyAudioState : (cached ? .ready : .preparing))
            })
        }
    }
    func persist() {
        do { try save() } catch { self.error = "Couldn’t save your Watch history. \(error.localizedDescription)"; canPersist = false }
    }
    private func save() throws {
        guard canPersist else { throw RelayError.invalid }
        try JSONEncoder().encode(Saved(snapshot: snapshot, outbox: outbox, bookmarks: bookmarks, audioFiles: audioFiles, draft: draft, localChats: localChats, selectedChatID: selectedChatID, replyAudioFiles: replyAudioFiles)).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func receiveReplyAudio(_ asset: ReplyAudioTransfer, from url: URL) {
        defer { try? FileManager.default.removeItem(at: url) }
        guard canPersist, asset.account == snapshot?.account else { return }
        do {
            let data = try Data(contentsOf: url); try asset.validate(data)
            if let old = replyAudioFiles[asset.audio.id.uuidString], old != asset { throw RelayError.duplicate }
            try data.write(to: audioURL(asset.audio.filename), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            replyAudioFiles[asset.audio.id.uuidString] = asset
            rebuild(); persist()
        } catch { self.error = "Couldn’t save this voice reply. Sync with your iPhone to try again." }
    }
    func requestReplyAudio(_ message: Message, in chatID: UUID) {
        guard let account = snapshot?.account, message.role == .muse else { return }
        relay?.requestReplyAudio(ReplyAudioRequest(account: account, chatID: chatID, messageID: message.id))
    }
    func read(_ id: UUID) {
        guard conversation(id) != nil, selectedChatID != id else { return }
        selectedChatID = id; persist()
    }
    @discardableResult func createChat() -> UUID? {
        guard var value = snapshot, paired, canPersist else { return nil }
        let chat = RelayChat.fresh(in: value.chats)
        let old = snapshot, oldSelection = selectedChatID
        value.chats.append(chat); snapshot = value; localChats.append(chat); selectedChatID = chat.id
        do { try save() }
        catch {
            snapshot = old; selectedChatID = oldSelection; localChats.removeAll { $0.id == chat.id }
            self.error = "Couldn’t save a new chat. \(error.localizedDescription)"; return nil
        }
        rebuild(); return chat.id
    }
    func toggleSaved(_ messageID: String, in conversationID: UUID) {
        if bookmarks.contains(messageID) { bookmarks.remove(messageID) } else { bookmarks.insert(messageID) }
        rebuild(); persist()
    }
    func keepDraft(_ draft: VoiceDraft) { self.draft = draft; persist() }
    func discardDraft() {
        if let draft { try? FileManager.default.removeItem(at: audioURL(draft.file)) }
        draft = nil; persist()
    }
    func sendVoice() async -> Bool {
        guard let draft, conversation(draft.conversationID) != nil else { return false }
        do {
            let url = audioURL(draft.file), data = try Data(contentsOf: url)
            guard data.count <= 2 * 1024 * 1024, draft.duration >= 0.3, draft.file.hasSuffix(".wav") else { throw RelayError.invalid }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return try enqueue(text: "", chatID: draft.conversationID, audioHash: hash, duration: draft.duration, audioFile: draft.file)
        } catch { self.error = "This recording could not be queued. Record it again. \(error.localizedDescription)"; return false }
    }
    @discardableResult func send(_ text: String, to id: UUID) async -> Bool {
        do { return try enqueue(text: text, chatID: id) } catch { self.error = error.localizedDescription; return false }
    }
    private func enqueue(text: String, chatID: UUID, audioHash: String? = nil, duration: Double? = nil, audioFile: String? = nil) throws -> Bool {
        guard var value = snapshot, value.paired, canPersist, value.chats.contains(where: { $0.id == chatID }) else { throw RelayError.invalid }
        guard outbox.count < 20 else { throw RelayError.full }
        let request = RelayRequest(account: value.account, chatID: chatID, text: text, audioSHA256: audioHash, duration: duration, newChat: localChats.first { $0.id == chatID })
        try request.validate()
        value.messages.append(RelayMessage(id: request.id.uuidString, requestID: request.id, chatID: chatID, role: "user", text: audioFile == nil ? text : "Voice note", date: request.createdAt, duration: duration, delivery: .queued))
        let old = snapshot; let oldDraft = draft; let oldSelection = selectedChatID
        snapshot = value; outbox.append(request); selectedChatID = chatID
        if let audioFile { audioFiles[request.id.uuidString] = audioFile; draft = nil }
        do { try save() }
        catch { snapshot = old; draft = oldDraft; selectedChatID = oldSelection; outbox.removeAll { $0.id == request.id }; audioFiles.removeValue(forKey: request.id.uuidString); throw error }
        rebuild(); flush(); return true
    }
    private func flush() {
        guard paired, canPersist, let relay else { return }
        for request in outbox {
            do {
                let audio = audioFiles[request.id.uuidString].map { audioURL($0) }
                try relay.enqueue(request, audio: audio)
            } catch { /* Remains in the durable outbox until activation or reconnect. */ }
        }
    }
    private func acknowledgePhone(_ id: UUID) {
        outbox.removeAll { $0.id == id }
        if let index = snapshot?.messages.firstIndex(where: { $0.requestID == id && $0.role == "user" }), snapshot?.messages[index].delivery == .queued { snapshot?.messages[index].delivery = .received }
        rebuild(); persist()
    }
}
