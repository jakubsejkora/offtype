import XCTest

import OfftypeCore
@testable import LearningEngine

// AGENT(LearningEngine): replace with exhaustive tests — DiffEngine rule
// extraction, RuleApplier ordering/idempotency/word-boundary/context-gating,
// ConfidenceGate boundaries, Phonetics. This placeholder keeps the target compiling.
final class LearningEnginePlaceholderTests: XCTestCase {
    func testRuleApplierIsIdempotentOnEmptyRules() {
        let (text, _) = RuleApplier().apply([], to: "hello world")
        XCTAssertEqual(text, "hello world")
    }
}
