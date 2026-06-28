import Foundation
import OfftypeCore

/// Decides whether a span still needs the cloud after local rules/dictionary.
public struct ConfidenceGate: Sendable {
    /// Spans below this recognizer confidence are eligible for cloud cleanup.
    public var threshold: Double
    public init(threshold: Double = 0.6) { self.threshold = threshold }

    /// A span needs the cloud only when it is *not* covered locally *and* the
    /// recognizer was unsure about it. Missing confidence is treated as confident
    /// (1.0), so nothing silently leaves the machine.
    public func needsCloud(spanCovered: Bool, confidence: Double?) -> Bool {
        if spanCovered { return false }
        return (confidence ?? 1.0) < threshold
    }
}

/// Orchestrates per-span routing: local rules/dictionary first; only uncovered +
/// low-confidence spans reach the cloud cleaner, and only when `allowCloud` is true
/// and a cleaner is supplied. The emitted decisions make `RewriteResult`'s
/// `localOnlyFraction` and token totals truthful.
public struct Router: Sendable {
    public var applier = RuleApplier()
    public var gate = ConfidenceGate()
    public init() {}

    public func rewrite(
        _ transcript: Transcript,
        rules: [Rule],
        dictionary: [DictionaryEntry],
        cleaner: Cleaner?,
        allowCloud: Bool
    ) async -> RewriteResult {
        let (words, gaps) = TextKit.tokenize(transcript.rawText)
        guard !words.isEmpty else {
            let raw = transcript.rawText
            let decisions = raw.isEmpty ? [] : [SpanDecision(original: raw, output: raw, source: .unchanged)]
            return RewriteResult(finalText: raw, decisions: decisions)
        }

        let confidences = Self.confidences(for: transcript, wordCount: words.count)
        var units = rewriteUnits(rules: rules, dictionary: dictionary, words: words, gaps: gaps)

        // Locally-resolved text first; this is the final answer unless the cloud runs.
        var finalText = rebuild(units: units, gaps: gaps)

        // Cloud candidates: still-unchanged spans the recognizer was unsure about.
        let cloudIndices = units.indices.filter { idx in
            guard units[idx].source == .unchanged else { return false }
            let confidence = units[idx].range.compactMap { confidences[$0] }.min()
            return gate.needsCloud(spanCovered: false, confidence: confidence)
        }

        if allowCloud, let cleaner, !cloudIndices.isEmpty {
            let context = words.map { $0.lowercased() }
            if let output = try? await cleaner.clean(finalText, context: context) {
                finalText = output.text
                // Attribute the single cleanup call's cost to the spans that caused
                // it (all tokens/latency on the first, so totals stay exact).
                for (offset, idx) in cloudIndices.enumerated() {
                    units[idx].source = .cloudLLM
                    units[idx].tokensUsed = offset == 0 ? output.tokensUsed : 0
                    units[idx].latencyMS = offset == 0 ? output.latencyMS : 0
                }
            }
            // On cleaner failure we keep the local result — nothing leaves the machine.
        }

        return RewriteResult(finalText: finalText, decisions: units.map(SpanDecision.init(unit:)))
    }

    /// Aligns recognizer confidences to word tokens. Uses per-span confidences when
    /// the span count matches (directly, or after tokenizing each span's text);
    /// otherwise returns all-`nil` (treated as confident → fully local).
    static func confidences(for transcript: Transcript, wordCount: Int) -> [Double?] {
        let spans = transcript.spans
        if spans.count == wordCount {
            return spans.map { $0.confidence }
        }
        if !spans.isEmpty {
            var expanded: [Double?] = []
            for span in spans {
                let tokens = TextKit.words(span.text)
                if tokens.isEmpty {
                    expanded.append(span.confidence)
                } else {
                    expanded.append(contentsOf: tokens.map { _ in span.confidence })
                }
            }
            if expanded.count == wordCount { return expanded }
        }
        return Array(repeating: nil, count: wordCount)
    }
}
