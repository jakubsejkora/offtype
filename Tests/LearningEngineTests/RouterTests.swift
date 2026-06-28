import XCTest
import OfftypeCore
@testable import LearningEngine

// A cleaner that returns a fixed, recognizable output so we can detect whether it
// was invoked. Sendable + side-effect-free (state is observed via the result).
private struct StubCleaner: Cleaner {
    var text: String
    var tokensUsed: Int
    var latencyMS: Double
    func clean(_ text: String, context: [String]) async throws -> CleanupOutput {
        CleanupOutput(text: self.text, tokensUsed: tokensUsed, latencyMS: latencyMS)
    }
}

private struct ThrowingCleaner: Cleaner {
    func clean(_ text: String, context: [String]) async throws -> CleanupOutput {
        throw OfftypeError.cloudDisabled
    }
}

final class ConfidenceGateTests: XCTestCase {
    func testCoveredSpanNeverNeedsCloud() {
        let gate = ConfidenceGate(threshold: 0.6)
        XCTAssertFalse(gate.needsCloud(spanCovered: true, confidence: 0.0))
        XCTAssertFalse(gate.needsCloud(spanCovered: true, confidence: nil))
    }

    func testUncoveredLowConfidenceNeedsCloud() {
        let gate = ConfidenceGate(threshold: 0.6)
        XCTAssertTrue(gate.needsCloud(spanCovered: false, confidence: 0.59))
        XCTAssertTrue(gate.needsCloud(spanCovered: false, confidence: 0.0))
    }

    func testBoundaryIsInclusiveOfStayingLocal() {
        let gate = ConfidenceGate(threshold: 0.6)
        XCTAssertFalse(gate.needsCloud(spanCovered: false, confidence: 0.6))   // exactly threshold → local
        XCTAssertFalse(gate.needsCloud(spanCovered: false, confidence: 0.61))
    }

    func testMissingConfidenceStaysLocal() {
        let gate = ConfidenceGate(threshold: 0.6)
        XCTAssertFalse(gate.needsCloud(spanCovered: false, confidence: nil))
    }
}

final class RouterTests: XCTestCase {
    private let router = Router()

    private func transcript(_ raw: String, confidences: [Double?]? = nil) -> Transcript {
        let words = OfftypeText.words(raw)
        guard let confidences else { return Transcript(rawText: raw) }
        precondition(confidences.count == words.count)
        let spans = zip(words, confidences).map { TranscriptSpan(text: $0.0, confidence: $0.1) }
        return Transcript(rawText: raw, spans: spans)
    }

    func testAllowCloudFalseNeverReachesCleaner() async {
        let cleaner = StubCleaner(text: "CLEANED", tokensUsed: 99, latencyMS: 99)
        let result = await router.rewrite(
            transcript("ship the widget", confidences: [0.9, 0.9, 0.2]),
            rules: [], dictionary: [], cleaner: cleaner, allowCloud: false
        )
        XCTAssertEqual(result.finalText, "ship the widget")
        XCTAssertFalse(result.decisions.contains { $0.source == .cloudLLM })
        XCTAssertEqual(result.localOnlyFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(result.tokensUsed, 0)
    }

    func testLowConfidenceUncoveredSpanReachesCloud() async {
        let cleaner = StubCleaner(text: "CLEANED", tokensUsed: 42, latencyMS: 123)
        let result = await router.rewrite(
            transcript("ship the widget", confidences: [0.9, 0.9, 0.2]),
            rules: [], dictionary: [], cleaner: cleaner, allowCloud: true
        )
        XCTAssertEqual(result.finalText, "CLEANED")
        let cloud = result.decisions.filter { $0.source == .cloudLLM }
        XCTAssertEqual(cloud.count, 1)
        XCTAssertEqual(cloud.first?.original, "widget")
        XCTAssertEqual(result.tokensUsed, 42) // attributed exactly once
        XCTAssertEqual(result.localOnlyFraction, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testRuleCoveredSpanSkipsCloudEvenWhenLowConfidence() async {
        let rule = Rule(alias: "widget", canonical: "Widget", confidence: 1.0)
        let cleaner = StubCleaner(text: "CLEANED", tokensUsed: 42, latencyMS: 1)
        let result = await router.rewrite(
            transcript("ship the widget", confidences: [0.9, 0.9, 0.2]),
            rules: [rule], dictionary: [], cleaner: cleaner, allowCloud: true
        )
        XCTAssertEqual(result.finalText, "ship the Widget")
        XCTAssertFalse(result.decisions.contains { $0.source == .cloudLLM })
        XCTAssertEqual(result.localOnlyFraction, 1.0, accuracy: 0.0001)
    }

    func testCleanerFailureStaysLocal() async {
        let result = await router.rewrite(
            transcript("ship the widget", confidences: [0.9, 0.9, 0.2]),
            rules: [], dictionary: [], cleaner: ThrowingCleaner(), allowCloud: true
        )
        XCTAssertEqual(result.finalText, "ship the widget")
        XCTAssertFalse(result.decisions.contains { $0.source == .cloudLLM })
    }

    func testMissingConfidencesStayLocal() async {
        let cleaner = StubCleaner(text: "CLEANED", tokensUsed: 5, latencyMS: 5)
        let result = await router.rewrite(
            transcript("ship the widget"), // no spans → confidence nil → confident
            rules: [], dictionary: [], cleaner: cleaner, allowCloud: true
        )
        XCTAssertEqual(result.finalText, "ship the widget")
        XCTAssertFalse(result.decisions.contains { $0.source == .cloudLLM })
        XCTAssertEqual(result.localOnlyFraction, 1.0, accuracy: 0.0001)
    }

    func testNoCleanerStaysLocal() async {
        let result = await router.rewrite(
            transcript("ship the widget", confidences: [0.9, 0.9, 0.2]),
            rules: [], dictionary: [], cleaner: nil, allowCloud: true
        )
        XCTAssertEqual(result.finalText, "ship the widget")
        XCTAssertFalse(result.decisions.contains { $0.source == .cloudLLM })
    }

    func testRulesAndDictionaryAreLocalAndCloudIsTruthful() async {
        // Rule fixes one span, dictionary recases another, a third low-confidence span
        // goes to cloud. Local-Only % must reflect exactly that split.
        let rule = Rule(alias: "cuba", canonical: "Kuba", confidence: 1.0)
        let dictionary = [DictionaryEntry(term: "Hetzner", source: .correction)]
        let cleaner = StubCleaner(text: "CLEANED", tokensUsed: 10, latencyMS: 10)
        let result = await router.rewrite(
            transcript("ping cuba on hetzner via gizmo",
                       confidences: [0.95, 0.95, 0.95, 0.95, 0.95, 0.2]),
            rules: [rule], dictionary: dictionary, cleaner: cleaner, allowCloud: true
        )
        let sources = result.decisions.map(\.source)
        XCTAssertTrue(sources.contains(.rule))
        XCTAssertTrue(sources.contains(.dictionary))
        XCTAssertEqual(sources.filter { $0 == .cloudLLM }.count, 1)
        // 6 spans, 1 to cloud → 5/6 local.
        XCTAssertEqual(result.localOnlyFraction, 5.0 / 6.0, accuracy: 0.0001)
    }

    func testEmptyTranscriptIsSafe() async {
        let result = await router.rewrite(
            Transcript(rawText: ""), rules: [], dictionary: [], cleaner: nil, allowCloud: true
        )
        XCTAssertEqual(result.finalText, "")
        XCTAssertTrue(result.decisions.isEmpty)
        XCTAssertEqual(result.localOnlyFraction, 1.0, accuracy: 0.0001)
    }
}
