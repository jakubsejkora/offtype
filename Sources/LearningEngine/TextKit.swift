import Foundation

// Internal, pure text utilities shared across the learning engine. No I/O, no OS
// calls — everything here is deterministic and side-effect free so the engine
// stays fully unit-testable.
enum TextKit {

    // MARK: - Tokenization

    /// Splits a string into word tokens and the gaps (separators) around them, so
    /// the original can be rebuilt exactly:
    /// `gaps[0] + words[0] + gaps[1] + words[1] + ... + words[n-1] + gaps[n]`.
    ///
    /// A *word* is a maximal run of letters/digits, allowing an apostrophe *inside*
    /// the run (so `don't` stays one token). Everything else (spaces, punctuation,
    /// dashes) becomes gap text. `gaps.count == words.count + 1` always holds.
    static func tokenize(_ s: String) -> (words: [String], gaps: [String]) {
        var words: [String] = []
        var gaps: [String] = []
        var currentGap = ""
        var currentWord = ""
        var inWord = false

        func isWordScalar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        for c in s {
            if isWordScalar(c) || (inWord && c == "'") {
                if !inWord {
                    gaps.append(currentGap)
                    currentGap = ""
                    inWord = true
                }
                currentWord.append(c)
            } else {
                if inWord {
                    words.append(currentWord)
                    currentWord = ""
                    inWord = false
                }
                currentGap.append(c)
            }
        }
        if inWord { words.append(currentWord) }
        gaps.append(currentGap)
        return (words, gaps)
    }

    /// Convenience: just the word tokens.
    static func words(_ s: String) -> [String] { tokenize(s).words }

    // MARK: - Edit distance / similarity

    /// Levenshtein distance over any `Equatable` sequence (chars or word tokens).
    static func levenshtein<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    static func charEditDistance(_ a: String, _ b: String) -> Int {
        levenshtein(Array(a), Array(b))
    }

    /// Normalized character dissimilarity in `[0, 1]` (0 == identical).
    static func charDissimilarity(_ a: String, _ b: String) -> Double {
        let m = Swift.max(a.count, b.count)
        if m == 0 { return 0 }
        return Double(charEditDistance(a, b)) / Double(m)
    }

    /// Length of the longest common subsequence of two token arrays. Used for the
    /// token-recall basis of Local-Only %.
    static func lcsLength<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            for j in 1...b.count {
                if a[i - 1] == b[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else {
                    curr[j] = Swift.max(prev[j], curr[j - 1])
                }
            }
            swap(&prev, &curr)
            for k in curr.indices { curr[k] = 0 }
        }
        return prev[b.count]
    }

    /// True if `needle` appears as a contiguous, case-sensitive run inside `hay`.
    static func containsContiguous(_ hay: [String], _ needle: [String]) -> Bool {
        if needle.isEmpty { return true }
        if needle.count > hay.count { return false }
        for start in 0...(hay.count - needle.count) where Array(hay[start..<(start + needle.count)]) == needle {
            return true
        }
        return false
    }

    // MARK: - Casing

    enum CasePattern { case lower, capitalized, upper, mixed }

    static func casePattern(of s: String) -> CasePattern {
        let chars = Array(s)
        let letters = chars.filter { $0.isLetter }
        if letters.isEmpty { return .lower }
        if letters.count > 1, letters.allSatisfy({ $0.isUppercase }) { return .upper }
        if letters.allSatisfy({ $0.isLowercase }) { return .lower }
        if let firstLetterIdx = chars.firstIndex(where: { $0.isLetter }) {
            let rest = chars[(firstLetterIdx + 1)...].filter { $0.isLetter }
            if chars[firstLetterIdx].isUppercase, rest.allSatisfy({ $0.isLowercase }) {
                return .capitalized
            }
        }
        return .mixed
    }

    static func applyCase(_ pattern: CasePattern, to s: String) -> String {
        switch pattern {
        case .lower: return s.lowercased()
        case .upper: return s.uppercased()
        case .capitalized: return s.prefix(1).uppercased() + s.dropFirst()
        case .mixed: return s
        }
    }

    /// Choose the output casing for a rewrite. If the canonical form carries
    /// intentional casing (any uppercase, e.g. `Offtype`, `GemmaQuant`, `Kuba`) we
    /// keep it verbatim — the user told us how the term is spelled. Otherwise the
    /// canonical is a plain lowercase word (e.g. `eval`) and we mirror the matched
    /// text's case so sentence-initial / shouted forms stay natural.
    static func casedOutput(canonical: String, matched: String) -> String {
        if canonical.contains(where: { $0.isUppercase }) { return canonical }
        return applyCase(casePattern(of: matched), to: canonical)
    }

    // MARK: - Stopwords (for context capture only)

    /// Generic English function words excluded when capturing a rule's context
    /// window — they carry no disambiguating signal. Domain words like `off`,
    /// `type`, `ping`, `ship`, `harness` are intentionally *not* here so they can
    /// gate ambiguous single-word rules.
    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "nor", "to", "of", "in", "on", "for",
        "with", "at", "by", "from", "as", "into", "onto", "over", "under", "again",
        "then", "once", "about", "above", "below", "up", "down", "out", "is", "are",
        "was", "were", "be", "been", "being", "am", "it", "its", "this", "that",
        "these", "those", "i", "me", "my", "we", "us", "our", "you", "your", "he",
        "she", "him", "her", "they", "them", "their", "so", "than", "too", "very",
        "can", "will", "would", "should", "could", "may", "might", "must", "do",
        "does", "did", "done", "has", "have", "had", "not", "no", "yes", "just",
        "also", "there", "here", "use", "used", "using", "get", "got", "let",
    ]
}
