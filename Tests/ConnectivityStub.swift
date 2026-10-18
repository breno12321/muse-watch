#if os(macOS)
import Foundation
@MainActor final class RelayConnectivity {
    var onSnapshot: ((RelaySnapshot) -> Void)?
    var onStatus: ((Bool) -> Void)?
    var onReceipt: ((UUID) -> Void)?
    var onAsset: ((String, URL, String) -> Void)?
    var onReplyAudio: ((ReplyAudioTransfer, URL) -> Void)?
    var onSpeechReceipt: ((UUID, Bool) -> Void)?
    var speechRequests: [LocalSpeechRequest] = []
    func enqueueSpeech(_ request: LocalSpeechRequest) throws { speechRequests.append(request) }
    func finishSpeechTransfer(_ id: UUID) {}
    func requestReplyAudio(_ asset: ReplyAudioRequest) {}
    func enqueueRename(_ edit: ChatRename) throws {}
    var requestedChats: [ChatRefreshRequest] = []
    func refresh(chat: ChatRefreshRequest? = nil) { if let chat { requestedChats.append(chat) } }
    func enqueue(_ request: RelayRequest, audio: URL?) throws {}
}
#endif
