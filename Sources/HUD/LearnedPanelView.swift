import SwiftUI
import OfftypeCore

// The Learned panel: live counters that climb as corrections crystallize into
// free local rules. The big Local-Only dial is the hero number; the tiles are
// the receipts (rules, words, cloud calls avoided, tokens + latency saved).
public struct LearnedPanelView: View {
    public var stats: LearnedStats
    /// Local-Only as a 0...1 fraction (drives the dial).
    public var localOnlyFraction: Double

    public init(stats: LearnedStats, localOnlyFraction: Double) {
        self.stats = stats
        self.localOnlyFraction = max(0, min(1, localOnlyFraction))
    }

    private var callsAvoided: Int { stats.llmCallsAvoided + stats.geminiCallsAvoided }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Eyebrow("Learned", tint: HUDPalette.local)
                Text("every correction becomes a rule")
                    .font(.hudLabel(10, .medium))
                    .foregroundStyle(HUDPalette.inkDim)
                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 18) {
                RingGauge(value: localOnlyFraction, tint: HUDPalette.local, lineWidth: 13, caption: "Local-Only")
                    .frame(width: 144, height: 144)

                LazyVGrid(columns: columns, spacing: 10) {
                    MetricTile(icon: "checklist", value: Double(stats.rulesLearned),
                               display: stats.rulesLearned.formatted(), label: "Rules learned", tint: HUDPalette.local)
                    MetricTile(icon: "character.book.closed.fill", value: Double(stats.wordsAdded),
                               display: stats.wordsAdded.formatted(), label: "Words added", tint: HUDPalette.signal)
                    MetricTile(icon: "bolt.slash.fill", value: Double(callsAvoided),
                               display: callsAvoided.formatted(), label: "Cloud calls avoided", tint: HUDPalette.local)
                    MetricTile(icon: "number.circle.fill", value: Double(stats.tokensSaved),
                               display: stats.tokensSaved.formatted(), label: "Tokens saved", tint: HUDPalette.local)
                }
            }

            latencyRow
        }
        .padding(18)
        .glassCard()
    }

    private var latencyRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(HUDPalette.signal)
            Text("Latency saved")
                .font(.hudLabel(12, .semibold))
                .foregroundStyle(HUDPalette.inkDim)
            Spacer(minLength: 0)
            Text(Self.latency(stats.latencySavedMS))
                .font(.hudNumber(18, .bold))
                .monospacedDigit()
                .foregroundStyle(HUDPalette.ink)
                .contentTransition(.numericText(value: stats.latencySavedMS))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HUDPalette.well)
        }
    }

    static func latency(_ ms: Double) -> String {
        if ms >= 1000 {
            return (ms / 1000).formatted(.number.precision(.fractionLength(1))) + " s"
        }
        return Int(ms.rounded()).formatted() + " ms"
    }
}

#Preview("Learned panel") {
    var stats = LearnedStats()
    stats.rulesLearned = 16
    stats.wordsAdded = 34
    stats.llmCallsAvoided = 9
    stats.tokensSaved = 2310
    stats.latencySavedMS = 7020
    return LearnedPanelView(stats: stats, localOnlyFraction: 0.84)
        .frame(width: 520)
        .padding(40)
        .background(Color.black)
}
