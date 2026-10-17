import XCTest
@testable import MuseCore

final class ChatRenameTests: XCTestCase {
    func testRenameIsScopedMetadataAndDuplicateDeliveryIsIdempotent() throws {
        let chat = RelayChat(title: "Chat", symbol: "bubble", exists: true)
        let edit = ChatRename(account: "test-account", chatID: chat.id, title: "Voice ideas", revision: 1)
        var chats = [chat]
        XCTAssertThrowsError(try edit.apply(to: &chats, account: "other-account"))
        XCTAssertEqual(chats, [chat])
        XCTAssertTrue(try edit.apply(to: &chats, account: "test-account"))
        XCTAssertFalse(try edit.apply(to: &chats, account: "test-account"))
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats[0].displayTitle, "Voice ideas")
        XCTAssertTrue(chats[0].exists)
        XCTAssertEqual(chats[0].nameRevision, 1)
    }
    func testOutOfOrderTransfersAndConcurrentPhoneEditsKeepTheNewerName() throws {
        let chat = RelayChat(title: "Chat", symbol: "bubble")
        var chats = [chat]
        let old = ChatRename(account: "test", chatID: chat.id, title: "Old name", revision: 1)
        let latest = ChatRename(account: "test", chatID: chat.id, title: "Latest name", revision: 2)
        XCTAssertTrue(try latest.apply(to: &chats, account: "test"))
        XCTAssertFalse(try old.apply(to: &chats, account: "test"))
        try chats[0].rename("Edited on iPhone")
        XCTAssertEqual(chats[0].nameRevision, 3)
        XCTAssertFalse(try latest.apply(to: &chats, account: "test"))
        let tied = ChatRename(account: "test", chatID: chat.id, title: "Concurrent Watch edit", revision: 3)
        XCTAssertFalse(try tied.apply(to: &chats, account: "test"))
        XCTAssertEqual(chats[0].displayTitle, "Edited on iPhone")
    }
    func testEmptyWatchChatCanBeNamedWithoutCreatingAServerSession() throws {
        let chat = RelayChat(title: "Chat 1", symbol: "bubble")
        let edit = ChatRename(account: "test", chatID: chat.id, title: "New notes", revision: 1, newChat: chat)
        var chats: [RelayChat] = []
        let decoded = try JSONDecoder().decode(ChatRename.self, from: JSONEncoder().encode(edit))
        XCTAssertTrue(try decoded.apply(to: &chats, account: "test"))
        XCTAssertEqual(chats[0].id, chat.id)
        XCTAssertFalse(chats[0].exists)
        XCTAssertEqual(chats[0].displayTitle, "New notes")
        chats[0].exists = true
        XCTAssertFalse(try decoded.apply(to: &chats, account: "test"))
        XCTAssertTrue(chats[0].exists)
    }
    func testInvalidNamesScopesAndForgedIntroductionsAreRejected() throws {
        let chat = RelayChat(title: "Chat", symbol: "bubble")
        for title in ["", " ", "Untrimmed ", "Two\nlines", String(repeating: "a", count: 81)] {
            XCTAssertThrowsError(try ChatRename(account: "test", chatID: chat.id, title: title, revision: 1).validate())
        }
        XCTAssertThrowsError(try ChatRename(account: "", chatID: chat.id, title: "Name", revision: 1).validate())
        XCTAssertThrowsError(try ChatRename(account: "test", chatID: chat.id, title: "Name", revision: 0).validate())
        XCTAssertThrowsError(try ChatRename(account: "test", chatID: chat.id, title: "Name", revision: .max).validate())
        XCTAssertThrowsError(try ChatRename(account: "test", chatID: UUID(), title: "Name", revision: 1, newChat: chat).validate())
        var forged = chat; forged.exists = true
        XCTAssertThrowsError(try ChatRename(account: "test", chatID: chat.id, title: "Name", revision: 1, newChat: forged).validate())
        var chats: [RelayChat] = []
        XCTAssertThrowsError(try ChatRename(account: "test", chatID: chat.id, title: "Name", revision: 1).apply(to: &chats, account: "test"))
        XCTAssertTrue(chats.isEmpty)
    }
    func testLegacyChatStartsRevisionOnFirstManualEditAndResetAdvancesIt() throws {
        let chat = RelayChat(title: "Legacy", symbol: "bubble")
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as? [String: Any])
        raw.removeValue(forKey: "nameRevision")
        var restored = try JSONDecoder().decode(RelayChat.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(restored.nameRevision)
        try restored.rename("Renamed")
        XCTAssertEqual(restored.nameRevision, 1)
        try restored.rename(nil)
        XCTAssertEqual(restored.nameRevision, 2)
        XCTAssertEqual(restored.displayTitle, "Legacy")
    }
}
