import XCTest
import OfftypeCore
import LearningEngine
@testable import Eval

final class EvaluatorTests: XCTestCase {
    private let evaluator = Evaluator()

    // MARK: - WER

    func testWERIsZeroWhenRulesFixEverything() {
        let manifest = [ManifestEntry(id: "1", groundTruth: "the cat sat", rawASR: "the bat sat", properNouns: [])]
        let rules = [Rule(alias: "bat", canonical: "cat")]
        let result = evaluator.run(manifest: manifest, rules: rules)
        XCTAssertEqual(result.wer, 0, accuracy: 0.0001)
        XCTAssertEqual(result.localOnlyPercent, 1, accuracy: 0.0001)
    }

    func testWERWithoutRulesReflectsRawErrors() {
        let manifest = [ManifestEntry(id: "1", groundTruth: "the cat sat", rawASR: "the bat sat", properNouns: [])]
        let result = evaluator.run(manifest: manifest, rules: [])
        XCTAssertEqual(result.wer, 1.0 / 3.0, accuracy: 0.0001)       // one substitution over three ref tokens
        XCTAssertEqual(result.localOnlyPercent, 2.0 / 3.0, accuracy: 0.0001) // two of three tokens correct locally
    }

    func testWERIsCaseInsensitive() {
        let manifest = [ManifestEntry(id: "1", groundTruth: "Hello World", rawASR: "hello world", properNouns: [])]
        XCTAssertEqual(evaluator.run(manifest: manifest, rules: []).wer, 0, accuracy: 0.0001)
    }

    func testCorpusWERAggregatesAcrossPhrases() {
        let manifest = [
            ManifestEntry(id: "1", groundTruth: "a b", rawASR: "a x", properNouns: []),       // 1 edit / 2
            ManifestEntry(id: "2", groundTruth: "c d e f", rawASR: "c d e f", properNouns: []), // 0 / 4
        ]
        // corpus WER = total edits / total ref tokens = 1 / 6
        XCTAssertEqual(evaluator.run(manifest: manifest, rules: []).wer, 1.0 / 6.0, accuracy: 0.0001)
    }

    // MARK: - Proper-noun accuracy

    func testProperNounAccuracyIsCaseSensitive() {
        let manifest = [ManifestEntry(id: "1", groundTruth: "ping Kuba", rawASR: "ping cuba", properNouns: ["Kuba"])]
        XCTAssertEqual(evaluator.run(manifest: manifest, rules: []).properNounAccuracy, 0, accuracy: 0.0001)
        let rules = [Rule(alias: "cuba", canonical: "Kuba")]
        XCTAssertEqual(evaluator.run(manifest: manifest, rules: rules).properNounAccuracy, 1, accuracy: 0.0001)
    }

    func testMultiWordProperNoun() {
        let manifest = [ManifestEntry(id: "1", groundTruth: "won the Silicon Rally", rawASR: "won the Silicon Rally", properNouns: ["Silicon Rally"])]
        XCTAssertEqual(evaluator.run(manifest: manifest, rules: []).properNounAccuracy, 1, accuracy: 0.0001)
        let lower = [ManifestEntry(id: "2", groundTruth: "won the Silicon Rally", rawASR: "won the silicon rally", properNouns: ["Silicon Rally"])]
        XCTAssertEqual(evaluator.run(manifest: lower, rules: []).properNounAccuracy, 0, accuracy: 0.0001)
    }

    func testProperNounAccuracyAggregates() {
        let manifest = [
            ManifestEntry(id: "1", groundTruth: "Kuba", rawASR: "Cuba", properNouns: ["Kuba"]),
            ManifestEntry(id: "2", groundTruth: "Parakeet", rawASR: "Parakeet", properNouns: ["Parakeet"]),
        ]
        // 1 of 2 correct without rules.
        XCTAssertEqual(evaluator.run(manifest: manifest, rules: []).properNounAccuracy, 0.5, accuracy: 0.0001)
    }

    // MARK: - Local-Only %

    func testLocalOnlyClimbsWithRules() {
        let manifest = [ManifestEntry(id: "1", groundTruth: "ping Kuba about Hetzner",
                                      rawASR: "ping Cuba about Hetzner", properNouns: ["Kuba"])]
        let before = evaluator.run(manifest: manifest, rules: []).localOnlyPercent
        let after = evaluator.run(manifest: manifest, rules: [Rule(alias: "cuba", canonical: "Kuba")]).localOnlyPercent
        XCTAssertEqual(before, 3.0 / 4.0, accuracy: 0.0001)
        XCTAssertEqual(after, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(after, before)
    }

    // MARK: - Degenerate

    func testEmptyManifest() {
        let result = evaluator.run(manifest: [], rules: [])
        XCTAssertEqual(result.perPhrase.count, 0)
        XCTAssertEqual(result.wer, 0)
        XCTAssertEqual(result.properNounAccuracy, 1)
        XCTAssertEqual(result.localOnlyPercent, 1)
    }

    func testPerPhraseResultsArePopulated() {
        let manifest = [ManifestEntry(id: "x", groundTruth: "ping Kuba", rawASR: "ping cuba", properNouns: ["Kuba"])]
        let result = evaluator.run(manifest: manifest, rules: [Rule(alias: "cuba", canonical: "Kuba")])
        XCTAssertEqual(result.perPhrase.count, 1)
        XCTAssertEqual(result.perPhrase[0].id, "x")
        XCTAssertEqual(result.perPhrase[0].hypothesis, "ping Kuba")
        XCTAssertEqual(result.perPhrase[0].properNounsCorrect, 1)
        XCTAssertEqual(result.perPhrase[0].properNounsTotal, 1)
    }

    // MARK: - Anti-overfit

    func testAntiOverfitPreservesNeighborsWithContextGatedRule() {
        let nearMiss = [ManifestEntry(id: "n1", groundTruth: "we love Cuba", rawASR: "we love Cuba", properNouns: ["Cuba"])]
        let rule = Rule(alias: "cuba", canonical: "Kuba", context: ["harness"]) // gated → won't fire here
        let result = evaluator.runAntiOverfit(nearMiss: nearMiss, rules: [rule])
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.preserved, 1)
        XCTAssertTrue(result.regressions.isEmpty)
    }

    func testAntiOverfitDetectsRegressionFromOverEagerRule() {
        let nearMiss = [ManifestEntry(id: "n1", groundTruth: "we love Cuba", rawASR: "we love Cuba", properNouns: ["Cuba"])]
        let rule = Rule(alias: "cuba", canonical: "Kuba", context: []) // global → wrongly fires
        let result = evaluator.runAntiOverfit(nearMiss: nearMiss, rules: [rule])
        XCTAssertFalse(result.passed)
        XCTAssertEqual(result.regressions, ["n1"])
        XCTAssertEqual(result.preservationRate, 0, accuracy: 0.0001)
    }

    // MARK: - Manifest loading

    func testLoadManifestRoundTrips() throws {
        let entries = [ManifestEntry(id: "1", groundTruth: "a", rawASR: "a", properNouns: ["A"])]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("offtype-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(entries).write(to: url)
        XCTAssertEqual(try evaluator.loadManifest(at: url), entries)
    }

    func testLoadManifestThrowsTypedErrorOnMissingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/offtype/\(UUID()).json")
        XCTAssertThrowsError(try evaluator.loadManifest(at: url)) { error in
            guard case EvalError.manifestUnreadable = error else {
                return XCTFail("expected EvalError.manifestUnreadable, got \(error)")
            }
        }
    }
}
