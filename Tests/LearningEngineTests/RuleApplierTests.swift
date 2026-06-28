import XCTest
import OfftypeCore
@testable import LearningEngine

final class RuleApplierTests: XCTestCase {
    private let applier = RuleApplier()

    private func makeRule(
        _ alias: String,
        _ canonical: String,
        context: [String] = [],
        confidence: Double = 1.0,
        enabled: Bool = true,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) -> Rule {
        Rule(alias: alias, canonical: canonical, phoneticKey: Phonetics.key(alias),
             context: context, confidence: confidence, enabled: enabled, createdAt: createdAt)
    }

    // MARK: - Basics

    func testEmptyRulesAreIdentityAndAllLocal() {
        let (text, decisions) = applier.apply([], to: "hello there world")
        XCTAssertEqual(text, "hello there world")
        XCTAssertEqual(decisions.count, 3)
        XCTAssertTrue(decisions.allSatisfy { $0.source == .unchanged })
        let result = RewriteResult(finalText: text, decisions: decisions)
        XCTAssertEqual(result.localOnlyFraction, 1.0, accuracy: 0.0001)
    }

    func testEmptyStringIsSafe() {
        let (text, decisions) = applier.apply([makeRule("cuba", "Kuba")], to: "")
        XCTAssertEqual(text, "")
        XCTAssertTrue(decisions.isEmpty)
    }

    // MARK: - Substitution + casing

    func testCasedCanonicalIsKeptVerbatim() {
        let rules = [makeRule("cuba", "Kuba")]
        XCTAssertEqual(applier.apply(rules, to: "ping Cuba now").text, "ping Kuba now")
        XCTAssertEqual(applier.apply(rules, to: "ping cuba now").text, "ping Kuba now")
        XCTAssertEqual(applier.apply(rules, to: "CUBA").text, "Kuba")
    }

    func testLowercaseCanonicalMirrorsMatchedCase() {
        let rules = [makeRule("evil", "eval")]
        XCTAssertEqual(applier.apply(rules, to: "evil").text, "eval")
        XCTAssertEqual(applier.apply(rules, to: "the evil harness").text, "the eval harness")
    }

    func testLowercaseCanonicalCapitalizationAndUppercase() {
        let rules = [makeRule("evil", "eval")]
        XCTAssertEqual(applier.apply(rules, to: "Evil").text, "Eval")
        XCTAssertEqual(applier.apply(rules, to: "EVIL").text, "EVAL")
    }

    func testMultipleOccurrencesAllReplaced() {
        let rules = [makeRule("cuba", "Kuba")]
        XCTAssertEqual(applier.apply(rules, to: "Cuba and Cuba again").text, "Kuba and Kuba again")
    }

    // MARK: - Word boundaries

    func testRuleRespectsWordBoundaries() {
        let rules = [makeRule("cat", "dog")]
        XCTAssertEqual(applier.apply(rules, to: "the category cat sat").text, "the category dog sat")
    }

    func testPunctuationIsPreserved() {
        let rules = [makeRule("cuba", "Kuba")]
        XCTAssertEqual(applier.apply(rules, to: "Cuba, really? Cuba!").text, "Kuba, really? Kuba!")
    }

    // MARK: - Longest-match / conflict resolution

    func testLongestMatchWinsOverHigherConfidenceShorterRule() {
        let rules = [
            makeRule("new york", "NYC", confidence: 0.9),
            makeRule("york", "Y", confidence: 0.99),
        ]
        XCTAssertEqual(applier.apply(rules, to: "visit new york city").text, "visit NYC city")
    }

    func testHighestConfidenceWinsForSameLength() {
        let rules = [
            makeRule("color", "colour", confidence: 0.7, createdAt: Date(timeIntervalSinceReferenceDate: 0)),
            makeRule("color", "COLOR", confidence: 0.95, createdAt: Date(timeIntervalSinceReferenceDate: 10)),
        ]
        XCTAssertEqual(applier.apply(rules, to: "the color").text, "the COLOR")
    }

    func testConflictTieBreaksDeterministicallyByAge() {
        let older = makeRule("foo", "AAA", confidence: 0.8, createdAt: Date(timeIntervalSinceReferenceDate: 0))
        let newer = makeRule("foo", "BBB", confidence: 0.8, createdAt: Date(timeIntervalSinceReferenceDate: 100))
        // Same confidence → older rule wins, regardless of array order.
        XCTAssertEqual(applier.apply([newer, older], to: "foo").text, "AAA")
        XCTAssertEqual(applier.apply([older, newer], to: "foo").text, "AAA")
    }

    // MARK: - Context gating

    func testContextGatedRuleFiresOnlyWithContextWord() {
        let rules = [makeRule("evil", "eval", context: ["harness", "run"])]
        XCTAssertEqual(applier.apply(rules, to: "an evil plan").text, "an evil plan")
        XCTAssertEqual(applier.apply(rules, to: "run the evil harness").text, "run the eval harness")
        XCTAssertEqual(applier.apply(rules, to: "evil empire and a harness").text, "eval empire and a harness")
    }

    // MARK: - Merges

    func testMergeAcrossWhitespaceOnly() {
        let rules = [makeRule("off type", "Offtype")]
        XCTAssertEqual(applier.apply(rules, to: "the off type tool").text, "the Offtype tool")
        XCTAssertEqual(applier.apply(rules, to: "off   type").text, "Offtype") // collapses internal spaces
    }

    func testMergeDoesNotCrossPunctuation() {
        let rules = [makeRule("off type", "Offtype")]
        XCTAssertEqual(applier.apply(rules, to: "turn it off, type now").text, "turn it off, type now")
        XCTAssertEqual(applier.apply(rules, to: "switch it off. Type it").text, "switch it off. Type it")
    }

    // MARK: - Idempotency

    func testApplicationIsIdempotent() {
        let rules = [
            makeRule("off type", "Offtype"),
            makeRule("cuba", "Kuba"),
            makeRule("gemma quant", "GemmaQuant"),
        ]
        let input = "ship off type to Cuba with gemma quant"
        let once = applier.apply(rules, to: input).text
        let twice = applier.apply(rules, to: once).text
        XCTAssertEqual(once, "ship Offtype to Kuba with GemmaQuant")
        XCTAssertEqual(once, twice)
    }

    // MARK: - Decisions

    func testDecisionsCarrySourcesAndRuleID() {
        let rule = makeRule("cuba", "Kuba")
        let (_, decisions) = applier.apply([rule], to: "ping Cuba now")
        XCTAssertEqual(decisions.map(\.source), [.unchanged, .rule, .unchanged])
        XCTAssertEqual(decisions[1].ruleID, rule.id)
        XCTAssertEqual(decisions[1].original, "Cuba")
        XCTAssertEqual(decisions[1].output, "Kuba")
        XCTAssertEqual(decisions[1].tokensUsed, 0)
    }

    func testDisabledRuleIsIgnored() {
        let rules = [makeRule("cuba", "Kuba", enabled: false)]
        XCTAssertEqual(applier.apply(rules, to: "ping Cuba").text, "ping Cuba")
    }

    // MARK: - Dictionary recasing

    func testDictionaryRecasesKnownTerm() {
        let dictionary = [DictionaryEntry(term: "Hetzner", source: .correction)]
        let (text, decisions) = applier.apply([], dictionary: dictionary, to: "deploy to hetzner now")
        XCTAssertEqual(text, "deploy to Hetzner now")
        XCTAssertEqual(decisions.first { $0.original == "hetzner" }?.source, .dictionary)
    }

    func testDictionaryNeverSubstitutesADifferentWord() {
        // "cuba" must not be turned into the term "Kuba" by the dictionary — that is
        // the (context-gated) job of a rule, not casing-only recasing.
        let dictionary = [DictionaryEntry(term: "Kuba", source: .correction)]
        XCTAssertEqual(applier.apply([], dictionary: dictionary, to: "visit cuba").text, "visit cuba")
    }

    // MARK: - Phonetic fallback

    func testPhoneticFallbackCatchesCloseVariant() {
        // A learned alias "kuba"→"Kuba" should still fix a near-identical mis-spelling
        // "kuuba" via the Metaphone fallback when its context is present.
        let rules = [makeRule("kuba", "Kuba", context: ["harness"])]
        XCTAssertEqual(Phonetics.key("kuuba"), Phonetics.key("kuba"))
        XCTAssertEqual(applier.apply(rules, to: "ping kuuba near harness").text, "ping Kuba near harness")
        // …but not when context is absent.
        XCTAssertEqual(applier.apply(rules, to: "ping kuuba now").text, "ping kuuba now")
    }
}
