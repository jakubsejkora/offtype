import Foundation
import OfftypeCore

// AGENT(Telemetry): maintain the "Learned" panel counters in LearnedStats
// (rules/words learned, LLM + Gemini calls avoided, tokens/$ + latency saved,
// Local-Only %), updated from each RewriteResult's decisions and from learning
// events. Persist via Persistence so counters survive relaunch and the demo can
// boot into a believable "already-learned" state.

public final class Telemetry: @unchecked Sendable {
    public private(set) var stats = LearnedStats()
    public init(stats: LearnedStats = LearnedStats()) { self.stats = stats }

    /// AGENT: fold a rewrite's per-span decisions into cumulative stats
    /// (count rule/dictionary spans as cloud calls avoided; sum tokens/latency saved;
    /// recompute Local-Only %).
    public func record(_ result: RewriteResult) {}
}
