import XCTest
import OfftypeCore
@testable import LearningEngine

final class DiffEngineTests: XCTestCase {
    private let engine = DiffEngine()

    private func rule(_ outcome: LearnOutcome, alias: String) -> Rule? {
        outcome.rules.first { $0.alias == alias }
    }

    // MARK: - The hero correction

    func testHeroCorrectionYieldsExpectedRulesAndTerms() {
        let correction = Correction(
            rawText: "Ship the off type evil harness to Cuba — use Parakeet and Gemma Quant, then ping Cuba about Hetzner.",
            correctedText: "Ship the Offtype eval harness to Kuba — use Parakeet and GemmaQuant, then ping Kuba about Hetzner."
        )
        let outcome = engine.learn(from: correction)

        // Exactly the four expected rewrites.
        let pairs = Set(outcome.rules.map { "\($0.alias)=>\($0.canonical)" })
        XCTAssertEqual(pairs, [
            "off type=>Offtype",
            "evil=>eval",
            "cuba=>Kuba",
            "gemma quant=>GemmaQuant",
        ])

        // Novel proper nouns harvested; the lowercase "eval" is NOT a term.
        let terms = Set(outcome.terms.map(\.term))
        XCTAssertEqual(terms, ["Offtype", "Kuba", "GemmaQuant"])
        XCTAssertTrue(outcome.terms.allSatisfy { $0.source == .correction })
    }

    func testMergeRulesApplyGloballyButSingleWordRulesAreContextGated() {
        let outcome = engine.learn(from: Correction(
            rawText: "off type evil harness Cuba gemma quant Hetzner",
            correctedText: "Offtype eval harness Kuba GemmaQuant Hetzner"
        ))
        // Multi-word merges are distinctive → no context gate.
        XCTAssertEqual(rule(outcome, alias: "off type")?.context, [])
        XCTAssertEqual(rule(outcome, alias: "gemma quant")?.context, [])
        // Ambiguous single-word rewrites carry a context window.
        XCTAssertFalse(rule(outcome, alias: "cuba")?.context.isEmpty ?? true)
        XCTAssertFalse(rule(outcome, alias: "evil")?.context.isEmpty ?? true)
        XCTAssertTrue(rule(outcome, alias: "cuba")?.context.contains("harness") ?? false)
    }

    func testRepeatedSubstitutionMergesIntoOneRuleWithUnionedContext() {
        // "Cuba" appears twice with different neighbors → one rule, hitCount 2, union.
        let correction = Correction(
            rawText: "ping Cuba about Hetzner then email Cuba near Parakeet",
            correctedText: "ping Kuba about Hetzner then email Kuba near Parakeet"
        )
        let outcome = engine.learn(from: correction)
        let cuba = rule(outcome, alias: "cuba")
        XCTAssertNotNil(cuba)
        XCTAssertEqual(cuba?.hitCount, 2)
        XCTAssertEqual(outcome.rules.filter { $0.alias == "cuba" }.count, 1)
        XCTAssertTrue(cuba?.context.contains("hetzner") ?? false)
        XCTAssertTrue(cuba?.context.contains("parakeet") ?? false)
    }

    func testConfidenceReflectsSimilarity() {
        let outcome = engine.learn(from: Correction(
            rawText: "the off type evil harness near Cuba",
            correctedText: "the Offtype eval harness near Kuba"
        ))
        // Exact merge → top confidence; a one-char substitution → a little lower.
        let merge = rule(outcome, alias: "off type")
        let sub = rule(outcome, alias: "cuba")
        XCTAssertEqual(merge?.confidence ?? 0, 0.99, accuracy: 0.0001)
        XCTAssertGreaterThan(sub?.confidence ?? 0, 0.6)
        XCTAssertLessThan(sub?.confidence ?? 1, merge?.confidence ?? 0)
    }

    func testPhoneticKeyAttachedToRules() {
        let outcome = engine.learn(from: Correction(
            rawText: "near Cuba harness",
            correctedText: "near Kuba harness"
        ))
        let cuba = rule(outcome, alias: "cuba")
        XCTAssertEqual(cuba?.phoneticKey, Phonetics.key("cuba"))
    }

    // MARK: - Degenerate inputs

    func testIdenticalTextsYieldNothing() {
        let outcome = engine.learn(from: Correction(
            rawText: "nothing changed here at all",
            correctedText: "nothing changed here at all"
        ))
        XCTAssertTrue(outcome.rules.isEmpty)
        XCTAssertTrue(outcome.terms.isEmpty)
    }

    func testPureInsertionHarvestsTermButEmitsNoRule() {
        // A word the user *added* (no raw counterpart) can't become a rewrite rule,
        // but a novel proper noun is still worth remembering.
        let outcome = engine.learn(from: Correction(
            rawText: "deploy to the cluster",
            correctedText: "deploy to the Hetzner cluster"
        ))
        XCTAssertTrue(outcome.rules.isEmpty)
        XCTAssertEqual(outcome.terms.map(\.term), ["Hetzner"])
    }

    func testWildlyDifferentSingleWordIsNotTurnedIntoARule() {
        // A genuine content edit (not a mis-hearing) should not crystallize.
        let outcome = engine.learn(from: Correction(
            rawText: "the cat sat",
            correctedText: "the elephant sat"
        ))
        XCTAssertTrue(outcome.rules.isEmpty)
    }

    func testEmptyCorrectionIsSafe() {
        let outcome = engine.learn(from: Correction(rawText: "", correctedText: ""))
        XCTAssertTrue(outcome.rules.isEmpty)
        XCTAssertTrue(outcome.terms.isEmpty)
    }

    func testLearningIsDeterministic() {
        let correction = Correction(
            rawText: "off type evil harness Cuba",
            correctedText: "Offtype eval harness Kuba"
        )
        let a = engine.learn(from: correction)
        let b = engine.learn(from: correction)
        XCTAssertEqual(a.rules.map { "\($0.alias)=>\($0.canonical)" },
                       b.rules.map { "\($0.alias)=>\($0.canonical)" })
    }
}
