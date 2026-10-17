#if os(iOS) || os(watchOS)
import Foundation
import WatchConnectivity
import CryptoKit

@MainActor
final class RelayConnectivity: NSObject, WCSessionDelegate {
    nonisolated static let snapshotKey = "museSnapshot"
    var onRequest: ((RelayRequest, URL?) -> Bool)?
    var onSnapshot: ((RelaySnapshot) -> Void)?
    var onSync: ((Bool) -> Void)?
    var onChatRefresh: ((ChatRefreshRequest) -> Data?)?
    var onReceipt: ((UUID) -> Void)?
    var onStatus: ((Bool) -> Void)?
    var onAsset: ((String, URL, String) -> Void)?
    var onReplyAudio: ((ReplyAudioTransfer, URL) -> Void)?
    var onReplyAudioRequest: ((ReplyAudioRequest) -> Bool)?
    var onRename: ((ChatRename) -> Bool)?
    private nonisolated let incoming: URL
    private var session: WCSession? { WCSession.isSupported() ? .default : nil }
    private var activated: Bool { session?.activationState == .activated }
    private var immediateVoice = Set<UUID>()
    private var chatToRefresh: ChatRefreshRequest?
    private var incomingVoice: [UUID: (assembly: VoiceChunkAssembly, date: Date)] = [:]
    private var canSendImmediately: Bool {
        #if os(watchOS)
        // A Watch message can wake the iPhone companion; don't gate that wake on stale reachability.
        activated
        #else
        reachable
        #endif
    }
    override init() {
        incoming = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("WatchTransfers", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        session?.delegate = self; session?.activate()
    }
    var reachable: Bool { activated && session?.isReachable == true }
    func refresh(chat: ChatRefreshRequest? = nil) {
        if let chat { chatToRefresh = chat }
        guard activated else { session?.activate(); return }
        #if os(watchOS)
        if let data = session?.receivedApplicationContext[Self.snapshotKey] as? Data { receiveSnapshot(data) }
        // A normal sync still requests the full history/avatar transfer. Only chat opens
        // and reconnects use the focused response.
        let requestedChat = chat == chatToRefresh ? chat : nil
        var request: [String: Any] = ["sync": true]
        if let requestedChat, let bytes = try? JSONEncoder().encode(requestedChat) { request["chatRefresh"] = bytes }
        if canSendImmediately { session?.sendMessage(request, replyHandler: { [weak self] reply in
            guard let data = reply[Self.snapshotKey] as? Data else { return }
            Task { @MainActor in
                guard let self else { return }
                if let requestedChat {
                    guard data.count <= 55000, self.chatToRefresh == requestedChat,
                          let snapshot = try? JSONDecoder().decode(RelaySnapshot.self, from: data),
                          snapshot.account == requestedChat.account else { return }
                }
                self.receiveSnapshot(data)
            }
        }, errorHandler: { _ in }) }
        #endif
        onStatus?(reachable)
    }
    func publish(_ snapshot: RelaySnapshot) {
        guard activated, let data = try? snapshot.contextData() else { return }
        do { try session?.updateApplicationContext([Self.snapshotKey: data]) } catch { return }
        if reachable { session?.sendMessage([Self.snapshotKey: data], replyHandler: nil, errorHandler: { _ in }) }
    }
    func enqueue(_ request: RelayRequest, audio: URL? = nil) throws {
        guard activated, let session else { throw RelayError.invalid }
        let data = try JSONEncoder().encode(request)
        if let audio {
            let alreadyQueued = session.outstandingFileTransfers.contains { transfer in
                guard let bytes = transfer.file.metadata?["request"] as? Data,
                      let old = try? JSONDecoder().decode(RelayRequest.self, from: bytes) else { return false }
                return old.id == request.id
            }
            if !alreadyQueued { session.transferFile(audio, metadata: ["request": data]) }
            sendVoiceImmediately(request, audio: audio)
        } else {
            if !session.outstandingUserInfoTransfers.contains(where: { ($0.userInfo["request"] as? Data) == data }) { session.transferUserInfo(["request": data]) }
            if canSendImmediately { session.sendMessage(["request": data], replyHandler: { [weak self] reply in
                if reply["received"] as? Bool == true { Task { @MainActor in self?.finishTransfer(request.id) } }
            }, errorHandler: { _ in }) }
        }
    }
    private func finishTransfer(_ id: UUID) {
        onReceipt?(id)
        for transfer in session?.outstandingFileTransfers ?? [] {
            if let bytes = transfer.file.metadata?["request"] as? Data,
               (try? JSONDecoder().decode(RelayRequest.self, from: bytes))?.id == id { transfer.cancel() }
        }
        for transfer in session?.outstandingUserInfoTransfers ?? [] {
            if let bytes = transfer.userInfo["request"] as? Data,
               (try? JSONDecoder().decode(RelayRequest.self, from: bytes))?.id == id { transfer.cancel() }
        }
    }
    private func sendVoiceImmediately(_ request: RelayRequest, audio: URL) {
        #if os(watchOS)
        guard canSendImmediately, !immediateVoice.contains(request.id) else { return }
        immediateVoice.insert(request.id)
        Task { [weak self] in
            guard let self else { return }
            defer { self.immediateVoice.remove(request.id) }
            do {
                let data = try Data(contentsOf: audio), encoded = try JSONEncoder().encode(request)
                guard data.count > 0, data.count <= 2 * 1024 * 1024 else { return }
                for offset in stride(from: 0, to: data.count, by: VoiceChunkAssembly.chunkBytes) {
                    guard !Task.isCancelled else { return }
                    let chunk = data.subdata(in: offset..<min(data.count, offset + VoiceChunkAssembly.chunkBytes))
                    let received = try await self.sendChunk(["request": encoded, "audioChunk": chunk, "chunkIndex": offset / VoiceChunkAssembly.chunkBytes, "totalBytes": data.count])
                    if received { self.finishTransfer(request.id); return }
                }
            } catch { /* The durable file transfer remains queued, including after suspension. */ }
        }
        #endif
    }
    private func sendChunk(_ message: [String: Any]) async throws -> Bool {
        guard let session, activated else { throw RelayError.invalid }
        return try await withCheckedThrowingContinuation { continuation in
            session.sendMessage(message, replyHandler: { reply in
                guard reply["chunkReceived"] as? Bool == true else { continuation.resume(throwing: RelayError.invalid); return }
                continuation.resume(returning: reply["received"] as? Bool == true)
            }, errorHandler: { continuation.resume(throwing: $0) })
        }
    }
    private func receiveVoiceChunk(_ request: RelayRequest, chunk: Data, index: Int, totalBytes: Int) -> Bool? {
        do {
            incomingVoice = incomingVoice.filter { Date().timeIntervalSince($0.value.date) < 120 }
            if incomingVoice[request.id] == nil {
                guard incomingVoice.count < 3 else { throw RelayError.full }
                incomingVoice[request.id] = (try VoiceChunkAssembly(request: request, totalBytes: totalBytes), .now)
            }
            guard var pending = incomingVoice[request.id], pending.assembly.request == request, pending.assembly.totalBytes == totalBytes else { throw RelayError.duplicate }
            let complete = try pending.assembly.append(index: index, chunk: chunk)
            pending.date = .now; incomingVoice[request.id] = pending
            guard let complete else { return false }
            incomingVoice.removeValue(forKey: request.id)
            let destination = incoming.appendingPathComponent(request.id.uuidString + ".wav")
            if FileManager.default.fileExists(atPath: destination.path) {
                guard try Data(contentsOf: destination) == complete else { throw RelayError.duplicate }
            } else { try complete.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
            guard onRequest?(request, destination) == true else { throw RelayError.invalid }
            return true
        } catch { incomingVoice.removeValue(forKey: request.id); return nil }
    }
    func transferAsset(kind: String, url: URL, account: String) {
        guard activated, let session else { return }
        if !session.outstandingFileTransfers.contains(where: { $0.file.metadata?["kind"] as? String == kind }) { session.transferFile(url, metadata: ["kind": kind, "account": account]) }
    }
    func transferReplyAudio(_ asset: ReplyAudioTransfer, url: URL) {
        guard activated, let session, let metadata = try? JSONEncoder().encode(asset) else { return }
        if !session.outstandingFileTransfers.contains(where: { transfer in
            guard let bytes = transfer.file.metadata?["replyAudio"] as? Data else { return false }
            return (try? JSONDecoder().decode(ReplyAudioTransfer.self, from: bytes)) == asset
        }) {
            session.transferFile(url, metadata: ["replyAudio": metadata])
        }
    }
    func requestReplyAudio(_ asset: ReplyAudioRequest) {
        guard activated, let session, let metadata = try? JSONEncoder().encode(asset) else { return }
        if !session.outstandingUserInfoTransfers.contains(where: { transfer in
            guard let bytes = transfer.userInfo["replyAudioRequest"] as? Data else { return false }
            return (try? JSONDecoder().decode(ReplyAudioRequest.self, from: bytes)) == asset
        }) {
            session.transferUserInfo(["replyAudioRequest": metadata])
        }
        if canSendImmediately { session.sendMessage(["replyAudioRequest": metadata], replyHandler: { _ in }, errorHandler: { _ in }) }
    }
    func enqueueRename(_ edit: ChatRename) throws {
        try edit.validate()
        guard activated, let session else { throw RelayError.invalid }
        let bytes = try JSONEncoder().encode(edit)
        if !session.outstandingUserInfoTransfers.contains(where: { transfer in
            guard let data = transfer.userInfo["chatRename"] as? Data else { return false }
            return (try? JSONDecoder().decode(ChatRename.self, from: data)) == edit
        }) { session.transferUserInfo(["chatRename": bytes]) }
        if canSendImmediately { session.sendMessage(["chatRename": bytes], replyHandler: { _ in }, errorHandler: { _ in }) }
    }
    private func receiveSnapshot(_ data: Data) {
        guard data.count <= 2 * 1024 * 1024, let snapshot = try? JSONDecoder().decode(RelaySnapshot.self, from: data), snapshot.version == 1 else { return }
        if let chatToRefresh, snapshot.account != chatToRefresh.account { self.chatToRefresh = nil }
        onSnapshot?(snapshot)
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) { Task { @MainActor in self.refresh(chat: self.chatToRefresh); self.onSync?(false) } }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) { Task { @MainActor in self.refresh(chat: self.chatToRefresh); if self.reachable { self.onSync?(false) } } }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[Self.snapshotKey] as? Data else { return }
        Task { @MainActor in self.receiveSnapshot(data) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if let bytes = userInfo["chatRename"] as? Data, bytes.count < 20000,
           let edit = try? JSONDecoder().decode(ChatRename.self, from: bytes) {
            Task { @MainActor in _ = self.onRename?(edit) }; return
        }
        if let bytes = userInfo["replyAudioRequest"] as? Data, bytes.count < 20000,
           let asset = try? JSONDecoder().decode(ReplyAudioRequest.self, from: bytes) {
            Task { @MainActor in _ = self.onReplyAudioRequest?(asset) }; return
        }
        guard let data = userInfo["request"] as? Data, data.count <= 20000, let request = try? JSONDecoder().decode(RelayRequest.self, from: data) else { return }
        Task { @MainActor in _ = self.onRequest?(request, nil) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let data = message[Self.snapshotKey] as? Data { Task { @MainActor in self.receiveSnapshot(data) } }
        if message["sync"] as? Bool == true { Task { @MainActor in self.onSync?(true) } }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let reply = ConnectivityReply(replyHandler)
        if let bytes = message["chatRefresh"] as? Data {
            guard bytes.count <= 1024, let request = try? JSONDecoder().decode(ChatRefreshRequest.self, from: bytes) else { replyHandler([:]); return }
            Task { @MainActor in
                guard let data = self.onChatRefresh?(request) else { reply.send([:]); return }
                reply.send([Self.snapshotKey: data])
            }
            return
        }
        if let bytes = message["chatRename"] as? Data, bytes.count < 20000,
           let edit = try? JSONDecoder().decode(ChatRename.self, from: bytes) {
            Task { @MainActor in reply.send(["renamed": self.onRename?(edit) ?? false]) }; return
        }
        if let bytes = message["replyAudioRequest"] as? Data, bytes.count < 20000,
           let asset = try? JSONDecoder().decode(ReplyAudioRequest.self, from: bytes) {
            Task { @MainActor in reply.send(["queued": self.onReplyAudioRequest?(asset) ?? false]) }; return
        }
        if let data = message["request"] as? Data, data.count <= 20000, let request = try? JSONDecoder().decode(RelayRequest.self, from: data) {
            if let chunk = message["audioChunk"] as? Data, let index = message["chunkIndex"] as? Int, let total = message["totalBytes"] as? Int {
                Task { @MainActor in
                    let received = self.receiveVoiceChunk(request, chunk: chunk, index: index, totalBytes: total)
                    reply.send(["chunkReceived": received != nil, "received": received == true])
                }
            } else { Task { @MainActor in reply.send(["received": self.onRequest?(request, nil) ?? false]) } }
        } else { Task { @MainActor in self.onSync?(true); reply.send(self.session?.applicationContext ?? [:]) } }
    }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // WCSession deletes the incoming temporary file after this delegate returns.
        do {
            let size = try file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 3 * 1024 * 1024 else { return }
            if let bytes = file.metadata?["replyAudio"] as? Data, bytes.count < 20000 {
                let asset = try JSONDecoder().decode(ReplyAudioTransfer.self, from: bytes)
                try asset.validate(Data(contentsOf: file.fileURL))
                let destination = incoming.appendingPathComponent(UUID().uuidString + "." + asset.audio.fileExtension)
                try FileManager.default.copyItem(at: file.fileURL, to: destination)
                Task { @MainActor in
                    if let handler = self.onReplyAudio { handler(asset, destination) }
                    else { try? FileManager.default.removeItem(at: destination) }
                }
            } else if let bytes = file.metadata?["request"] as? Data, bytes.count < 20000 {
                let request = try JSONDecoder().decode(RelayRequest.self, from: bytes); try request.validate()
                guard let hash = request.audioSHA256 else { return }
                let data = try Data(contentsOf: file.fileURL)
                guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else { return }
                let destination = incoming.appendingPathComponent(request.id.uuidString + ".wav")
                if FileManager.default.fileExists(atPath: destination.path) {
                    guard try Data(contentsOf: destination) == data else { throw RelayError.duplicate }
                } else { try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
                Task { @MainActor in _ = self.onRequest?(request, destination) }
            } else if let kind = file.metadata?["kind"] as? String, ["avatar", "history"].contains(kind) {
                let destination = incoming.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: file.fileURL, to: destination)
                let assetAccount = file.metadata?["account"] as? String
                Task { @MainActor in
                    if kind == "history", let data = try? Data(contentsOf: destination) { self.receiveSnapshot(data); try? FileManager.default.removeItem(at: destination) }
                    else if let account = assetAccount { self.onAsset?(kind, destination, account) }
                    else { try? FileManager.default.removeItem(at: destination) }
                }
            }
        } catch { /* Sender retains the recording until the durable phone receipt. */ }
    }
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { Task { @MainActor in self.onSync?(true) } }
    #endif
}
private final class ConnectivityReply: @unchecked Sendable {
    private let handler: ([String: Any]) -> Void
    init(_ handler: @escaping ([String: Any]) -> Void) { self.handler = handler }
    @MainActor func send(_ value: [String: Any]) { handler(value) }
}
#endif
