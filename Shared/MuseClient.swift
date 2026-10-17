import Foundation

public enum MuseClientEvent: Sendable {
    case status(String)
    case diagnostic(String)
    case accepted(sessionID: String, messageID: String)
    case reply(id: String, text: String, done: Bool)
    case failure(String)
    case finished
}
public actor MuseClient {
    public nonisolated let events: AsyncStream<MuseClientEvent>
    private let sink: AsyncStream<MuseClientEvent>.Continuation
    private var socket: URLSessionWebSocketTask?
    private var network: URLSession?
    private var transport: NoiseTransport?
    private var reader: Task<Void, Never>?
    private var writeTail: Task<Void, Error>?
    private var credentials: DeviceCredentials?
    private var connecting = false
    private var connectionID = UUID()
    private var controlID: UInt64 = 0, subscriptionID: UInt64 = 0
    private var registerID = "", sessionID = ""
    private var subscribedSessionID: String?
    private var controlBuffer = Data(), eventBuffer = Data()
    private var retiredStreams = Set<UInt64>()
    private struct Pending { var data = Data(); var status: UInt64 = 0; let continuation: CheckedContinuation<Data, Error> }
    private var pending: [UInt64: Pending] = [:]
    private var registration: CheckedContinuation<Void, Error>?
    private var subscription: CheckedContinuation<Void, Error>?
    private var timeoutTasks: [Task<Void, Never>] = []
    private var turn: TurnAccumulator?
    private var activeTurn = false
    private var retiredMessages = Set<String>()
    private var settleTask: Task<Void, Never>?
    private var turnID = UUID()
    private var busyActivity = false
    private var runningTasks = Set<String>()
    private var pingTask: Task<Void, Never>?
    private var credentialAccount = "device-credentials"

    public init() {
        let stream = AsyncStream<MuseClientEvent>.makeStream(bufferingPolicy: .bufferingNewest(128))
        events = stream.stream; sink = stream.continuation
    }
    public func connect(credentials value: DeviceCredentials, sessionID: String, credentialAccount: String = "device-credentials", existingChat: Bool = false, resumeAcceptedMessageID: String? = nil) async throws {
        guard !connecting else { throw MuseError.network("A connection attempt is already running.") }
        await disconnect(); connecting = true; defer { connecting = false }
        self.credentialAccount = credentialAccount
        try value.validate(); self.credentials = value; self.sessionID = sessionID
        if let id = resumeAcceptedMessageID {
            guard existingChat else { throw MuseError.invalid("A saved reply requires an existing conversation.") }
            turn = try TurnAccumulator(resumingSessionID: sessionID, acceptedMessageID: id); activeTurn = true; turnID = UUID(); busyActivity = false; runningTasks = []
        }
        sink.yield(.status("Finding your Muse…"))
        do {
            var vms: [MuseVM]
            do { vms = try await MuseAPI.fetchVMs(value) }
            catch MuseError.rejectedCredentials {
                let refreshed = try await MuseAPI.refresh(value)
                try SecureStore.save(JSONEncoder().encode(refreshed), account: credentialAccount)
                self.credentials = refreshed; vms = try await MuseAPI.fetchVMs(refreshed)
            }
            let vm = vms.first(where: \.isDefault) ?? vms[0]
            var url = URLComponents(); url.scheme = "wss"; url.host = "hatch.metaaivm.com"; url.path = "/v1/noise"; url.queryItems = [URLQueryItem(name: "vm_id", value: vm.id)]
            guard let endpoint = url.url else { throw MuseError.invalid("Invalid Muse connection address.") }
            var request = URLRequest(url: endpoint); request.setValue("Bearer " + vm.token, forHTTPHeaderField: "Authorization")
            let network = MuseAPI.session(); self.network = network
            let socket = network.webSocketTask(with: request); socket.maximumMessageSize = 4 * 1024 * 1024
            self.socket = socket; socket.resume()
            let epoch = connectionID
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await self?.handshakeTimeout(epoch)
            }
            defer { deadline.cancel() }
            sink.yield(.status("Establishing encrypted connection…"))
            let handshake = NoiseHandshake()
            try await socket.send(.data(handshake.message1()))
            guard case .data(let response) = try await socket.receive() else { throw MuseError.invalid("Muse returned an invalid Noise handshake.") }
            try handshake.message2(response); try await socket.send(.data(handshake.message3()))
            let keys = try handshake.split(); transport = NoiseTransport(send: keys.send, receive: keys.receive)
            reader = Task { [weak self] in await self?.readLoop(epoch) }
            sink.yield(.status("Registering the paired device…"))
            try await registerDevice()
            sink.yield(.status("Subscribing to your Muse chat…"))
            try await subscribe(sessionID: existingChat ? sessionID : nil)
            sink.yield(.status("Connected to Muse"))
            if resumeAcceptedMessageID != nil {
                let id = turnID
                timeoutTasks.append(Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(90)) } catch { return }
                    await self?.expireReply(epoch, turnID: id)
                })
            }
            pingTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    await self?.ping(epoch)
                }
            }
        } catch {
            await disconnect()
            if (error as? MuseError) == .rejectedCredentials { try? SecureStore.delete(credentialAccount) }
            throw error
        }
    }
    private func ping(_ epoch: UUID) async {
        guard epoch == connectionID, let socket else { return }
        socket.sendPing { _ in }
    }
    public func currentCredentials() -> DeviceCredentials? { credentials }
    public func usePairedCredentialStore() { credentialAccount = "device-credentials" }
    public func refreshCredentials() async throws {
        guard !activeTurn, !connecting, let credentials else { throw MuseError.network("Finish the current request before testing credential refresh.") }
        let updated = try await MuseAPI.refresh(credentials)
        try SecureStore.save(JSONEncoder().encode(updated), account: credentialAccount)
        self.credentials = updated
    }
    private func handshakeTimeout(_ epoch: UUID) {
        guard epoch == connectionID, connecting else { return }
        socket?.cancel(with: .goingAway, reason: nil)
    }
    public func disconnect(reason: MuseError = .interrupted) async {
        connectionID = UUID(); reader?.cancel(); reader = nil
        settleTask?.cancel(); settleTask = nil; pingTask?.cancel(); pingTask = nil; retiredMessages = []
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        network?.invalidateAndCancel(); network = nil; transport = nil
        writeTail?.cancel(); writeTail = nil
        for task in timeoutTasks { task.cancel() }; timeoutTasks = []
        registration?.resume(throwing: reason); registration = nil
        subscription?.resume(throwing: reason); subscription = nil
        for value in pending.values { value.continuation.resume(throwing: reason) }; pending = [:]
        controlBuffer = Data(); eventBuffer = Data(); turn = nil; activeTurn = false
        retiredStreams = []; controlID = 0; subscriptionID = 0; subscribedSessionID = nil
    }
    private func write(_ frames: [Data]) async throws {
        guard let socket else { throw MuseError.interrupted }
        let previous = writeTail
        let task = Task { try await previous?.value; for frame in frames { try Task.checkCancellation(); try await socket.send(.data(frame)) } }
        writeTail = task; try await task.value
    }
    private func registerDevice() async throws {
        guard let transport, let credentials else { throw MuseError.interrupted }
        let request = try transport.request(path: "/link-control", streaming: true); controlID = request.id; registerID = UUID().uuidString
        try await write(request.frames)
        // Minimal device metadata: no system.run, file access, or remote execution.
        let data = try jsonData(["type": "req", "id": registerID, "method": "link.register", "params": [
            "node_id": credentials.identity.nodeID, "display_name": "Muse Watch", "platform": "ios", "version": "1.0.0",
            "device_family": "homehub", "model_id": "muse-watch-companion", "is_wakeup_supported": false, "commands_v2": [:]
        ]])
        let prefix = Data.littleEndian(UInt64(data.count)).prefix(4)
        let frames = try transport.body(stream: controlID, data: Data(prefix) + data)
        try await withCheckedThrowingContinuation { continuation in
            registration = continuation
            timeoutTasks.append(Task { [weak self] in
                do { try await self?.write(frames) } catch { await self?.fail(error) }
            })
        }
    }
    private func subscribe(sessionID targetSession: String? = nil) async throws {
        guard let transport else { throw MuseError.interrupted }
        // The new side chat is created by the first /chat/stream request. The
        // SDK permits an unscoped subscription before it exists; correlation
        // below discards every event outside this connection's owned session.
        let old = subscriptionID
        if old != 0 { retiredStreams.insert(old) }
        let body: [String: String] = targetSession.map { ["session_id": $0] } ?? [:]
        let request = try transport.request(path: "/chat/subscribe", body: jsonData(body), headers: [("Content-Type", "application/json"), ("Accept", "application/x-ndjson")])
        eventBuffer = Data()
        subscriptionID = request.id; subscribedSessionID = targetSession
        try await withCheckedThrowingContinuation { continuation in
            subscription = continuation
            timeoutTasks.append(Task { [weak self] in do { try await self?.write(request.frames) } catch { await self?.fail(error) } })
        }
        // Open the new listener before closing the old stream.
        if old != 0 { try await write(transport.reset(stream: old)) }
    }
    public func sendText(_ text: String) async throws -> String {
        guard let credentials, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 16384 else { throw MuseError.invalid("Enter a message of up to 16 KiB.") }
        return try await post(try jsonData(["message": text, "output_modality": "text", "device_id": credentials.identity.nodeID, "session_id": sessionID]))
    }
    public func sendVoice(_ data: Data, text: String = "") async throws -> String {
        guard let credentials else { throw MuseError.interrupted }
        return try await post(VoicePayload.body(data, text: text, deviceID: credentials.identity.nodeID, sessionID: sessionID))
    }
    private func post(_ body: Data) async throws -> String {
        guard !activeTurn, let transport, socket != nil else { throw MuseError.network("Connect to Muse and finish the current turn first.") }
        activeTurn = true; turnID = UUID(); busyActivity = false; runningTasks = []
        turn = TurnAccumulator(sessionID: sessionID, retiredMessageIDs: retiredMessages)
        let multipart = body.count > 64 * 1024
        let request = try transport.request(path: "/chat/stream", body: multipart ? Data() : body, streaming: multipart, headers: [("Content-Type", "application/json"), ("x-request-id", UUID().uuidString), ("x-app-id", "musegadget")])
        do {
            let raw: Data = try await withCheckedThrowingContinuation { continuation in
                pending[request.id] = Pending(continuation: continuation)
                timeoutTasks.append(Task { [weak self] in
                    do { try await self?.upload(request.frames, body: multipart ? body : nil, stream: request.id) }
                    catch { await self?.fail(error) }
                })
                timeoutTasks.append(Task { [weak self] in try? await Task.sleep(for: .seconds(60)); guard !Task.isCancelled else { return }; await self?.expireRequest(request.id) })
            }
            let buffered = try turn?.acknowledge(jsonObject(raw)) ?? []
            if let acceptedID = turn?.acknowledgedID { sink.yield(.accepted(sessionID: sessionID, messageID: acceptedID)) }
            for reply in buffered { emit(reply) }
            // A new side chat exists only after its first acknowledged post.
            // Switch promptly to its scoped listener, then retire the old stream.
            if subscribedSessionID != sessionID { try await subscribe(sessionID: sessionID) }
            let epoch = connectionID, currentTurn = turnID
            timeoutTasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(90)); guard !Task.isCancelled else { return }
                await self?.expireReply(epoch, turnID: currentTurn)
            })
            return turn?.acknowledgedID ?? ""
        } catch { activeTurn = false; turn = nil; throw error }
    }
    private func upload(_ frames: [Data], body: Data?, stream: UInt64) async throws {
        try await write(frames)
        guard let body else { return }
        for offset in stride(from: 0, to: body.count, by: 16384) {
            guard let transport else { throw MuseError.interrupted }
            let part = Data(body.dropFirst(offset).prefix(16384))
            try await write(transport.body(stream: stream, data: part, ended: offset + part.count == body.count))
        }
    }
    private func expireRequest(_ id: UInt64) {
        pending.removeValue(forKey: id)?.continuation.resume(throwing: MuseError.interrupted)
    }
    private func expireReply(_ epoch: UUID, turnID: UUID) async {
        guard epoch == connectionID, turnID == self.turnID, activeTurn else { return }
        await fail(MuseError.network("Muse accepted the message, but no completed reply arrived. Open the conversation in Muse. No automatic resend."))
    }
    private func readLoop(_ epoch: UUID) async {
        do {
            while !Task.isCancelled, epoch == connectionID, let socket, let transport {
                guard case .data(let frame) = try await socket.receive() else { throw MuseError.invalid("Unexpected text on encrypted connection.") }
                if let packet = try transport.decode(frame) { try process(packet) }
            }
        } catch { if epoch == connectionID, !Task.isCancelled { await fail(error) } }
    }
    private func fail(_ error: Error) async {
        if (error as? MuseError) == .rejectedCredentials { try? SecureStore.delete(credentialAccount); credentials = nil }
        let reason = (error as? MuseError) ?? .network("Encrypted Muse connection closed (network error \((error as NSError).code)).")
        await disconnect(reason: reason)
        // Do not surface remote response bodies or authorization headers in UI/logs.
        sink.yield(.failure(reason.localizedDescription))
    }
    private func process(_ packet: ServicePacket) throws {
        if retiredStreams.contains(packet.streamID) { return }
        if packet.status == 401 || packet.status == 403 { throw MuseError.rejectedCredentials }
        let streamName = packet.streamID == controlID ? "device registration (/link-control)" : (packet.streamID == subscriptionID ? "chat subscription (/chat/subscribe)" : "message request")
        if packet.kind == 5 { throw MuseError.network("Muse reset the \(streamName) stream.") }
        if packet.status >= 400 { throw MuseError.network("Muse \(streamName) returned HTTP \(packet.status).") }
        if packet.streamID == controlID {
            controlBuffer += packet.data
            guard controlBuffer.count <= 4 * 1024 * 1024 else { throw MuseError.invalid("Muse control message exceeds limit.") }
            while controlBuffer.count >= 4 {
                let length = [UInt8](controlBuffer.prefix(4)).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
                guard length <= 4 * 1024 * 1024 else { throw MuseError.invalid("Muse control message exceeds limit.") }
                guard controlBuffer.count >= length + 4 else { break }
                let object = try jsonObject(Data(controlBuffer.dropFirst(4).prefix(length))); controlBuffer = Data(controlBuffer.dropFirst(4 + length))
                if object["id"] as? String == registerID, object["method"] == nil {
                    guard object["error"] == nil || object["error"] is NSNull, object["ok"] as? Bool != false else { throw MuseError.network("Muse refused device registration.") }
                    registration?.resume(); registration = nil
                }
                if ["link.unpaired", "node.unpaired"].contains(object["event"] as? String ?? "") { throw MuseError.rejectedCredentials }
                if object["method"] as? String == "link.invoke" { throw MuseError.network("Muse requested an unsupported device capability. No command was executed.") }
            }
            if packet.ended { throw MuseError.network("Muse closed the device control stream.") }
        } else if packet.streamID == subscriptionID {
            if packet.status >= 200 {
                sink.yield(.diagnostic("Subscription HTTP \(packet.status)"))
                subscription?.resume(); subscription = nil
            }
            if !packet.data.isEmpty { sink.yield(.diagnostic("Subscription received \(packet.data.count) bytes")) }
            eventBuffer += packet.data
            guard eventBuffer.count <= 262144 else { throw MuseError.invalid("Muse chat event exceeds limit.") }
            while let newline = eventBuffer.firstIndex(of: 10) {
                let line = Data(eventBuffer[..<newline]); eventBuffer = Data(eventBuffer[eventBuffer.index(after: newline)...])
                if !line.isEmpty {
                    let event = try jsonObject(line)
                    let knownNames: Set<String> = ["delta.message_start", "delta.text_append", "delta.message_done", "message.assistant", "message.user", "agent.status", "task.status"]
                    let name = event["event"] as? String ?? ""
                    let payload = event["payload"] as? [String: Any] ?? [:]
                    let eventSession = payload["session_id"] as? String ?? event["session_id"] as? String
                    let matches = eventSession == sessionID || (UUID(uuidString: eventSession ?? "") != nil && UUID(uuidString: eventSession ?? "") == UUID(uuidString: sessionID))
                    let category = knownNames.contains(name) ? name : "other"
                    sink.yield(.diagnostic("Event \(category) · event type \(event["type"] as? String == "event") · own chat \(matches) · payload \(!payload.isEmpty)"))
                    if matches, activeTurn {
                        if name == "agent.status", let code = payload["activity_code"] as? String {
                            busyActivity = !["", "idle", "online"].contains(code)
                            if busyActivity { settleTask?.cancel() } else { scheduleSettlement() }
                        }
                        if name == "task.status", let taskID = payload["task_id"] as? String, let status = payload["status"] as? String {
                            if status == "running" { runningTasks.insert(taskID); settleTask?.cancel() }
                            else if ["completed", "failed", "errored", "cancelled", "canceled"].contains(status) { runningTasks.remove(taskID); scheduleSettlement() }
                        }
                    }
                    for reply in try turn?.feed(event) ?? [] { emit(reply) }
                }
            }
            if packet.ended { throw MuseError.network("Muse closed the chat subscription.") }
        } else if var request = pending[packet.streamID] {
            request.data += packet.data; if packet.status != 0 { request.status = packet.status }
            guard request.data.count <= 1024 * 1024 else { throw MuseError.invalid("Muse response exceeds limit.") }
            if packet.ended {
                pending.removeValue(forKey: packet.streamID)
                guard (200..<300).contains(request.status) else { request.continuation.resume(throwing: MuseError.network("Muse did not accept this message.")); return }
                request.continuation.resume(returning: request.data)
            } else { pending[packet.streamID] = request }
        }
    }
    private func emit(_ reply: TurnAccumulator.Reply) {
        sink.yield(.reply(id: reply.id, text: reply.text, done: reply.done))
        scheduleSettlement()
    }
    private func scheduleSettlement() {
        settleTask?.cancel()
        guard !busyActivity, runningTasks.isEmpty, turn?.allRepliesComplete == true else { return }
        let id = turnID
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            await self?.settle(id)
        }
    }
    private func settle(_ id: UUID) {
        guard id == turnID, activeTurn, !busyActivity, runningTasks.isEmpty, turn?.allRepliesComplete == true else { return }
        retiredMessages.formUnion(turn?.replyIDs ?? [])
        activeTurn = false; sink.yield(.finished)
    }
}
