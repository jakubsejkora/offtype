import SwiftUI

// The money-shot scoreboard: three falsifiable numbers from the frozen held-out
// set. Each rolls with a numeric-text animation, and when a learning event has
// just landed, a delta chip shows where it came from ("was 43%") so the climb is
// legible as a before→after story.
public struct HeroMetricsView: View {
    public var hero: HeroMetrics
    public var baseline: HeroMetrics?

    public init(hero: HeroMetrics, baseline: HeroMetrics? = nil) {
        self.hero = hero
        self.baseline = baseline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("Live scoreboard · frozen held-out set")
            HStack(alignment: .top, spacing: 0) {
                HeroStat(label: "Proper-noun accuracy",
                         value: hero.properNounAccuracy, baseline: baseline?.properNounAccuracy,
                         higherIsBetter: true, fraction: 0)
                divider
                HeroStat(label: "Word error rate",
                         value: hero.wer, baseline: baseline?.wer,
                         higherIsBetter: false, fraction: 1)
                divider
                HeroStat(label: "Local-Only",
                         value: hero.localOnlyPercent, baseline: baseline?.localOnlyPercent,
                         higherIsBetter: true, fraction: 0)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var divider: some View {
        Rectangle()
            .fill(HUDPalette.hairline)
            .frame(width: 1, height: 64)
            .frame(maxWidth: .infinity)
    }
}

private struct HeroStat: View {
    let label: String
    let value: Double
    let baseline: Double?
    let higherIsBetter: Bool
    let fraction: Int

    private var improved: Bool? {
        guard let baseline, baseline != value else { return nil }
        return higherIsBetter ? value > baseline : value < baseline
    }

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            Eyebrow(label)
            Text(value.asPercent(fraction))
                .font(.hudNumber(48, .heavy))
                .monospacedDigit()
                .foregroundStyle(HUDPalette.ink)
                .contentTransition(.numericText(value: value))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            delta
                .frame(height: 18)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var delta: some View {
        if let baseline, let improved {
            let tint = improved ? HUDPalette.local : HUDPalette.alert
            HStack(spacing: 4) {
                Image(systemName: improved ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .black))
                Text("was \(baseline.asPercent(fraction))")
                    .font(.hudLabel(11, .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background { Capsule().fill(tint.opacity(0.16)) }
            .transition(.scale(scale: 0.7).combined(with: .opacity))
        }
    }
}

#Preview("Hero — after climb") {
    HeroMetricsView(
        hero: HeroMetrics(properNounAccuracy: 0.92, localOnlyPercent: 0.84, wer: 0.042),
        baseline: HeroMetrics(properNounAccuracy: 0.43, localOnlyPercent: 0.31, wer: 0.186)
    )
    .frame(width: 720)
    .padding(40)
    .background(Color.black)
}
