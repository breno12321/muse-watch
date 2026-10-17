import Foundation
import Observation
import CryptoKit
import UIKit
import AVFoundation

@MainActor @Observable
final class PhoneState {
    static let shared = PhoneState()
    struct PendingSetup: Codable { let request: SetupRequest; let privateKey: Data }
    struct LegacyMessage: Codable { let id: String; let role: String; let text: String; let done: Bool }
    struct LegacyHistory: Codable { let connection: String; let messages: [LegacyMessage]; let sessionID: String?; let sessionExists: Bool? }
    struct Archive: Codable {
        var account: String; var revision: Int; var chats: [RelayChat]; var messages: [RelayMessage]; var journal: RelayJournal
        var museName: String; var personName: String; var avatarRevision: String?
    }
    var status = "Set up your Muse"
    var error: String?
    var setupRequest: SetupRequest?
    var requestURL: URL?
    var paired = false
    var connected = false
    var busy = false
    var hasCandidate = false
    var watchReachable = false
    var chats: [RelayChat] = []
    var messages: [RelayMessage] = []
    var museName = "Cal"
    var personName = "Breno"
    var avatarRevision: String?
    private(set) var journal = RelayJournal()
    private let client = MuseClient()
    private let relay = RelayConnectivity()
    private let directory: URL
    private let historyURL: URL
    private var pending: PendingSetup?
    private var sessionID = UUID().uuidString.lowercased()
    private var sessionExists = false
    private var credentialNodeID: String?
    private var revision = 0
    private var storageReady = true
    private var activeRequest: UUID?
    private var recoveryIDs = Set<UUID>()
    private var attemptedRecoveries = Set<UUID>()
    private var monitoringRecovery = false
    private var restartAfterRecovery = false
    private var pump: Task<Void, Never>?
    private var listener: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var audioRequests: [ReplyAudioRequest] = []
    private var fetchingAudioOnly = false
    private var activeAudioRequest: ReplyAudioRequest?
    private var audioBackgroundExpired = false
    #if DEBUG
    private var audioDiagnostics: [String] = []
    #endif

    init() {
        directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        historyURL = directory.appendingPathComponent("muse-live-phone.json")
        do {
            if let bytes = try SecureStore.read("pending-setup") {
                let value = try JSONDecoder().decode(PendingSetup.self, from: bytes)
                if (try? value.request.validate()) != nil { pending = value; setupRequest = value.request; try writeRequest(value.request) }
                else { try SecureStore.delete("pending-setup") }
            }
            hasCandidate = try SecureStore.read("candidate-device-credentials") != nil
            if let bytes = try SecureStore.read("device-credentials") {
                let credentials = try JSONDecoder().decode(DeviceCredentials.self, from: bytes); try credentials.validate()
                credentialNodeID = credentials.identity.nodeID; paired = true; status = "Ready for your Watch"
            }
            if FileManager.default.fileExists(atPath: historyURL.path) {
                let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: historyURL))
                if saved.account == credentialNodeID {
                    revision = saved.revision; chats = saved.chats; messages = saved.messages; journal = saved.journal
                    museName = saved.museName; personName = saved.personName; avatarRevision = saved.avatarRevision
                    for index in messages.indices where messages[index].replyAudioState == .preparing { messages[index].replyAudioState = .unavailable }
                    journal.recoverInterrupted()
                    for entry in journal.entries { applyEntry(entry) }
                }
            }
            if chats.isEmpty, paired {
                let legacyURL = directory.appendingPathComponent("authentication-gate-history.json")
                if let data = try? Data(contentsOf: legacyURL), let legacy = try? JSONDecoder().decode(LegacyHistory.self, from: data), legacy.connection == credentialNodeID, let old = legacy.sessionID, let id = UUID(uuidString: old) {
                    chats = defaultChats(mainID: id); chats[0].exists = legacy.sessionExists ?? false
                    messages = legacy.messages.filter { $0.done }.map { RelayMessage(id: $0.id, chatID: id, role: $0.role == "user" ? "user" : "muse", text: $0.text, delivery: $0.role == "user" ? .complete : nil) }
                } else { chats = defaultChats() }
            }
            if paired { try persist() }
        } catch { storageReady = false; self.error = "Your saved setup or history could not be opened. It has been preserved. \(error.localizedDescription)" }
        relay.onRequest = { [weak self] request, audio in self?.receive(request, audio: audio) ?? false }
        relay.onSync = { [weak self] assets in self?.publish(); if assets { self?.sendAssets() }; self?.startProcessing() }
        relay.onStatus = { [weak self] reachable in self?.watchReachable = reachable }
        relay.onReplyAudioRequest = { [weak self] request in self?.requestReplyAudio(request) ?? false }
        relay.onRename = { [weak self] edit in self?.receiveRename(edit) ?? false }
        listener = Task { [weak self] in await self?.listen() }
    }
    private func defaultChats(mainID: UUID = UUID()) -> [RelayChat] {
        [RelayChat(id: mainID, title: museName, symbol: "bubble.left.and.bubble.right")]
    }
    @discardableResult func createChat() -> RelayChat? {
        guard paired, storageReady else { return nil }
        let chat = RelayChat.fresh(in: chats)
        chats.append(chat)
        do { try persist() }
        catch { chats.removeAll { $0.id == chat.id }; self.error = error.localizedDescription; return nil }
        publish(); return chat
    }
    @discardableResult func renameChat(_ id: UUID, title: String?) -> Bool {
        guard paired, storageReady, let index = chats.firstIndex(where: { $0.id == id }) else { return false }
        let previous = chats[index]
        do { try chats[index].rename(title) }
        catch { self.error = "Choose a chat name between 1 and 80 characters."; return false }
        do { try persist() }
        catch { chats[index] = previous; self.error = "Couldn’t save the chat name."; return false }
        publish(); return true
    }
    private func receiveRename(_ edit: ChatRename) -> Bool {
        guard paired, storageReady, let account = credentialNodeID else { return false }
        let previous = chats
        do {
            if try edit.apply(to: &chats, account: account) { try persist() }
            publish(); return true
        } catch { chats = previous; return false }
    }
    private func snapshot() -> RelaySnapshot {
        RelaySnapshot(account: credentialNodeID ?? "", revision: revision, paired: paired, status: status, museName: museName, personName: personName, avatarRevision: avatarRevision, chats: chats, messages: messages, updatedAt: .now)
    }
    private func persist() throws {
        guard storageReady else { throw MuseError.invalid("Saved history needs attention on iPhone before sending.") }
        revision += 1
        let saved = Archive(account: credentialNodeID ?? "", revision: revision, chats: chats, messages: messages, journal: journal, museName: museName, personName: personName, avatarRevision: avatarRevision)
        try JSONEncoder().encode(saved).write(to: historyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func publish() { relay.publish(snapshot()) }
    private func changed() {
        do { try persist() } catch { self.error = error.localizedDescription; storageReady = false }
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.publish()
        }
    }
    func becameActive() { relay.refresh(); publish(); queueRecoveries(); startProcessing() }
    func becameBackground() {
        if pump == nil { Task { guard pump == nil else { return }; await client.disconnect(); connected = false } }
    }
    private func listen() async {
        for await event in client.events {
            switch event {
            case .status: if activeRequest != nil { status = "Connecting to Muse…" }
            case .diagnostic(let value): if value.hasPrefix("Audio ") { recordAudioDiagnostic(value) }
            case .accepted(let session, let messageID):
                guard let id = activeRequest, let index = journal.entries.firstIndex(where: { $0.id == id }), journal.entries[index].request.chatID.uuidString.lowercased() == session else { continue }
                journal.entries[index].acceptedID = messageID
                if let chat = chats.firstIndex(where: { $0.id == journal.entries[index].request.chatID }) { chats[chat].exists = true }
                setDelivery(id, .accepted); status = "Waiting for \(museName)…"; changed()
            case .reply(let id, let text, let done):
                guard let requestID = activeRequest, let entry = journal.entries.first(where: { $0.id == requestID }) else { continue }
                if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].text = text }
                else { messages.append(RelayMessage(id: id, requestID: requestID, chatID: entry.request.chatID, role: "muse", text: text)) }
                if done, let index = messages.firstIndex(where: { $0.id == id }), messages[index].replyAudioState == nil { messages[index].replyAudioState = .preparing }
                status = "\(museName) is replying…"; changed()
            case .replyAudio(let id, let data):
                guard let request = activeRequest, let entry = journal.entries.first(where: { $0.id == request }),
                      let index = messages.firstIndex(where: { $0.id == id && $0.chatID == entry.request.chatID && $0.role == "muse" }) else { continue }
                do {
                    guard let data else { throw RelayError.invalid }
                    try cacheReplyAudio(data, at: index)
                } catch {
                    messages[index].replyAudioState = .unavailable; changed()
                }
            case .topic(let sessionID, let title):
                guard let id = UUID(uuidString: sessionID), let index = chats.firstIndex(where: { $0.id == id }), chats[index].serverTitle != title else { continue }
                chats[index].serverTitle = title; changed()
            case .finished:
                if let id = activeRequest { setDelivery(id, .complete) }
                activeRequest = nil; status = "Ready for your Watch"; changed()
            case .failure(let message):
                if fetchingAudioOnly { continue }
                if let id = activeRequest, let entry = journal.entries.first(where: { $0.id == id }) {
                    for index in messages.indices where messages[index].requestID == id && messages[index].replyAudioState == .preparing { messages[index].replyAudioState = .unavailable }
                    let submitted = entry.acceptedID != nil || [.sending, .accepted].contains(entry.delivery)
                    setDelivery(id, submitted ? (entry.acceptedID == nil ? .uncertain : .replyUnavailable) : .received, detail: submitted ? "Check this chat in Muse. It will not be resent. \(message)" : "Open Muse on iPhone to retry connecting. \(message)")
                }
                activeRequest = nil; connected = false; error = message; status = "Open Muse on iPhone"; changed()
            }
        }
    }
    @discardableResult func receive(_ request: RelayRequest, audio: URL?) -> Bool {
        do {
            guard paired, storageReady, request.account == credentialNodeID else { return false }
            let newChat = try request.chatToInsert(in: chats)
            if request.audioSHA256 != nil {
                guard let audio else { return false }; try VoicePayload.validateWAV(Data(contentsOf: audio))
            }
            var updated = journal
            let inserted = try updated.receive(request)
            if inserted {
                if let newChat { chats.append(newChat) }
                journal = updated
                messages.append(RelayMessage(id: request.id.uuidString, requestID: request.id, chatID: request.chatID, role: "user", text: request.audioSHA256 == nil ? request.text : (request.text.isEmpty ? "Voice note" : request.text), date: request.createdAt, duration: request.duration, delivery: .received))
                do { try persist() } catch { storageReady = false; throw error } // No acknowledgement or submission until durable.
            }
            if inserted, let current = activeRequest, monitoringRecovery {
                setDelivery(current, .replyUnavailable, detail: "Listening paused for your new message. Check the earlier reply in Muse.")
                activeRequest = nil; restartAfterRecovery = true; changed()
            }
            publish(); startProcessing(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func sendText(_ text: String, to chatID: UUID) {
        guard let account = credentialNodeID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = receive(RelayRequest(account: account, chatID: chatID, text: text), audio: nil)
    }
    private func setDelivery(_ id: UUID, _ delivery: Delivery, detail: String? = nil) {
        guard let i = journal.entries.firstIndex(where: { $0.id == id }) else { return }
        journal.entries[i].delivery = delivery; journal.entries[i].detail = detail; applyEntry(journal.entries[i])
    }
    private func applyEntry(_ entry: JournalEntry) {
        if let i = messages.firstIndex(where: { $0.id == entry.id.uuidString }) { messages[i].delivery = entry.delivery; messages[i].detail = entry.detail }
    }
    func retryConnection() { error = nil; attemptedRecoveries = []; queueRecoveries(); startProcessing(); publish() }
    private func queueRecoveries() {
        for chat in chats {
            if let last = journal.entries.last(where: { $0.request.chatID == chat.id }), last.delivery == .replyUnavailable, last.acceptedID != nil, !attemptedRecoveries.contains(last.id) { recoveryIDs.insert(last.id) }
        }
    }
    private var nextEntry: JournalEntry? {
        journal.entries.first(where: { $0.delivery == .received }) ?? journal.entries.last(where: { $0.delivery == .replyUnavailable && recoveryIDs.contains($0.id) && !attemptedRecoveries.contains($0.id) })
    }
    private func startProcessing() {
        guard pump == nil, paired, storageReady, nextEntry != nil || !audioRequests.isEmpty else { return }
        // Acquire execution time before leaving the WatchConnectivity callback.
        audioBackgroundExpired = false
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Muse Watch message") { [weak self] in Task { @MainActor in await self?.expireBackground() } }
        pump = Task { [weak self] in
            guard let self else { return }
            if self.nextEntry != nil { await self.processQueue() }
            else { await self.processAudioRequests() }
        }
    }
    private func processQueue() async {
        busy = true
        defer {
            pump = nil; busy = false; monitoringRecovery = false; endBackground(); publish()
            if restartAfterRecovery || (!audioRequests.isEmpty && nextEntry == nil) { restartAfterRecovery = false; Task { [weak self] in self?.startProcessing() } }
        }
        while let entry = nextEntry, paired, storageReady {
            let request = entry.request
            let isRecovery = entry.acceptedID != nil; monitoringRecovery = isRecovery
            if isRecovery { attemptedRecoveries.insert(request.id); recoveryIDs.remove(request.id) }
            activeRequest = request.id; error = nil
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Muse Watch message") { [weak self] in Task { @MainActor in await self?.expireBackground() } }
            }
            do {
                setDelivery(request.id, isRecovery ? .accepted : .connecting); try persist(); publish()
                guard let bytes = try SecureStore.read("device-credentials"), let chat = chats.first(where: { $0.id == request.chatID }) else { throw MuseError.rejectedCredentials }
                let credentials = try JSONDecoder().decode(DeviceCredentials.self, from: bytes)
                try await client.connect(credentials: credentials, sessionID: chat.id.uuidString.lowercased(), existingChat: chat.exists, resumeAcceptedMessageID: entry.acceptedID)
                guard activeRequest == request.id else { throw MuseError.interrupted }
                connected = true
                if !isRecovery {
                    setDelivery(request.id, .sending); try persist(); publish()
                    if request.audioSHA256 != nil {
                    let file = directory.appendingPathComponent("WatchTransfers").appendingPathComponent(request.id.uuidString + ".wav")
                    let data = try Data(contentsOf: file)
                    _ = try await client.sendVoice(data, text: request.text)
                    } else { _ = try await client.sendText(request.text) }
                }
                while activeRequest == request.id { try await Task.sleep(for: .milliseconds(200)) }
                await client.disconnect(); connected = false; endBackground()
                if journal.entries.first(where: { $0.id == request.id })?.delivery != .complete { break }
            } catch {
                if let value = journal.entries.first(where: { $0.id == request.id }), !value.delivery.terminal {
                    let submitted = value.acceptedID != nil || [.sending, .accepted].contains(value.delivery)
                    setDelivery(request.id, submitted ? (value.acceptedID == nil ? .uncertain : .replyUnavailable) : .received, detail: submitted ? "Submission may have succeeded. Check Muse; this message will not be resent." : "Couldn’t connect. Open Muse on iPhone and tap Retry.")
                }
                activeRequest = nil; connected = false; self.error = error.localizedDescription
                if (error as? MuseError) == .rejectedCredentials { paired = false; status = "Reconnect your Muse account" }
                else { status = "Open Muse on iPhone" }
                changed()
                await client.disconnect(); break
            }
        }
    }
    private func expireBackground() async {
        audioBackgroundExpired = true
        if let id = activeRequest, let entry = journal.entries.first(where: { $0.id == id }) {
            for index in messages.indices where messages[index].requestID == id && messages[index].replyAudioState == .preparing { messages[index].replyAudioState = .unavailable }
            let submitted = entry.acceptedID != nil || [.sending, .accepted].contains(entry.delivery)
            setDelivery(id, submitted ? (entry.acceptedID == nil ? .uncertain : .replyUnavailable) : .received, detail: submitted ? "iPhone background time ended. Check Muse for the reply; this message will not be resent." : "Open Muse on iPhone to finish connecting.")
        }
        activeRequest = nil; status = "Open Muse on iPhone"; changed(); await client.disconnect(); connected = false; endBackground()
    }
    private func endBackground() { if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid } }
    func updateProfile() {
        museName = String(museName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)); if museName.isEmpty { museName = "Muse" }
        personName = String(personName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if !chats.isEmpty { chats[0].title = museName }; changed()
    }
    func chooseAvatar(_ data: Data) throws {
        guard data.count <= 20 * 1024 * 1024, let image = UIImage(data: data) else { throw RelayError.invalid }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256))
        let thumbnail = renderer.image { _ in
            let ratio = max(256 / image.size.width, 256 / image.size.height)
            let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
            image.draw(in: CGRect(x: (256-size.width)/2, y: (256-size.height)/2, width: size.width, height: size.height))
        }
        guard let bytes = thumbnail.jpegData(compressionQuality: 0.85) else { throw RelayError.invalid }
        try bytes.write(to: directory.appendingPathComponent("muse-avatar.jpg"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        avatarRevision = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(); changed(); sendAssets()
    }
    var avatarURL: URL { directory.appendingPathComponent("muse-avatar.jpg") }
    func replyAudioURL(_ audio: ReplyAudio) -> URL { directory.appendingPathComponent(audio.filename) }
    private func cacheReplyAudio(_ data: Data, at index: Int) throws {
        let player = try AVAudioPlayer(data: data)
        recordAudioDiagnostic("Audio decoded: \(Int(player.duration)) seconds")
        let audio = try ReplyAudio(data: data, duration: player.duration)
        try data.write(to: replyAudioURL(audio), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        messages[index].replyAudio = audio; messages[index].replyAudioState = .ready
        try persist(); publish()
        _ = sendReplyAudio(ReplyAudioTransfer(account: credentialNodeID ?? "", chatID: messages[index].chatID, messageID: messages[index].id, audio: audio))
    }
    @discardableResult func requestReplyAudio(_ request: ReplyAudioRequest) -> Bool {
        guard paired, storageReady, request.account == credentialNodeID, (try? request.validate()) != nil,
              let message = messages.first(where: { $0.id == request.messageID && $0.chatID == request.chatID && $0.role == "muse" }) else { return false }
        if let audio = message.replyAudio, sendReplyAudio(ReplyAudioTransfer(account: request.account, chatID: request.chatID, messageID: message.id, audio: audio)) { return true }
        if activeAudioRequest == request || audioRequests.contains(request) { return true }
        guard audioRequests.count < 20 else { return false }
        audioRequests.append(request)
        if let index = messages.firstIndex(where: { $0.id == request.messageID }) { messages[index].replyAudioState = .preparing }
        changed(); startProcessing()
        return true
    }
    func requestReplyAudio(for message: RelayMessage) {
        _ = requestReplyAudio(ReplyAudioRequest(account: credentialNodeID ?? "", chatID: message.chatID, messageID: message.id))
    }
    private func processAudioRequests() async {
        busy = true; fetchingAudioOnly = true
        defer {
            pump = nil; busy = false; fetchingAudioOnly = false; activeAudioRequest = nil; endBackground(); publish()
            if !audioBackgroundExpired, nextEntry != nil { Task { [weak self] in self?.startProcessing() } }
        }
        while paired, storageReady, !audioBackgroundExpired, nextEntry == nil, !audioRequests.isEmpty {
            let request = audioRequests.removeFirst()
            activeAudioRequest = request
            guard request.account == credentialNodeID else { continue }
            do {
                guard let bytes = try SecureStore.read("device-credentials") else { throw MuseError.rejectedCredentials }
                status = "Getting voice reply…"; error = nil; publish()
                // A cached reply's TTS endpoint needs registration, not a historical chat subscription or another post.
                try await client.connect(credentials: JSONDecoder().decode(DeviceCredentials.self, from: bytes), sessionID: request.chatID.uuidString.lowercased(), subscribeToChat: false)
                let data = try await client.replyAudio(messageID: request.messageID)
                guard request.account == credentialNodeID, let index = messages.firstIndex(where: { $0.id == request.messageID && $0.chatID == request.chatID && $0.role == "muse" }) else { throw RelayError.invalid }
                try cacheReplyAudio(data, at: index)
            } catch {
                if case ReplyAudioError.http(let status) = error { recordAudioDiagnostic("Audio unavailable HTTP \(status)") }
                else { recordAudioDiagnostic("Audio unavailable code \((error as NSError).code)") }
                if (error as? MuseError) == .rejectedCredentials { paired = false; self.error = "Reconnect your Muse account." }
                if let index = messages.firstIndex(where: { $0.id == request.messageID && $0.chatID == request.chatID }) { messages[index].replyAudioState = .unavailable }
                changed()
            }
            await client.disconnect(); connected = false; status = paired ? "Ready for your Watch" : "Reconnect your Muse account"; publish()
            activeAudioRequest = nil
        }
    }
    private func recordAudioDiagnostic(_ value: String) {
        #if DEBUG
        // Counts/statuses only: no credentials, message text, IDs, URLs, or remote bodies.
        audioDiagnostics.append(value); audioDiagnostics = Array(audioDiagnostics.suffix(40))
        if let data = try? JSONEncoder().encode(audioDiagnostics) {
            try? data.write(to: directory.appendingPathComponent("reply-audio-diagnostics.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        #endif
    }
    private func sendReplyAudio(_ asset: ReplyAudioTransfer) -> Bool {
        guard paired, storageReady, asset.account == credentialNodeID,
              messages.contains(where: { $0.id == asset.messageID && $0.chatID == asset.chatID && $0.role == "muse" && $0.replyAudio == asset.audio }),
              let data = try? Data(contentsOf: replyAudioURL(asset.audio)), (try? asset.validate(data)) != nil else { return false }
        relay.transferReplyAudio(asset, url: replyAudioURL(asset.audio)); return true
    }
    private func sendAssets() {
        if avatarRevision != nil { relay.transferAsset(kind: "avatar", url: avatarURL, account: credentialNodeID ?? "") }
        if let data = try? JSONEncoder().encode(snapshot()), data.count < 2 * 1024 * 1024 {
            let path = directory.appendingPathComponent("watch-history.json")
            try? data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]); relay.transferAsset(kind: "history", url: path, account: credentialNodeID ?? "")
        }
    }
    func testRefresh() async {
        guard paired, !busy else { return }
        do {
            guard let bytes = try SecureStore.read("device-credentials") else { throw MuseError.rejectedCredentials }
            let updated = try await MuseAPI.refresh(JSONDecoder().decode(DeviceCredentials.self, from: bytes))
            try SecureStore.save(JSONEncoder().encode(updated), account: "device-credentials"); status = "Connection renewed"; error = nil; publish()
        } catch { self.error = error.localizedDescription }
    }
    func disconnectPairing() async {
        guard !busy else { return }; await client.disconnect()
        do {
            if FileManager.default.fileExists(atPath: historyURL.path) {
                try FileManager.default.copyItem(at: historyURL, to: directory.appendingPathComponent("disconnected-account-\(UUID().uuidString).json"))
            }
            try SecureStore.delete("device-credentials"); try SecureStore.delete("pending-setup"); try SecureStore.delete("candidate-device-credentials")
            paired = false; connected = false; hasCandidate = false; pending = nil; setupRequest = nil; requestURL = nil
            status = "Set up your Muse"; changed()
        } catch { self.error = error.localizedDescription }
    }
    func createRequest() {
        guard !paired, !busy else { return }
        do {
            let key = Curve25519.KeyAgreement.PrivateKey()
            let value = PendingSetup(request: SetupRequest(publicKey: key.publicKey.rawRepresentation), privateKey: key.rawRepresentation)
            try SecureStore.save(JSONEncoder().encode(value), account: "pending-setup")
            pending = value; setupRequest = value.request; try writeRequest(value.request); error = nil
        } catch { self.error = error.localizedDescription }
    }
    private func writeRequest(_ request: SetupRequest) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MuseWatch-\(request.id.uuidString).muserequest")
        try JSONEncoder().encode(request).write(to: url, options: .atomic); requestURL = url
    }
    func importCredentials(_ url: URL) async {
        guard !busy, !paired else { error = "Disconnect this pairing before importing another account."; return }
        busy = true; defer { busy = false }
        do {
            guard let pending else { throw MuseError.invalid("Create a setup request on this iPhone first. Imported files cannot be reused after setup.") }
            let envelope = try JSONDecoder().decode(SetupEnvelope.self, from: readSetupFile(url))
            let candidate = try envelope.open(request: pending.request, privateKey: pending.privateKey)
            try SecureStore.save(JSONEncoder().encode(candidate), account: "candidate-device-credentials")
            hasCandidate = true
            try await finishSetup(candidate)
        } catch {
            await client.disconnect(); connected = false; self.error = error.localizedDescription
            status = "Couldn’t connect this pairing"
        }
    }
    private func finishSetup(_ candidate: DeviceCredentials) async throws {
        sessionID = UUID().uuidString.lowercased(); sessionExists = false
        try await client.connect(credentials: candidate, sessionID: sessionID, credentialAccount: "candidate-device-credentials")
        guard let verified = await client.currentCredentials() else { throw MuseError.interrupted }
        try SecureStore.save(JSONEncoder().encode(verified), account: "device-credentials")
        await client.usePairedCredentialStore()
        try SecureStore.delete("pending-setup"); try SecureStore.delete("candidate-device-credentials")
        pending = nil; setupRequest = nil; hasCandidate = false
        if let requestURL { try? FileManager.default.removeItem(at: requestURL) }; requestURL = nil
        paired = true; connected = true; credentialNodeID = verified.identity.nodeID
        chats = defaultChats(mainID: UUID(uuidString: sessionID) ?? UUID())
        messages = []; journal = RelayJournal(); error = nil
        await client.disconnect(); connected = false; status = "Ready for your Watch"
        try persist(); publish()
    }
    func retrySetup() async {
        guard !busy, !paired, hasCandidate else { return }; busy = true; defer { busy = false }
        do {
            guard let data = try SecureStore.read("candidate-device-credentials") else { throw MuseError.rejectedCredentials }
            try await finishSetup(JSONDecoder().decode(DeviceCredentials.self, from: data))
        } catch { connected = false; self.error = error.localizedDescription; status = "Setup connection failed" }
    }

}
