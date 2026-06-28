import SwiftUI

// The privacy proof, distilled to one dot. It is DARK whenever nothing is in
// flight — and that darkness is the entire pitch ("nothing left your Mac").
// It lights (amber, pulsing) only while `active`, i.e. during a real cloud call.
public struct NetworkIndicator: View {
    public var active: Bool
    public var showsLabel: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(active: Bool, showsLabel: Bool = true) {
        self.active = active
        self.showsLabel = showsLabel
    }

    private var tint: Color { active ? HUDPalette.cloud : HUDPalette.local }

    public var body: some View {
        HStack(spacing: 7) {
            dot
            if showsLabel {
                Text(active ? "Cloud active" : "On-device")
                    .font(.hudLabel(11, .semibold))
                    .foregroundStyle(active ? HUDPalette.cloud : HUDPalette.inkDim)
                    .contentTransition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.25), value: active)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Network")
        .accessibilityValue(active ? "Cloud active" : "On-device, nothing leaving this Mac")
    }

    private var dot: some View {
        TimelineView(.animation(paused: reduceMotion || !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = active && !reduceMotion ? (sin(t * 5) * 0.5 + 0.5) : 0
            ZStack {
                // Halo only when active.
                Circle()
                    .fill(tint)
                    .frame(width: 10, height: 10)
                    .scaleEffect(1 + CGFloat(pulse) * 1.4)
                    .opacity(active ? 0.35 * (1 - pulse) : 0)
                Circle()
                    .fill(active ? AnyShapeStyle(tint) : AnyShapeStyle(HUDPalette.idle.opacity(0.5)))
                    .frame(width: 8, height: 8)
                    .overlay { Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5) }
                    .shadow(color: active ? tint.opacity(0.8) : .clear, radius: 5)
            }
            .frame(width: 18, height: 18)
        }
    }
}

#Preview("Network") {
    VStack(alignment: .leading, spacing: 16) {
        NetworkIndicator(active: false)
        NetworkIndicator(active: true)
        NetworkIndicator(active: false, showsLabel: false)
    }
    .padding(40)
    .background(Color.black)
}
