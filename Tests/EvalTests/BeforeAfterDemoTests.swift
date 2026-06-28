import XCTest
import OfftypeCore
import LearningEngine
@testable import Eval

/// The demo's central, un-fakeable claim, scored on the FROZEN held-out manifest:
/// after learning from a single seed correction, proper-noun accuracy and Local-Only
/// % climb and WER drops — WITHOUT corrupting look-alike neighbors. Every number is
/// computed from `demo/`, never hardcoded.
final class BeforeAfterDemoTests: XCTestCase {

    func testSeedYieldsFourRulesAndThreeTerms() throws {
        let learned = try DemoFixtures.learnedFromSeed()
        XCTAssertEqual(learned.rules.count, 4)
        XCTAssertEqual(Set(learned.rules.map { "\($0.alias)=>\($0.canonical)" }), [
            "off type=>Offtype", "evil=>eval", "cuba=>Kuba", "gemma quant=>GemmaQuant",
        ])
        XCTAssertEqual(Set(learned.terms.map(\.term)), ["Offtype", "Kuba", "GemmaQuant"])
    }

    func testHeldOutNumbersClimbAfterOneCorrection() throws {
        let manifest = try DemoFixtures.manifest()
        let learned = try DemoFixtures.learnedFromSeed()
        let evaluator = Evaluator()

        let before = evaluator.run(manifest: manifest, rules: [], dictionary: [])
        let after = evaluator.run(manifest: manifest, rules: learned.rules, dictionary: learned.terms)

        // The three headline numbers must all move the right way, by a real margin.
        XCTAssertGreaterThan(after.properNounAccuracy, before.properNounAccuracy + 0.30)
        XCTAssertLessThan(after.wer, before.wer - 0.10)
        XCTAssertGreaterThan(after.localOnlyPercent, before.localOnlyPercent + 0.10)

        // Sanity bounds (these are generalization to UNSEEN phrases, so < 100%).
        XCTAssertLessThan(before.properNounAccuracy, 0.5)
        XCTAssertGreaterThan(after.properNounAccuracy, 0.75)

        print(String(format: "[demo] BEFORE  PN=%.1f%%  WER=%.1f%%  Local-Only=%.1f%%",
                     before.properNounAccuracy * 100, before.wer * 100, before.localOnlyPercent * 100))
        print(String(format: "[demo] AFTER   PN=%.1f%%  WER=%.1f%%  Local-Only=%.1f%%",
                     after.properNounAccuracy * 100, after.wer * 100, after.localOnlyPercent * 100))
    }

    func testRulesGeneralizeToAnUnseenHeldOutPhrase() throws {
        // h1 is NOT the seed sentence, yet the learned rules must fix it.
        let learned = try DemoFixtures.learnedFromSeed()
        let manifest = try DemoFixtures.manifest()
        let after = Evaluator().run(manifest: manifest, rules: learned.rules, dictionary: learned.terms)
        let h1 = try XCTUnwrap(after.perPhrase.first { $0.id == "h1" })
        XCTAssertEqual(h1.hypothesis, "Push the Offtype eval harness to Kuba before standup.")
        XCTAssertEqual(h1.wer, 0, accuracy: 0.0001)
    }

    func testAntiOverfitChallengePasses() throws {
        let nearMiss = try DemoFixtures.nearMiss()
        let learned = try DemoFixtures.learnedFromSeed()
        let result = Evaluator().runAntiOverfit(nearMiss: nearMiss, rules: learned.rules, dictionary: learned.terms)

        XCTAssertTrue(result.passed, "regressions: \(result.regressions)")
        XCTAssertEqual(result.preserved, result.total)
        XCTAssertEqual(result.preservationRate, 1.0, accuracy: 0.0001)

        // The signature neighbor: the country "Cuba" must stay "Cuba".
        let cuba = try XCTUnwrap(result.perPhrase.first { $0.id == "n1" })
        XCTAssertTrue(cuba.hypothesis.contains("Cuba"))
        XCTAssertFalse(cuba.hypothesis.contains("Kuba"))
    }

    func testDemoEvaluationIsDeterministic() throws {
        let manifest = try DemoFixtures.manifest()
        let learned = try DemoFixtures.learnedFromSeed()
        let a = Evaluator().run(manifest: manifest, rules: learned.rules, dictionary: learned.terms)
        let b = Evaluator().run(manifest: manifest, rules: learned.rules, dictionary: learned.terms)
        XCTAssertEqual(a, b)
    }
}
