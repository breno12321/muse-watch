#if os(macOS)
import Foundation
@MainActor final class RelayConnectivity {
    var onSnapshot: ((RelaySnapshot) -> Void)?
    var onStatus: ((Bool) -> Void)?
    var onReceipt: ((UUID) -> Void)?
    var onAsset: ((String, URL, String) -> Void)?
    var onReplyAudio: ((ReplyAudioTransfer, URL) -> Void)?
    func requestReplyAudio(_ asset: ReplyAudioRequest) {}
    func refresh() {}
    func enqueue(_ request: RelayRequest, audio: URL?) throws {}
}
#endif
