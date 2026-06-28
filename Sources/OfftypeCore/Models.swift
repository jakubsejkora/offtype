import Foundation

// MARK: - Audio

/// A buffer of mono PCM samples, normalized to `Float` in [-1, 1].
/// Produced by `AudioCapture`, consumed by a `Transcriber`.
public struct AudioSamples: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }
}

// MARK: - Transcription

/// One token/word span from the recognizer, retaining the model's confidence so
/// the `Router` can decide per-span whether a local rule suffices.
public struct TranscriptSpan: Sendable, Equatable, Codable {
    public var text: String
    public var confidence: Double?

    public init(text: String, confidence: Double? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

/// The raw, *uncorrected* recognizer output. `rawText` is preserved verbatim so
/// the demo's debug strip can prove the model still mis-hears while the learned
/// layer fixes the output.
public struct Transcript: Sendable, Equatable, Codable {
    public var rawText: String
    public var spans: [TranscriptSpan]
    public var locale: String

    public init(rawText: String, spans: [TranscriptSpan] = [], locale: String = "en_US") {
        self.rawText = rawText
        self.spans = spans
        self.locale = locale
    }
}

// MARK: - Learning store

/// A learned alias→canonical rewrite. The heart of "every correction becomes a
/// rule." `context` enables context-gating (e.g. apply `evil→eval` only near
/// `harness`/`run`), and `confidence` powers conflict resolution + rollback.
public struct Rule: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var alias: String          // what was heard, normalized (lowercased)
    public var canonical: String      // what it should be
    public var phoneticKey: String?   // Double-Metaphone of the alias, for fuzzy matching
    public var context: [String]      // optional gating tokens; empty == always applies
    public var confidence: Double     // 0...1
    public var enabled: Bool
    public var hitCount: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        alias: String,
        canonical: String,
        phoneticKey: String? = nil,
        context: [String] = [],
        confidence: Double = 1.0,
        enabled: Bool = true,
        hitCount: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.alias = alias
        self.canonical = canonical
        self.phoneticKey = phoneticKey
        self.context = context
        self.confidence = confidence
        self.enabled = enabled
        self.hitCount = hitCount
        self.createdAt = createdAt
    }
}

/// A personal-dictionary term (proper noun, jargon, acronym). Harvested from
/// corrections and from on-screen OCR. Used to bias rewriting toward known terms.
public struct DictionaryEntry: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var term: String
    public var weight: Double
    public var locale: String
    public var source: Source
    public var createdAt: Date

    public enum Source: String, Sendable, Codable { case correction, ocr, manual, seed }

    public init(
        id: UUID = UUID(),
        term: String,
        weight: Double = 1.0,
        locale: String = "en_US",
        source: Source = .manual,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.term = term
        self.weight = weight
        self.locale = locale
        self.source = source
        self.createdAt = createdAt
    }
}

/// A raw→corrected pair, the training signal the `DiffEngine` distills into rules.
public struct Correction: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var rawText: String
    public var correctedText: String
    public var appBundleID: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        rawText: String,
        correctedText: String,
        appBundleID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.rawText = rawText
        self.correctedText = correctedText
        self.appBundleID = appBundleID
        self.createdAt = createdAt
    }
}

// MARK: - Rewrite pipeline output

/// Where a given span's final text came from. Drives the HUD badge
/// (`rule applied · 0 tokens · 0 ms` vs `cloud · N tokens · X ms`).
public enum RewriteSource: String, Sendable, Equatable, Codable {
    case unchanged
    case rule
    case dictionary
    case cloudLLM
}

/// Per-span accounting for one rewrite — the evidence that the cloud was skipped.
public struct SpanDecision: Sendable, Equatable, Codable {
    public var original: String
    public var output: String
    public var source: RewriteSource
    public var ruleID: UUID?
    public var tokensUsed: Int
    public var latencyMS: Double

    public init(
        original: String,
        output: String,
        source: RewriteSource,
        ruleID: UUID? = nil,
        tokensUsed: Int = 0,
        latencyMS: Double = 0
    ) {
        self.original = original
        self.output = output
        self.source = source
        self.ruleID = ruleID
        self.tokensUsed = tokensUsed
        self.latencyMS = latencyMS
    }
}

/// The full result of running a transcript through the learned rewrite layer.
public struct RewriteResult: Sendable, Equatable, Codable {
    public var finalText: String
    public var decisions: [SpanDecision]

    public init(finalText: String, decisions: [SpanDecision] = []) {
        self.finalText = finalText
        self.decisions = decisions
    }

    /// Fraction of spans handled without any cloud/LLM call — the hero number.
    public var localOnlyFraction: Double {
        guard !decisions.isEmpty else { return 1 }
        let local = decisions.filter { $0.source != .cloudLLM }.count
        return Double(local) / Double(decisions.count)
    }

    public var tokensUsed: Int { decisions.reduce(0) { $0 + $1.tokensUsed } }
}

// MARK: - Counters & evaluation

/// Cumulative "Learned" panel counters.
public struct LearnedStats: Sendable, Equatable, Codable {
    public var rulesLearned: Int = 0
    public var wordsAdded: Int = 0
    public var llmCallsAvoided: Int = 0
    public var geminiCallsAvoided: Int = 0
    public var tokensSaved: Int = 0
    public var latencySavedMS: Double = 0
    public var localOnlyPercent: Double = 0

    public init() {}
}

/// Result of scoring one held-out phrase through the real pipeline.
public struct EvalPhraseResult: Sendable, Equatable, Codable {
    public var id: String
    public var groundTruth: String
    public var hypothesis: String
    public var wer: Double
    public var properNounsCorrect: Int
    public var properNounsTotal: Int

    public init(id: String, groundTruth: String, hypothesis: String, wer: Double, properNounsCorrect: Int, properNounsTotal: Int) {
        self.id = id
        self.groundTruth = groundTruth
        self.hypothesis = hypothesis
        self.wer = wer
        self.properNounsCorrect = properNounsCorrect
        self.properNounsTotal = properNounsTotal
    }
}

/// Aggregate metric over the frozen held-out manifest. Computed, never hardcoded.
public struct EvalResult: Sendable, Equatable, Codable {
    public var wer: Double
    public var properNounAccuracy: Double
    public var localOnlyPercent: Double
    public var perPhrase: [EvalPhraseResult]

    public init(wer: Double, properNounAccuracy: Double, localOnlyPercent: Double, perPhrase: [EvalPhraseResult]) {
        self.wer = wer
        self.properNounAccuracy = properNounAccuracy
        self.localOnlyPercent = localOnlyPercent
        self.perPhrase = perPhrase
    }
}
