import Foundation

/// A small, public facade over the engine's internal tokenizer and distance
/// helpers, so other pure-logic modules (notably `Eval`) score text with the *same*
/// tokenization the `RuleApplier` uses — keeping metrics consistent with rewriting.
public enum OfftypeText {
    /// Word tokens (letters/digits, apostrophes kept inside a word), punctuation and
    /// whitespace dropped — the unit of all word-level metrics.
    public static func words(_ s: String) -> [String] { TextKit.words(s) }

    /// Token-level Levenshtein edit distance (the numerator of WER).
    public static func tokenEditDistance(_ a: [String], _ b: [String]) -> Int {
        TextKit.levenshtein(a, b)
    }

    /// Length of the longest common subsequence of two token arrays.
    public static func lcsLength(_ a: [String], _ b: [String]) -> Int {
        TextKit.lcsLength(a, b)
    }

    /// True if `needle` appears as a contiguous, case-sensitive run inside `hay`.
    public static func containsContiguous(_ hay: [String], _ needle: [String]) -> Bool {
        TextKit.containsContiguous(hay, needle)
    }
}
