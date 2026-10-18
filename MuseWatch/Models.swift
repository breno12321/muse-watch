import Foundation

struct Message: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, muse }
    let id: String
    let role: Role
    var text: String
    let date: Date
    var audioFile: String?
    var duration: TimeInterval?
    var saved: Bool
    var delivery: Delivery?
    var detail: String?
    var replyAudio: ReplyAudio? = nil
    var replyAudioState: ReplyAudioState? = nil
    var replyComplete: Bool? = nil
    var localSpeech: LocalSpeechStatus? = nil
    var speechFile: String? = nil
    var speechTextHash: String? = nil
    var speechPending: LocalSpeechRequest? = nil
    var speechRejected = false
}
struct Conversation: Identifiable, Equatable {
    let id: UUID
    var title: String
    var symbol: String
    var messages: [Message]
    var unread = false
    var earlier = false
    var activityDate: Date = .distantPast
}
struct VoiceDraft: Codable {
    let file: String
    let duration: TimeInterval
    let conversationID: UUID
}
func audioTime(_ seconds: TimeInterval) -> String {
    let value = seconds.isFinite ? max(0, Int(seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}
