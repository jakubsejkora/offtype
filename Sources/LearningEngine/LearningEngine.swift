import Foundation
import OfftypeCore

// The demo-critical, PURE-LOGIC brain of Offtype — "every correction becomes a
// rule." No I/O, no OS calls; deterministic and fast, so it can be exhaustively
// unit-tested without launching the app. The pieces:
//
//   • Phonetics   — Metaphone keys for fuzzy alias matching          (Phonetics.swift)
//   • DiffEngine  — (raw → corrected) ⇒ alias→canonical rules + terms (DiffEngine.swift)
//   • RuleApplier — longest-match, context-gated, idempotent rewrite  (RuleApplier.swift)
//   • ConfidenceGate / Router — per-span local-vs-cloud routing       (Router.swift)
//
// The public signatures in those files are the contract the app + Eval depend on.

/// The product of distilling one correction: the rules to apply next time, plus any
/// novel proper-noun/jargon terms to remember in the personal dictionary.
public struct LearnOutcome: Sendable, Equatable {
    public var rules: [Rule]
    public var terms: [DictionaryEntry]

    public init(rules: [Rule] = [], terms: [DictionaryEntry] = []) {
        self.rules = rules
        self.terms = terms
    }
}
