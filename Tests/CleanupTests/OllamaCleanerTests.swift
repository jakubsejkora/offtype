import XCTest

import OfftypeCore
@testable import Cleanup

final class OllamaCleanerTests: XCTestCase {

    // MARK: - Response parsing (real token accounting)

    func testParseResponseExtractsTokensAndCleanedText() throws {
        // `message.content` is itself a JSON object because we request a `format` schema.
        let fixture = #"""
            {
              "model": "gemma3:4b",
              "created_at": "2026-06-28T00:00:00Z",
              "message": {
                "role": "assistant",
                "thinking": "user dictated a greeting",
                "content": "{\"cleaned\":\"Hello, world.\"}"
              },
              "done": true,
              "total_duration": 123456789,
              "prompt_eval_count": 42,
              "eval_count": 13
            }
            """#

        let parsed = try OllamaCleaner.parseResponse(Data(fixture.utf8))
        XCTAssertEqual(parsed.cleanedText, "Hello, world.")
        XCTAssertEqual(parsed.tokensUsed, 55)  // prompt_eval_count + eval_count
    }

    func testParseResponseMissingCountsDefaultToZero() throws {
        let fixture = #"""
            {
              "message": { "role": "assistant", "content": "{\"cleaned\":\"Fine.\"}" },
              "done": true
            }
            """#

        let parsed = try OllamaCleaner.parseResponse(Data(fixture.utf8))
        XCTAssertEqual(parsed.cleanedText, "Fine.")
        XCTAssertEqual(parsed.tokensUsed, 0)
    }

    func testParseResponseWithSchemaDroppedContentYieldsNilText() throws {
        // The schema-drop failure mode: content is a JSON object without the `cleaned` key.
        // Tokens were still spent, so they must still be reported.
        let fixture = #"""
            {
              "message": { "role": "assistant", "content": "{}" },
              "prompt_eval_count": 10,
              "eval_count": 0
            }
            """#

        let parsed = try OllamaCleaner.parseResponse(Data(fixture.utf8))
        XCTAssertNil(parsed.cleanedText)
        XCTAssertEqual(parsed.tokensUsed, 10)
    }

    func testParseResponseWithNonJSONContentYieldsNilText() throws {
        let fixture = #"""
            {
              "message": { "role": "assistant", "content": "not json at all" },
              "prompt_eval_count": 7,
              "eval_count": 3
            }
            """#

        let parsed = try OllamaCleaner.parseResponse(Data(fixture.utf8))
        XCTAssertNil(parsed.cleanedText)
        XCTAssertEqual(parsed.tokensUsed, 10)
    }

    // MARK: - Request shaping

    func testMakeChatRequestProducesGemmaChatBody() throws {
        let request = OllamaCleaner.makeChatRequest(
            text: "hello world",
            context: ["Offtype", "Kuba"],
            model: "gemma3:4b",
            think: true
        )

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "gemma3:4b")
        XCTAssertEqual(json["stream"] as? Bool, false)
        XCTAssertEqual(json["think"] as? Bool, true)  // schema-drop mitigation stays on

        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["temperature"] as? Double, 0)

        // Structured-output schema pins the reply to {"cleaned": "..."}.
        let format = try XCTUnwrap(json["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "object")
        XCTAssertEqual(format["required"] as? [String], ["cleaned"])
        let properties = try XCTUnwrap(format["properties"] as? [String: Any])
        let cleaned = try XCTUnwrap(properties["cleaned"] as? [String: Any])
        XCTAssertEqual(cleaned["type"] as? String, "string")

        // system + user; the proper nouns are passed through for verbatim preservation.
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertFalse((messages.first?["content"] as? String ?? "").isEmpty)
        let userContent = try XCTUnwrap(messages.last?["content"] as? String)
        XCTAssertTrue(userContent.contains("hello world"))
        XCTAssertTrue(userContent.contains("Offtype"))
        XCTAssertTrue(userContent.contains("Kuba"))
    }

    func testMakeChatRequestOmitsPreserveLineWhenNoContext() throws {
        let request = OllamaCleaner.makeChatRequest(
            text: "just text", context: [], model: "gemma3:4b", think: true)
        let userContent = try XCTUnwrap(request.messages.last?.content)
        XCTAssertEqual(userContent, "just text")
    }

    // MARK: - Graceful failure (never crash, return input unchanged)

    func testCleanReturnsInputUnchangedWhenOllamaUnreachable() async throws {
        // Port 59999 on loopback is (almost certainly) closed → connection refused, fast.
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:59999/api/chat"))
        let cleaner = OllamaCleaner(endpoint: endpoint, requestTimeout: 3)

        let output = try await cleaner.clean("keep me exactly", context: [])
        XCTAssertEqual(output.text, "keep me exactly")
        XCTAssertEqual(output.tokensUsed, 0)
    }

    func testCleanShortCircuitsOnEmptyText() async throws {
        let cleaner = OllamaCleaner(endpoint: OllamaCleaner.defaultEndpoint)
        let output = try await cleaner.clean("   ", context: [])
        XCTAssertEqual(output.text, "   ")
        XCTAssertEqual(output.tokensUsed, 0)
        XCTAssertEqual(output.latencyMS, 0)
    }
}
