import Foundation
import OfftypeCore

// AGENT(LearningEngine): this is the demo-critical, PURE-LOGIC brain. Implement
// every body below and unit-test exhaustively (LearningEngineTests). No I/O, no
// OS calls — deterministic and fast. The public signatures here are the contract
// the app + Eval depend on; keep them stable.

/// Phonetic key for fuzzy alias matching (e.g. "cuba" ~ "Kuba").
public enum Phonetics {
    /// AGENT: implement Double Metaphone. Stub returns a lowercased, vowel-trimmed key.
    public static func key(_ s: String) -> String {
        s.lowercased().filter { !"aeiou".contains($0) && $0.isLetter }
    }
}

public struct LearnOutcome: Sendable, Equatable {
    public var rules: [Rule]
    public var terms: [DictionaryEntry]
    public init(rules: [Rule] = [], terms: [DictionaryEntry] = []) {
        self.rules = rules
        self.terms = terms
    }
}

/// Distills a (raw → corrected) pair into alias→canonical rules + dictionary terms
/// via token-level edit-distance alignment.
public struct DiffEngine: Sendable {
    public init() {}
    /// AGENT: implement token alignment + substitution extraction (capture
    /// alias→canonical for replaced spans; harvest novel canonical tokens as terms;
    /// attach a small context window + phonetic key; set confidence).
    public func learn(from correction: Correction) -> LearnOutcome { LearnOutcome() }
}

/// Applies learned rules to text: longest-match, word-boundary-aware, context-gated,
/// highest-confidence-wins, idempotent.
public struct RuleApplier: Sendable {
    public init() {}
    /// AGENT: implement. Returns rewritten text + per-span decisions (source=.rule
    /// for replaced spans, .unchanged otherwise) for the HUD badge + Local-Only %.
    public func apply(_ rules: [Rule], to text: String) -> (text: String, decisions: [SpanDecision]) {
        (text, [SpanDecision(original: text, output: text, source: .unchanged)])
    }
}

/// Decides whether a span still needs the cloud after local rules/dictionary.
public struct ConfidenceGate: Sendable {
    public var threshold: Double
    public init(threshold: Double = 0.6) { self.threshold = threshold }
    public func needsCloud(spanCovered: Bool, confidence: Double?) -> Bool {
        if spanCovered { return false }
        return (confidence ?? 1.0) < threshold
    }
}

/// Orchestrates the per-span routing: local rules/dictionary first; only
/// uncovered + low-confidence spans reach the cloud cleaner (when allowed).
public struct Router: Sendable {
    public var applier = RuleApplier()
    public var gate = ConfidenceGate()
    public init() {}

    /// AGENT: implement. Must produce decisions that make Local-Only % truthful
    /// and never call the cleaner when `allowCloud` is false or rules already cover
    /// the text.
    public func rewrite(
        _ transcript: Transcript,
        rules: [Rule],
        dictionary: [DictionaryEntry],
        cleaner: Cleaner?,
        allowCloud: Bool
    ) async -> RewriteResult {
        let (text, decisions) = applier.apply(rules, to: transcript.rawText)
        return RewriteResult(finalText: text, decisions: decisions)
    }
}
