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
        var audioPresentations: [String: MuseAudioPresentation]? = nil
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
    var transcriptionAuthorized = VoiceTranscriber.authorized
    var transcriptionPermissionDenied = VoiceTranscriber.permissionDenied
    var transcriptionLocale = UserDefaults.standard.string(forKey: "voice-transcription-locale") ?? Locale.current.identifier
    var chats: [RelayChat] = []
    var messages: [RelayMessage] = []
    var museName = "Cal"
    var personName = "Breno"
    var avatarRevision: String?
    private(set) var journal = RelayJournal()
    private let client = MuseClient()
    private let transcriber = VoiceTranscriber()
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
    private var audioPresentations: [String: MuseAudioPresentation] = [:]
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
                    audioPresentations = saved.audioPresentations ?? [:]
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
        relay.onChatRefresh = { [weak self] request in
            guard let self, self.storageReady, self.paired, request.account == self.snapshot().account,
                  self.chats.contains(where: { $0.id == request.chatID }) else { return nil }
            self.startProcessing()
            return try? self.snapshot().contextData(for: request)
        }
        relay.onStatus = { [weak self] reachable in self?.watchReachable = reachable }
        relay.onReplyAudioRequest = { [weak self] request in self?.requestReplyAudio(request) ?? false }
        relay.onRename = { [weak self] edit in self?.receiveRename(edit) ?? false }
        for reference in audioPresentations.values.prefix(4) {
            recordAudioDiagnostic("Audio presentation: stored \(reference.mimeLabel); \(reference.pathKind); resources \(reference.resources != nil)")
        }
        listener = Task { [weak self] in await self?.listen() }
    }
    private func defaultChats(mainID: UUID = UUID()) -> [RelayChat] {
        [RelayChat(id: mainID, title: museName, symbol: "bubble.left.and.bubble.right")]
    }
    var visibleChats: [RelayChat] { RelayChat.orderedByActivity(chats.filter { !$0.isLegacyStarter }, messages: messages) }
    var earlierChats: [RelayChat] { RelayChat.orderedByActivity(chats.filter(\.isLegacyStarter), messages: messages) }
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
        let saved = Archive(account: credentialNodeID ?? "", revision: revision, chats: chats, messages: messages, journal: journal, museName: museName, personName: personName, avatarRevision: avatarRevision, audioPresentations: audioPresentations)
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
    func becameActive() {
        transcriptionAuthorized = VoiceTranscriber.authorized
        transcriptionPermissionDenied = VoiceTranscriber.permissionDenied
        relay.refresh(); publish(); queueRecoveries(); startProcessing()
    }
    var blockedVoiceNotes: Int { journal.entries.filter { $0.delivery == .received && $0.transcriptionBlocked == true }.count }
    func enableTranscription() async {
        guard UIApplication.shared.applicationState == .active else { return }
        transcriptionAuthorized = await VoiceTranscriber.authorize()
        transcriptionPermissionDenied = VoiceTranscriber.permissionDenied
        if transcriptionAuthorized { retryVoiceNotes() }
    }
    func saveTranscriptionLocale() { UserDefaults.standard.set(transcriptionLocale, forKey: "voice-transcription-locale") }
    func retryVoiceNotes() {
        journal.retryTranscriptions(); changed(); startProcessing()
    }
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
                recordAudioDiagnostic("Muse turn: accepted")
                journal.entries[index].acceptedID = messageID
                if let chat = chats.firstIndex(where: { $0.id == journal.entries[index].request.chatID }) { chats[chat].exists = true }
                setDelivery(id, .accepted); status = "Waiting for \(museName)…"; changed()
            case .reply(let id, let text, let done):
                guard let requestID = activeRequest, let entry = journal.entries.first(where: { $0.id == requestID }) else { continue }
                if messages.first(where: { $0.id == id })?.text != text, let index = chats.firstIndex(where: { $0.id == entry.request.chatID }) { chats[index].updatedAt = .now }
                if let index = messages.firstIndex(where: { $0.id == id }) { messages[index].text = text }
                else { messages.append(RelayMessage(id: id, requestID: requestID, chatID: entry.request.chatID, role: "muse", text: text)) }
                if done {
                    recordAudioDiagnostic("Muse turn: reply text completed")
                }
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
            case .audioPresentation(let id, let reference):
                guard let requestID = activeRequest, let entry = journal.entries.first(where: { $0.id == requestID }),
                      messages.contains(where: { $0.id == id && $0.chatID == entry.request.chatID && $0.role == "muse" }) else { continue }
                var saved = reference
                if let previous = audioPresentations[id], previous.path == reference.path { saved.accessDenied = previous.accessDenied }
                audioPresentations[id] = saved; changed()
            case .topic(let sessionID, let title):
                guard let id = UUID(uuidString: sessionID), let index = chats.firstIndex(where: { $0.id == id }), chats[index].serverTitle != title else { continue }
                chats[index].serverTitle = title; changed()
            case .finished:
                if let id = activeRequest { setDelivery(id, .complete) }
                activeRequest = nil; status = "Ready for your Watch"; changed()
            case .failure(let issue):
                if fetchingAudioOnly { continue }
                if issue.isSavedReplyUnavailable, let id = activeRequest {
                    stopUnavailableRecovery(id, issue: issue); continue
                }
                let message = issue.localizedDescription
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
                if let index = updated.entries.firstIndex(where: { $0.id == request.id }) {
                    // Request text only; preserve legacy audio preferences in older journal entries.
                    updated.entries[index].voiceReply = false
                    updated.entries[index].askForVoiceNote = false
                }
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
        if let i = messages.firstIndex(where: { $0.id == entry.id.uuidString }) {
            messages[i].delivery = entry.delivery; messages[i].detail = entry.detail
            if let transcript = entry.transcript { messages[i].text = transcript }
        }
    }
    func retryConnection() { error = nil; attemptedRecoveries = []; journal.retryTranscriptions(); changed(); queueRecoveries(); startProcessing(); publish() }
    var unavailableReplyCount: Int { journal.entries.filter { $0.recoveryStopped == true }.count }
    private func stopUnavailableRecovery(_ id: UUID, issue: MuseError) {
        journal.stopReplyRecovery(id, detail: issue.localizedDescription)
        if let entry = journal.entries.first(where: { $0.id == id }) { applyEntry(entry) }
        activeRequest = nil; connected = false; error = nil; status = "Ready for your Watch"; changed()
    }
    private func queueRecoveries() {
        for chat in chats {
            if let last = journal.entries.last(where: { $0.request.chatID == chat.id }), last.canRecoverReply, !attemptedRecoveries.contains(last.id) { recoveryIDs.insert(last.id) }
        }
    }
    private var nextEntry: JournalEntry? {
        journal.entries.first(where: \.canPrepare) ?? journal.entries.last(where: { $0.canRecoverReply && recoveryIDs.contains($0.id) && !attemptedRecoveries.contains($0.id) })
    }
    private func startProcessing() {
        guard pump == nil, !busy, paired, storageReady, nextEntry != nil || !audioRequests.isEmpty else { return }
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
            if !audioBackgroundExpired, restartAfterRecovery || (!audioRequests.isEmpty && nextEntry == nil) { restartAfterRecovery = false; Task { [weak self] in self?.startProcessing() } }
        }
        while let entry = nextEntry, paired, storageReady, !audioBackgroundExpired {
            let request = entry.request
            let isRecovery = entry.acceptedID != nil; monitoringRecovery = isRecovery
            if isRecovery { attemptedRecoveries.insert(request.id); recoveryIDs.remove(request.id) }
            activeRequest = request.id; error = nil
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Muse Watch message") { [weak self] in Task { @MainActor in await self?.expireBackground() } }
            }
            do {
                if !isRecovery, request.audioSHA256 != nil, entry.transcript == nil {
                    setDelivery(request.id, .connecting, detail: "Transcribing on iPhone…"); status = "Transcribing voice note…"; try persist(); publish()
                    let file = directory.appendingPathComponent("WatchTransfers").appendingPathComponent(request.id.uuidString + ".wav")
                    let data = try Data(contentsOf: file)
                    try VoicePayload.validateWAV(data)
                    guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == request.audioSHA256 else { throw RelayError.invalid }
                    recordAudioDiagnostic("Voice input: transcribing locally")
                    let text = try await transcriber.transcribe(file, locale: transcriptionLocale)
                    guard activeRequest == request.id else { throw VoiceTranscriptionError.cancelled }
                    try journal.saveTranscript(text, for: request.id)
                    if let updated = journal.entries.first(where: { $0.id == request.id }) { applyEntry(updated) }
                    try persist(); publish() // Durable transcript precedes any Muse submission.
                    recordAudioDiagnostic("Voice input: transcript saved")
                }
                guard let prepared = journal.entries.first(where: { $0.id == request.id }) else { throw RelayError.invalid }
                let outgoingText = isRecovery ? "" : try prepared.outgoingText(includeVoiceRequest: false)
                setDelivery(request.id, isRecovery ? .accepted : .connecting); try persist(); publish()
                guard let bytes = try SecureStore.read("device-credentials"), let chat = chats.first(where: { $0.id == request.chatID }) else { throw MuseError.rejectedCredentials }
                let credentials = try JSONDecoder().decode(DeviceCredentials.self, from: bytes)
                try await client.connect(credentials: credentials, sessionID: chat.id.uuidString.lowercased(), existingChat: chat.exists, resumeAcceptedMessageID: entry.acceptedID, voiceReply: false, waitForVoiceNote: false)
                guard activeRequest == request.id else { throw MuseError.interrupted }
                connected = true
                if !isRecovery {
                    setDelivery(request.id, .sending); try persist(); publish()
                    recordAudioDiagnostic("Muse input: text only; attachments 0; text output requested")
                    _ = try await client.sendText(outgoingText, voiceReply: false, waitForVoiceNote: false)
                }
                while activeRequest == request.id { try await Task.sleep(for: .milliseconds(200)) }
                await client.disconnect(); connected = false; endBackground()
                if journal.entries.first(where: { $0.id == request.id })?.recoveryStopped == true { continue }
                if journal.entries.first(where: { $0.id == request.id })?.delivery != .complete { break }
            } catch {
                if let issue = error as? VoiceTranscriptionError {
                    if let index = journal.entries.firstIndex(where: { $0.id == request.id }), journal.entries[index].acceptedID == nil {
                        journal.entries[index].transcriptionBlocked = true
                        setDelivery(request.id, .received, detail: issue.localizedDescription)
                    }
                    recordAudioDiagnostic("Voice input: \(issue.diagnostic); Muse submission skipped")
                    activeRequest = nil; status = "Voice note needs attention on iPhone"; changed()
                    continue // A blocked voice note must not block typed messages or other chats.
                }
                if let issue = error as? MuseError, issue.isSavedReplyUnavailable, entry.acceptedID != nil {
                    stopUnavailableRecovery(request.id, issue: issue)
                    await client.disconnect(); continue
                }
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
        transcriber.cancel()
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
        messages[index].replyAudio = audio; messages[index].replyAudioState = .ready; messages[index].detail = nil
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
        if let index = messages.firstIndex(where: { $0.id == request.messageID }) { messages[index].replyAudioState = .preparing; messages[index].detail = nil }
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
                let data: Data
                if let reference = audioPresentations[request.messageID] {
                    recordAudioDiagnostic("Audio presentation: fetching workspace media")
                    data = try await client.replyAudio(presentation: reference)
                } else { data = try await client.replyAudio(messageID: request.messageID) }
                guard request.account == credentialNodeID, let index = messages.firstIndex(where: { $0.id == request.messageID && $0.chatID == request.chatID && $0.role == "muse" }) else { throw RelayError.invalid }
                try cacheReplyAudio(data, at: index)
            } catch {
                if case ReplyAudioError.http(let status) = error { recordAudioDiagnostic("Audio unavailable HTTP \(status)") }
                else { recordAudioDiagnostic("Audio unavailable code \((error as NSError).code)") }
                if (error as? MuseError) == .rejectedCredentials { paired = false; self.error = "Reconnect your Muse account." }
                if let index = messages.firstIndex(where: { $0.id == request.messageID && $0.chatID == request.chatID }) { messages[index].replyAudioState = .unavailable }
                if case ReplyAudioError.http(403) = error, audioPresentations[request.messageID] != nil {
                    audioPresentations[request.messageID]?.accessDenied = true
                    if let index = messages.firstIndex(where: { $0.id == request.messageID && $0.chatID == request.chatID }) {
                        messages[index].detail = "Muse denied this voice-note download (403). Listen in official Muse. Your text is saved."
                    }
                }
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
    func testConnection() async {
        guard paired, !busy, pump == nil else { return }
        busy = true; status = "Checking Muse connection…"; error = nil; publish()
        do {
            guard let bytes = try SecureStore.read("device-credentials") else { throw MuseError.rejectedCredentials }
            // Verify registration and the SDK's live, unscoped listener without creating a chat or posting a message.
            try await client.connect(credentials: JSONDecoder().decode(DeviceCredentials.self, from: bytes), sessionID: chats.first?.id.uuidString.lowercased() ?? UUID().uuidString.lowercased())
            status = "Connection checked · ready for your Watch"; error = nil
        } catch {
            self.error = error.localizedDescription; status = "Check your Muse connection"
            if (error as? MuseError) == .rejectedCredentials { paired = false }
        }
        await client.disconnect(); connected = false; busy = false; publish(); startProcessing()
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
        messages = []; journal = RelayJournal(); audioPresentations = [:]; error = nil
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
