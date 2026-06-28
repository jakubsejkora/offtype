import XCTest
import OfftypeCore
@testable import Telemetry

final class TelemetryTests: XCTestCase {

    private func decision(_ source: RewriteSource, tokens: Int = 0) -> SpanDecision {
        SpanDecision(original: "x", output: "y", source: source, tokensUsed: tokens)
    }

    func testRecordCountsLocalSpansAsAvoidedCalls() {
        let telemetry = Telemetry(estimates: TelemetryEstimates(tokensPerAvoidedCall: 100, latencyPerAvoidedCallMS: 200))
        let result = RewriteResult(finalText: "y", decisions: [
            decision(.rule),
            decision(.unchanged),
            decision(.dictionary),
            decision(.cloudLLM, tokens: 500),
        ])
        telemetry.record(result)

        let stats = telemetry.stats
        XCTAssertEqual(stats.llmCallsAvoided, 2)              // rule + dictionary
        XCTAssertEqual(stats.tokensSaved, 200)               // 2 × 100
        XCTAssertEqual(stats.latencySavedMS, 400, accuracy: 0.0001) // 2 × 200
        XCTAssertEqual(stats.localOnlyPercent, 0.75, accuracy: 0.0001) // 3 of 4 spans local
    }

    func testCumulativeAcrossMultipleRewrites() {
        let telemetry = Telemetry()
        telemetry.record(RewriteResult(finalText: "y", decisions: [decision(.rule), decision(.cloudLLM)]))
        telemetry.record(RewriteResult(finalText: "y", decisions: [decision(.rule), decision(.rule)]))
        let stats = telemetry.stats
        XCTAssertEqual(stats.llmCallsAvoided, 3)
        // 3 local of 4 total spans.
        XCTAssertEqual(stats.localOnlyPercent, 0.75, accuracy: 0.0001)
    }

    func testRecordLearningTracksRulesAndWords() {
        let telemetry = Telemetry()
        telemetry.recordLearning(rulesLearned: 4, wordsAdded: 3)
        telemetry.recordLearning(rulesLearned: 1, wordsAdded: 0)
        XCTAssertEqual(telemetry.stats.rulesLearned, 5)
        XCTAssertEqual(telemetry.stats.wordsAdded, 3)
    }

    func testRecordMacroReplayTracksGeminiAvoided() {
        let telemetry = Telemetry()
        telemetry.recordMacroReplay()
        telemetry.recordMacroReplay(geminiCallsAvoided: 2)
        XCTAssertEqual(telemetry.stats.geminiCallsAvoided, 3)
    }

    func testDefaultEstimatesProduceBelievableSavings() {
        let telemetry = Telemetry() // defaults: 120 tokens, 350 ms
        telemetry.record(RewriteResult(finalText: "y", decisions: [decision(.rule), decision(.dictionary)]))
        XCTAssertEqual(telemetry.stats.tokensSaved, 240)
        XCTAssertEqual(telemetry.stats.latencySavedMS, 700, accuracy: 0.0001)
    }

    func testInitialStatsAreSeedable() {
        var seed = LearnedStats()
        seed.rulesLearned = 9
        seed.tokensSaved = 2310
        let telemetry = Telemetry(stats: seed)
        XCTAssertEqual(telemetry.stats.rulesLearned, 9)
        XCTAssertEqual(telemetry.stats.tokensSaved, 2310)
    }

    func testEmptyResultDoesNotDivideByZero() {
        let telemetry = Telemetry()
        telemetry.record(RewriteResult(finalText: "", decisions: []))
        XCTAssertEqual(telemetry.stats.localOnlyPercent, 0)
        XCTAssertEqual(telemetry.stats.llmCallsAvoided, 0)
    }
}
