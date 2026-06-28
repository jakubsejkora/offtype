import Foundation
import OfftypeCore

// The deterministic heart of rule application, shared by `RuleApplier` (rules →
// text, used by Eval) and `Router` (adds the per-span cloud decision). Kept as
// internal free functions so both reuse the exact same matching/rebuilding logic.

/// One contiguous decision over a run of word tokens `[range]`.
struct RewriteUnit {
    var range: Range<Int>      // word indices consumed, half-open [lower, upper)
    var original: String       // the exact original substring for this run
    var output: String         // the rewritten text (== original when unchanged)
    var source: RewriteSource
    var ruleID: UUID?
    var tokensUsed: Int = 0
    var latencyMS: Double = 0
}

/// Phonetic fallback fires only on very close spellings, so a learned alias still
/// catches near-identical mis-hearings without clobbering unrelated words.
private let phoneticMaxDissimilarity = 0.34

/// A candidate rule match at a given start index.
private struct RuleMatch {
    var rule: Rule
    var length: Int  // number of word tokens consumed
}

/// Walks `words`, replacing the longest, highest-confidence, context-satisfied
/// rule match at each position; otherwise tries safe dictionary recasing; else
/// leaves the token unchanged. Idempotent: a replaced span is never re-scanned.
func rewriteUnits(
    rules: [Rule],
    dictionary: [DictionaryEntry],
    words: [String],
    gaps: [String]
) -> [RewriteUnit] {
    let active = rules.filter { $0.enabled }
    let maxAlias = active.reduce(1) { Swift.max($0, aliasWordCount($1)) }
    let sentenceWords = Set(words.map { $0.lowercased() })

    var units: [RewriteUnit] = []
    var i = 0
    while i < words.count {
        if let match = bestRuleMatch(
            at: i,
            words: words,
            gaps: gaps,
            rules: active,
            maxAlias: maxAlias,
            sentenceWords: sentenceWords
        ) {
            let lo = i
            let hi = i + match.length
            let original = rebuildOriginal(words: words, gaps: gaps, lo: lo, hi: hi)
            let output = TextKit.casedOutput(canonical: match.rule.canonical, matched: words[lo])
            if output == original {
                // No-op rewrite (already canonical): keep it local + unchanged so
                // application stays idempotent and Local-Only % stays truthful.
                units.append(RewriteUnit(range: lo..<hi, original: original, output: original, source: .unchanged))
            } else {
                units.append(RewriteUnit(range: lo..<hi, original: original, output: output, source: .rule, ruleID: match.rule.id))
            }
            i = hi
        } else {
            let word = words[i]
            if let term = dictionaryRecase(word, dictionary: dictionary) {
                units.append(RewriteUnit(range: i..<(i + 1), original: word, output: term, source: .dictionary))
            } else {
                units.append(RewriteUnit(range: i..<(i + 1), original: word, output: word, source: .unchanged))
            }
            i += 1
        }
    }
    return units
}

/// Reassembles final text from units, preserving the gaps that bound each unit and
/// dropping the internal gaps of any merged (multi-word → one) replacement.
func rebuild(units: [RewriteUnit], gaps: [String]) -> String {
    guard let leading = gaps.first else { return "" }
    var out = leading
    for u in units {
        out += u.output
        out += gaps[u.range.upperBound] // the gap immediately after this unit's last word
    }
    return out
}

// MARK: - Internals

private func aliasWordCount(_ rule: Rule) -> Int {
    rule.alias.split(separator: " ", omittingEmptySubsequences: true).count
}

private func contextSatisfied(_ rule: Rule, sentenceWords: Set<String>) -> Bool {
    if rule.context.isEmpty { return true }
    return rule.context.contains { sentenceWords.contains($0) }
}

/// Longest-match-wins, then highest confidence, then oldest rule, then UUID — a
/// fully deterministic ordering. Exact alias match is tried at every length before
/// falling back to a tight phonetic match on single tokens.
private func bestRuleMatch(
    at i: Int,
    words: [String],
    gaps: [String],
    rules: [Rule],
    maxAlias: Int,
    sentenceWords: Set<String>
) -> RuleMatch? {
    let remaining = words.count - i
    var length = Swift.min(maxAlias, remaining)
    while length >= 1 {
        // The candidate span's words must be joined by whitespace-only gaps, so we
        // never merge across punctuation ("off, type" must not become "Offtype").
        if length == 1 || internalGapsAreWhitespace(gaps: gaps, lo: i, length: length) {
            let candidateLower = (0..<length).map { words[i + $0].lowercased() }.joined(separator: " ")
            let matches = rules.filter {
                aliasWordCount($0) == length
                    && $0.alias == candidateLower
                    && contextSatisfied($0, sentenceWords: sentenceWords)
            }
            if let best = pickBest(matches) {
                return RuleMatch(rule: best, length: length)
            }
        }
        length -= 1
    }

    // Phonetic fallback: single token, equal Metaphone key, near-identical spelling.
    let token = words[i]
    let tokenLower = token.lowercased()
    let tokenKey = Phonetics.key(token)
    if !tokenKey.isEmpty {
        let fuzzy = rules.filter { rule in
            aliasWordCount(rule) == 1
                && rule.alias != tokenLower
                && (rule.phoneticKey ?? Phonetics.key(rule.alias)) == tokenKey
                && TextKit.charDissimilarity(rule.alias, tokenLower) <= phoneticMaxDissimilarity
                && contextSatisfied(rule, sentenceWords: sentenceWords)
        }
        if let best = pickBest(fuzzy) {
            return RuleMatch(rule: best, length: 1)
        }
    }
    return nil
}

private func pickBest(_ matches: [Rule]) -> Rule? {
    matches.max { lhs, rhs in
        if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt } // older wins
        return lhs.id.uuidString > rhs.id.uuidString
    }
}

private func internalGapsAreWhitespace(gaps: [String], lo: Int, length: Int) -> Bool {
    guard length > 1 else { return true }
    for k in 1..<length {
        let gap = gaps[lo + k]
        if !gap.allSatisfy(\.isWhitespace) { return false }
    }
    return true
}

private func rebuildOriginal(words: [String], gaps: [String], lo: Int, hi: Int) -> String {
    var s = ""
    for k in lo..<hi {
        if k > lo { s += gaps[k] }
        s += words[k]
    }
    return s
}

/// Safe, casing-only dictionary fix: recase a token to a known term when they
/// differ *only* by case (e.g. `hetzner` → `Hetzner`). It never substitutes one
/// word for a different one — that is the (context-gated) job of rules — so it
/// cannot corrupt a legitimately different word.
private func dictionaryRecase(_ word: String, dictionary: [DictionaryEntry]) -> String? {
    let lower = word.lowercased()
    if TextKit.stopwords.contains(lower) { return nil }
    for entry in dictionary {
        guard entry.term.contains(where: { $0.isUppercase }) else { continue }
        if entry.term != word, entry.term.lowercased() == lower {
            return entry.term
        }
    }
    return nil
}
