import XCTest

import OfftypeCore
@testable import Transcription

final class ParakeetTranscriberTests: XCTestCase {

    private let boundary = "\u{2581}"  // ▁

    // MARK: - SentencePiece token → word-span merge

    func testMergesSubwordTokensIntoWords() {
        // "Hello world." — a boundary opens each word; trailing "." extends "world".
        let tokens: [(text: String, confidence: Double?)] = [
            ("\(boundary)Hello", 0.9),
            ("\(boundary)world", 0.8),
            (".", 1.0),
        ]

        let spans = ParakeetTranscriber.wordSpans(fromTokens: tokens)
        XCTAssertEqual(spans.map(\.text), ["Hello", "world."])
        XCTAssertEqual(spans[0].confidence ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertEqual(spans[1].confidence ?? 0, 0.9, accuracy: 1e-9)  // mean(0.8, 1.0)
    }

    func testSubwordContinuationsJoinWithoutSpace() {
        let tokens: [(text: String, confidence: Double?)] = [
            ("\(boundary)un", 0.5),
            ("believ", 0.6),
            ("able", 0.7),
        ]

        let spans = ParakeetTranscriber.wordSpans(fromTokens: tokens)
        XCTAssertEqual(spans.map(\.text), ["unbelievable"])
        XCTAssertEqual(spans[0].confidence ?? 0, 0.6, accuracy: 1e-9)  // mean(0.5, 0.6, 0.7)
    }

    func testLeadingTokenWithoutBoundaryStillStartsAWord() {
        let tokens: [(text: String, confidence: Double?)] = [
            ("Hello", 0.9),
            ("\(boundary)there", 0.8),
        ]
        let spans = ParakeetTranscriber.wordSpans(fromTokens: tokens)
        XCTAssertEqual(spans.map(\.text), ["Hello", "there"])
    }

    func testNilConfidencesProduceNilSpanConfidence() {
        let tokens: [(text: String, confidence: Double?)] = [
            ("\(boundary)test", nil)
        ]
        let spans = ParakeetTranscriber.wordSpans(fromTokens: tokens)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].text, "test")
        XCTAssertNil(spans[0].confidence)
    }

    func testEmptyTokensProduceNoSpans() {
        XCTAssertTrue(ParakeetTranscriber.wordSpans(fromTokens: []).isEmpty)
    }

    // MARK: - StubTranscriber (offline/test default)

    func testStubTranscriberSplitsIntoSpans() async throws {
        let stub = StubTranscriber(returning: "alpha beta gamma")
        let transcript = try await stub.transcribe(
            AudioSamples(samples: [], sampleRate: 16_000))
        XCTAssertEqual(transcript.rawText, "alpha beta gamma")
        XCTAssertEqual(transcript.spans.map(\.text), ["alpha", "beta", "gamma"])
    }

    // MARK: - Missing-model contract (must not crash)

    func testMissingModelIsHandledGracefully() async throws {
        let missingDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("offtype-no-parakeet-\(UUID().uuidString)", isDirectory: true)
        let transcriber = ParakeetTranscriber(
            modelDirectory: missingDir, allowDownloadFallback: false)
        let audio = AudioSamples(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)

        do {
            let transcript = try await transcriber.transcribe(audio)
            // Fallback build (compiled without FluidAudio): degrades to an empty transcript.
            XCTAssertTrue(transcript.rawText.isEmpty)
            XCTAssertTrue(transcript.spans.isEmpty)
        } catch let error as OfftypeError {
            // Primary build: an absent model surfaces as a typed, recoverable error.
            guard case .modelNotFound = error else {
                return XCTFail("expected .modelNotFound, got \(error)")
            }
        }
    }
}
