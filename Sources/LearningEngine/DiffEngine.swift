import Foundation
import OfftypeCore

/// Distills a `(raw → corrected)` pair into alias→canonical `Rule`s plus harvested
/// `DictionaryEntry` terms, via a similarity-aware token alignment that recognizes
/// 1→1 substitutions, n→1 merges ("off type" → "Offtype") and 1→n splits.
///
/// Pure and deterministic: the same correction always yields the same rules.
public struct DiffEngine: Sendable {
    /// Largest number of tokens a single merge/split may span.
    public var maxSpan: Int
    /// Single-word substitutions more dissimilar than this (and not phonetically
    /// equal) are treated as genuine content edits — not mis-hearings — and do not
    /// become rules.
    public var maxRuleDissimilarity: Double
    /// A merge/split move is only considered when the joined forms are at least this
    /// similar; otherwise it is really an insertion/deletion and is modeled as such.
    public var maxMergeDissimilarity: Double

    public init(maxSpan: Int = 4, maxRuleDissimilarity: Double = 0.6, maxMergeDissimilarity: Double = 0.34) {
        self.maxSpan = Swift.max(2, maxSpan)
        self.maxRuleDissimilarity = maxRuleDissimilarity
        self.maxMergeDissimilarity = maxMergeDissimilarity
    }

    public func learn(from correction: Correction) -> LearnOutcome {
        let raw = TextKit.words(correction.rawText)
        let corrected = TextKit.words(correction.correctedText)
        let ops = align(raw, corrected)
        let rawLowerSet = Set(raw.map { $0.lowercased() })

        var ruleByKey: [String: Rule] = [:]
        var ruleOrder: [String] = []
        var terms: [DictionaryEntry] = []
        var seenTerms = Set<String>()

        for op in ops where op.kind == .change {
            // Harvest any novel proper nouns regardless of whether a rule is emitted
            // (covers pure insertions too).
            harvest(op.corWords, rawLowerSet: rawLowerSet, into: &terms, seen: &seenTerms, createdAt: correction.createdAt)

            guard !op.rawWords.isEmpty, !op.corWords.isEmpty else { continue } // pure ins/del → no rewrite rule

            let alias = op.rawWords.map { $0.lowercased() }.joined(separator: " ")
            let canonical = op.corWords.joined(separator: " ")
            if alias == canonical.lowercased(), op.rawWords == op.corWords { continue }

            let dissimilarity = TextKit.charDissimilarity(alias.replacingOccurrences(of: " ", with: ""),
                                                          canonical.lowercased().replacingOccurrences(of: " ", with: ""))
            // Multi-word merges are distinctive and safe to apply globally; single
            // dissimilar substitutions are likely real edits, not mis-hearings —
            // unless they are phonetically equal (a classic homophone mis-hearing).
            if op.rawWords.count == 1,
               dissimilarity > maxRuleDissimilarity,
               Phonetics.key(alias) != Phonetics.key(canonical) {
                continue
            }

            let singleWordAlias = op.rawWords.count == 1
            // Context-gate only ambiguous single-word rewrites (e.g. "cuba"→"Kuba",
            // "evil"→"eval"); multi-word merges apply globally so they generalize.
            let context = singleWordAlias ? captureContext(raw: raw, range: op.rawRange) : []
            let confidence = Swift.min(0.99, Swift.max(0.6, 1.0 - 0.5 * dissimilarity))
            let phoneticKey = Phonetics.key(alias)

            let key = alias + "→" + canonical
            if var existing = ruleByKey[key] {
                existing.hitCount += 1
                existing.confidence = Swift.min(0.99, existing.confidence + 0.02)
                existing.context = Array(Set(existing.context).union(context)).sorted()
                ruleByKey[key] = existing
            } else {
                ruleByKey[key] = Rule(
                    alias: alias,
                    canonical: canonical,
                    phoneticKey: phoneticKey,
                    context: context.sorted(),
                    confidence: confidence,
                    hitCount: 1,
                    createdAt: correction.createdAt
                )
                ruleOrder.append(key)
            }
        }

        let rules = ruleOrder.compactMap { ruleByKey[$0] }
        return LearnOutcome(rules: rules, terms: terms)
    }

    // MARK: - Term harvesting

    private func harvest(
        _ canonWords: [String],
        rawLowerSet: Set<String>,
        into terms: inout [DictionaryEntry],
        seen: inout Set<String>,
        createdAt: Date
    ) {
        for word in canonWords {
            let lower = word.lowercased()
            guard looksLikeProperNoun(word) else { continue }
            guard !rawLowerSet.contains(lower) else { continue } // not novel — already in raw
            guard !seen.contains(lower) else { continue }
            seen.insert(lower)
            terms.append(DictionaryEntry(term: word, weight: 1.0, source: .correction, createdAt: createdAt))
        }
    }

    private func looksLikeProperNoun(_ word: String) -> Bool {
        guard word.count >= 2 else { return false }
        guard word.contains(where: { $0.isUppercase }) else { return false }
        return !TextKit.stopwords.contains(word.lowercased())
    }

    // MARK: - Context capture

    private func captureContext(raw: [String], range: Range<Int>) -> [String] {
        let window = 2
        let lo = Swift.max(0, range.lowerBound - window)
        let hi = Swift.min(raw.count, range.upperBound + window)
        var context: [String] = []
        for idx in lo..<hi where !range.contains(idx) {
            let token = raw[idx].lowercased()
            if token.count < 2 { continue }
            if TextKit.stopwords.contains(token) { continue }
            if !context.contains(token) { context.append(token) }
        }
        return Array(context.prefix(4))
    }

    // MARK: - Alignment

    private enum OpKind { case equal, change }
    private struct AlignOp {
        var kind: OpKind
        var rawRange: Range<Int>
        var rawWords: [String]
        var corWords: [String]
    }

    /// Token-level edit-distance alignment with merge/split moves. Cost prefers
    /// exact matches (0), then recasing (~0.05), then similar substitutions/merges,
    /// over plain insert/delete — so adjacent independent changes stay separate ops.
    private func align(_ raw: [String], _ corrected: [String]) -> [AlignOp] {
        let m = raw.count
        let n = corrected.count
        if m == 0, n == 0 { return [] }

        let infinity = Double.greatestFiniteMagnitude
        let insCost = 0.9
        let delCost = 0.9

        var dp = Array(repeating: Array(repeating: infinity, count: n + 1), count: m + 1)
        var back = Array(repeating: Array(repeating: (0, 0), count: n + 1), count: m + 1)
        dp[0][0] = 0

        for i in 0...m {
            for j in 0...n {
                if i == 0, j == 0 { continue }
                var best = infinity
                var move = (0, 0)

                if i >= 1, j >= 1 {
                    let c = dp[i - 1][j - 1] + substitutionCost(raw[i - 1], corrected[j - 1])
                    if c < best { best = c; move = (1, 1) }
                }
                if i >= 1 {
                    let c = dp[i - 1][j] + delCost
                    if c < best { best = c; move = (1, 0) }
                }
                if j >= 1 {
                    let c = dp[i][j - 1] + insCost
                    if c < best { best = c; move = (0, 1) }
                }
                if j >= 1, i >= 2 { // merge k raw → 1 corrected
                    var k = 2
                    while k <= maxSpan, k <= i {
                        let merged = raw[(i - k)..<i].joined()
                        let dissim = TextKit.charDissimilarity(merged.lowercased(), corrected[j - 1].lowercased())
                        if dissim <= maxMergeDissimilarity {
                            let c = dp[i - k][j - 1] + dissim
                            if c < best { best = c; move = (k, 1) }
                        }
                        k += 1
                    }
                }
                if i >= 1, j >= 2 { // split 1 raw → k corrected
                    var k = 2
                    while k <= maxSpan, k <= j {
                        let merged = corrected[(j - k)..<j].joined()
                        let dissim = TextKit.charDissimilarity(raw[i - 1].lowercased(), merged.lowercased())
                        if dissim <= maxMergeDissimilarity {
                            let c = dp[i - 1][j - k] + dissim
                            if c < best { best = c; move = (1, k) }
                        }
                        k += 1
                    }
                }

                dp[i][j] = best
                back[i][j] = move
            }
        }

        var ops: [AlignOp] = []
        var i = m
        var j = n
        while i > 0 || j > 0 {
            let (di, dj) = back[i][j]
            if di == 0, dj == 0 { break } // defensive: should not happen on a valid path
            let rawWords = di > 0 ? Array(raw[(i - di)..<i]) : []
            let corWords = dj > 0 ? Array(corrected[(j - dj)..<j]) : []
            let isEqual = (di == 1 && dj == 1 && raw[i - 1] == corrected[j - 1])
            ops.append(AlignOp(kind: isEqual ? .equal : .change,
                               rawRange: (i - di)..<i,
                               rawWords: rawWords,
                               corWords: corWords))
            i -= di
            j -= dj
        }
        return ops.reversed()
    }

    private func substitutionCost(_ a: String, _ b: String) -> Double {
        if a == b { return 0 }
        if a.lowercased() == b.lowercased() { return 0.05 } // recasing
        return TextKit.charDissimilarity(a.lowercased(), b.lowercased())
    }
}
