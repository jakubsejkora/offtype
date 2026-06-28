import Foundation
import OfftypeCore

/// Applies learned rules (and optional dictionary recasing) to text:
/// longest-match, word-boundary-aware, context-gated, highest-confidence-wins,
/// case-preserving, and idempotent. Returns the rewritten text plus one
/// `SpanDecision` per word span so the HUD badge and Local-Only % are truthful.
public struct RuleApplier: Sendable {
    public init() {}

    /// Rules-only application (the path Eval uses).
    public func apply(_ rules: [Rule], to text: String) -> (text: String, decisions: [SpanDecision]) {
        apply(rules, dictionary: [], to: text)
    }

    /// Rules + dictionary recasing.
    public func apply(_ rules: [Rule], dictionary: [DictionaryEntry], to text: String) -> (text: String, decisions: [SpanDecision]) {
        let (words, gaps) = TextKit.tokenize(text)
        guard !words.isEmpty else {
            let decisions = text.isEmpty ? [] : [SpanDecision(original: text, output: text, source: .unchanged)]
            return (text, decisions)
        }
        let units = rewriteUnits(rules: rules, dictionary: dictionary, words: words, gaps: gaps)
        let finalText = rebuild(units: units, gaps: gaps)
        return (finalText, units.map(SpanDecision.init(unit:)))
    }
}

extension SpanDecision {
    init(unit: RewriteUnit) {
        self.init(
            original: unit.original,
            output: unit.output,
            source: unit.source,
            ruleID: unit.ruleID,
            tokensUsed: unit.tokensUsed,
            latencyMS: unit.latencyMS
        )
    }
}
