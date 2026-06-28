import Foundation
import OfftypeCore

// AGENT(Cleanup): implement `OllamaCleaner` calling http://127.0.0.1:11434/api/chat
// with model "gemma3:4b", a tight punctuation/casing/disfluency system prompt, and
// JSON `format` schema (keep `think` ON to avoid the Gemma+format schema-drop bug).
// Decode tokens from the response for real cost accounting. This is an ENHANCEMENT,
// gated behind FeatureFlags.llmCleanupEnabled and the per-span confidence gate —
// never on the critical demo path. Default app cleaner is `NoopCleaner`.

/// Placeholder so the package compiles; passes text through with zero cost.
public struct OllamaCleaner: Cleaner {
    public var model: String
    public var endpoint: URL
    public init(model: String = "gemma3:4b",
                endpoint: URL = URL(string: "http://127.0.0.1:11434/api/chat")!) {
        self.model = model
        self.endpoint = endpoint
    }
    public func clean(_ text: String, context: [String]) async throws -> CleanupOutput {
        CleanupOutput(text: text, tokensUsed: 0, latencyMS: 0)
    }
}
