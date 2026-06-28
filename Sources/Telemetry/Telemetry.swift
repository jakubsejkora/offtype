import Foundation
import OfftypeCore

// The "Learned" panel's brain: folds each rewrite's per-span decisions and every
// learning event into cumulative `LearnedStats` (rules/words learned, LLM calls
// avoided, tokens/latency saved, Local-Only %). The app persists `stats` via
// `Persistence.StatRepository` so counters survive relaunch and the demo boots into
// a believable "already-learned" state.

/// Per-avoided-call cost estimates used to translate locally-handled spans into a
/// believable "tokens/latency saved" number. These are explicitly *estimates* of
/// the cloud cost we did NOT pay; override to match your model's real economics.
public struct TelemetryEstimates: Sendable, Equatable {
    public var tokensPerAvoidedCall: Int
    public var latencyPerAvoidedCallMS: Double

    public init(tokensPerAvoidedCall: Int = 120, latencyPerAvoidedCallMS: Double = 350) {
        self.tokensPerAvoidedCall = tokensPerAvoidedCall
        self.latencyPerAvoidedCallMS = latencyPerAvoidedCallMS
    }
}

public final class Telemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var _stats: LearnedStats
    private var spansSeen = 0
    private var localSpansSeen = 0
    public let estimates: TelemetryEstimates

    public init(stats: LearnedStats = LearnedStats(), estimates: TelemetryEstimates = TelemetryEstimates()) {
        self._stats = stats
        self.estimates = estimates
        // A restored `stats` keeps its persisted Local-Only %; the rolling span
        // tallies start fresh and refine the percentage as new rewrites arrive.
    }

    public var stats: LearnedStats {
        lock.lock(); defer { lock.unlock() }
        return _stats
    }

    /// Fold one rewrite into cumulative stats: every rule/dictionary span is an LLM
    /// call avoided (+ estimated tokens/latency saved); cloud spans are counted
    /// against Local-Only %.
    public func record(_ result: RewriteResult) {
        lock.lock(); defer { lock.unlock() }
        for decision in result.decisions {
            spansSeen += 1
            switch decision.source {
            case .rule, .dictionary:
                localSpansSeen += 1
                _stats.llmCallsAvoided += 1
                _stats.tokensSaved += estimates.tokensPerAvoidedCall
                _stats.latencySavedMS += estimates.latencyPerAvoidedCallMS
            case .unchanged:
                localSpansSeen += 1
            case .cloudLLM:
                break
            }
        }
        recomputeLocalOnly()
    }

    /// Record that a correction crystallized into rules + dictionary terms.
    public func recordLearning(rulesLearned: Int, wordsAdded: Int) {
        lock.lock(); defer { lock.unlock() }
        _stats.rulesLearned += rulesLearned
        _stats.wordsAdded += wordsAdded
    }

    /// Record a computer-use macro replay that ran with zero Gemini calls.
    public func recordMacroReplay(geminiCallsAvoided: Int = 1) {
        lock.lock(); defer { lock.unlock() }
        _stats.geminiCallsAvoided += geminiCallsAvoided
    }

    private func recomputeLocalOnly() {
        _stats.localOnlyPercent = spansSeen == 0 ? 0 : Double(localSpansSeen) / Double(spansSeen)
    }
}
