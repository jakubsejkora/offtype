import Foundation

// MARK: - Cross-boundary protocols
//
// These are the seams that let modules (and parallel build agents) develop and
// test against stable interfaces, and let the app inject mocks.

/// On-device speech-to-text. Default impl: `ParakeetTranscriber` (FluidAudio).
public protocol Transcriber: Sendable {
    /// Transcribe a finished utterance into raw, uncorrected text + spans.
    func transcribe(_ audio: AudioSamples) async throws -> Transcript
}

/// Output of an optional cloud/LLM cleanup pass, with real cost accounting.
public struct CleanupOutput: Sendable, Equatable {
    public var text: String
    public var tokensUsed: Int
    public var latencyMS: Double

    public init(text: String, tokensUsed: Int, latencyMS: Double) {
        self.text = text
        self.tokensUsed = tokensUsed
        self.latencyMS = latencyMS
    }
}

/// Optional text-cleanup pass (punctuation/casing/disfluencies). Kept OFF the
/// critical demo path: invoked only when deterministic rules don't cover a span.
/// Default impl: `NoopCleaner`; enhancement: `OllamaCleaner` (local Gemma).
public protocol Cleaner: Sendable {
    func clean(_ text: String, context: [String]) async throws -> CleanupOutput
}

/// Inserts final text into whatever app has focus. Default impl: pasteboard+⌘V
/// with save/restore; must refuse when secure input is active.
public protocol TextInjecting: Sendable {
    /// Returns false (without throwing) when injection is blocked, e.g. a secure
    /// input field is focused, so the caller can fall back to in-app rendering.
    @discardableResult
    func inject(_ text: String) throws -> Bool
}

/// A no-op cleaner: the rules-first pipeline is fully functional without any LLM.
public struct NoopCleaner: Cleaner {
    public init() {}
    public func clean(_ text: String, context: [String]) async throws -> CleanupOutput {
        CleanupOutput(text: text, tokensUsed: 0, latencyMS: 0)
    }
}
