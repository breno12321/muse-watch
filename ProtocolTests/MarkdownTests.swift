import XCTest
@testable import MuseCore

final class MarkdownTests: XCTestCase {
    func testHeadingsListsAndParagraphsKeepTheirStructure() {
        let markdown = MuseMarkdown("# A **plan**\n\nA thought.\nAnother line.\n\n1. First\n   wrapped detail\n   - Nested\n- [x] Finished\n\n> Keep it simple.\n> One step.\n\n---")
        XCTAssertEqual(markdown.blocks, [
            .init(kind: .heading(1), text: "A **plan**"),
            .init(kind: .paragraph, text: "A thought.\nAnother line."),
            .init(kind: .listItem(marker: "1.", depth: 0, checked: nil), text: "First\nwrapped detail"),
            .init(kind: .listItem(marker: "•", depth: 1, checked: nil), text: "Nested"),
            .init(kind: .listItem(marker: "•", depth: 0, checked: true), text: "Finished"),
            .init(kind: .quote, text: "Keep it simple.\nOne step."),
            .init(kind: .divider, text: "")
        ])
    }

    func testCodeKeepsLiteralWhitespaceAndHandlesAnUnfinishedStream() {
        let markdown = MuseMarkdown("```swift\nlet label = \"**literal**\"\n  print(label)\n```\n\n~~~\nunfinished\n")
        XCTAssertEqual(markdown.blocks, [
            .init(kind: .code(language: "swift"), text: "let label = \"**literal**\"\n  print(label)"),
            .init(kind: .code(language: nil), text: "unfinished\n")
        ])
    }

    func testInlineFormattingKeepsEmphasisCodeLinksAndNewlines() {
        let value = MuseMarkdown.inline("**Bold** and *gentle* `code`\n[Read](https://example.com)")
        XCTAssertEqual(String(value.characters), "Bold and gentle code\nRead")
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertTrue(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        XCTAssertEqual(value.runs.compactMap(\.link).first?.absoluteString, "https://example.com")
        let unsupported = MuseMarkdown.inline("[Settings](custom-app://settings) [File](file:///private/data)")
        XCTAssertEqual(String(unsupported.characters), "Settings File")
        XCTAssertTrue(unsupported.runs.allSatisfy { $0.link == nil })
        let image = MuseMarkdown.inline("![A flower](https://example.com/image.png)")
        XCTAssertEqual(String(image.characters), "A flower")
        XCTAssertTrue(image.runs.allSatisfy { $0.imageURL == nil })
    }

    func testTablesKeepEscapedPipesAndInlineCodeInsideTheirCells() {
        let markdown = MuseMarkdown("| Choice | Why |\n| :--- | ---: |\n| **A** | `x|y` |\n| B | keep \\| literal |\n\nA | plain sentence")
        XCTAssertEqual(markdown.blocks, [
            .init(kind: .table(headers: ["Choice", "Why"], rows: [["**A**", "`x|y`"], ["B", "keep \\| literal"]]), text: ""),
            .init(kind: .paragraph, text: "A | plain sentence")
        ])
        XCTAssertEqual(MuseMarkdown("A | B\nnot | a separator").blocks,
            [.init(kind: .paragraph, text: "A | B\nnot | a separator")])
        XCTAssertEqual(MuseMarkdown("Name | Detail\n--- | ---\nCal | Listening").blocks,
            [.init(kind: .table(headers: ["Name", "Detail"], rows: [["Cal", "Listening"]]), text: "")])
    }

    func testPlainTextUnicodeAndSetextHeadingsRemainReadable() {
        XCTAssertEqual(MuseMarkdown("Café 🌱\r\n\r\nA title\r\n=======\r\n\r\n#hashtag\r\n2.5 km").blocks, [
            .init(kind: .paragraph, text: "Café 🌱"),
            .init(kind: .heading(1), text: "A title"),
            .init(kind: .paragraph, text: "#hashtag\n2.5 km")
        ])
    }

    func testMuseStructuredTranscriptPreservesMarkdownForTheRenderer() throws {
        let turn = TurnAccumulator(sessionID: "rich-chat")
        _ = try turn.acknowledge(["session_id": "rich-chat", "is_thread": true, "message_id": "user"])
        let reply = try turn.feed([
            "type": "event", "event": "delta.message_done",
            "payload": ["session_id": "rich-chat", "message_id": "assistant", "parent_message_id": "user",
                "transcript": ["messages": [["id": "assistant", "role": "assistant", "content": [
                    ["type": "text", "text": "## A **plan**"],
                    ["type": "text", "text": "- First step\n- `Second` step"]
                ]]]]]
        ])
        XCTAssertEqual(reply.first?.text, "## A **plan**\n- First step\n- `Second` step")
        XCTAssertEqual(reply.first?.done, true)
        XCTAssertEqual(MuseMarkdown(try XCTUnwrap(reply.first?.text)).blocks.count, 3)
    }
}
