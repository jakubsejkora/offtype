import SwiftUI
import OfftypeCore

// The signature "Dynamic Circle": a living privacy lamp that sits by the notch.
// Its color is the proof — cyan while listening, emerald when work stays local
// (free, instant), amber when the cloud is touched. A faint "cloud-drain" ring
// renders Local-Only % right on the orb: amber arc draining into emerald as
// rules take over. Idle breathes; listening shows a live level ring + sonar +
// radial waveform; processing spins a route-tinted arc behind a local/cloud
// glyph; result snaps to a checkmark.
public struct DynamicCircleView: View {
    public var state: PipelineState
    public var route: HUDRoute
    /// Fraction of recent work handled locally (0...1) — drives the drain ring.
    public var localFraction: Double
    public var diameter: CGFloat

    @State private var levels: [CGFloat]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let sampleCount = 40

    /// The view reserves a square this many times the orb diameter, so glow and
    /// sonar never clip. Callers anchoring the orb (e.g. the notch panel) use this
    /// to find the orb's center inside the reserved frame.
    public static let reservedScale: CGFloat = 2.2

    public init(
        state: PipelineState = .idle,
        route: HUDRoute = .local,
        localFraction: Double = 1,
        diameter: CGFloat = 30
    ) {
        self.state = state
        self.route = route
        self.localFraction = max(0, min(1, localFraction))
        self.diameter = diameter
        _levels = State(initialValue: Array(repeating: 0, count: Self.sampleCount))
    }

    // Derived
    private var phase: HUDPhase { state.hudPhase }
    private var level: CGFloat { CGFloat(state.hudLevel) }

    private var tint: Color {
        switch phase {
        case .idle: return HUDPalette.idle
        case .listening: return HUDPalette.signal
        case .processing: return route.tint
        case .result(let ok): return ok ? HUDPalette.local : HUDPalette.alert
        }
    }

    public var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            content(t: t)
        }
        .frame(width: diameter, height: diameter)
        // Generous overflow room for glow + sonar without clipping.
        .frame(width: diameter * Self.reservedScale, height: diameter * Self.reservedScale)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Offtype")
        .accessibilityValue(phase.word)
        .onChange(of: state.hudLevel) { _, new in
            levels.append(CGFloat(new))
            if levels.count > Self.sampleCount {
                levels.removeFirst(levels.count - Self.sampleCount)
            }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase != .listening {
                withAnimation(.easeOut(duration: 0.35)) {
                    levels = Array(repeating: 0, count: Self.sampleCount)
                }
            }
        }
    }

    @ViewBuilder
    private func content(t: TimeInterval) -> some View {
        let breathe = reduceMotion ? 0 : sin(t * 1.6) * 0.5 + 0.5      // 0...1
        let idleScale = 1 + (phase == .idle ? CGFloat(breathe) * 0.04 : 0)

        ZStack {
            glow(t: t, breathe: breathe)
            drainRing
            if phase == .listening { listeningLayers(t: t) }
            orb
            if phase == .processing { processingArc(t: t) }
            glyph
        }
        .scaleEffect(idleScale)
    }

    // MARK: Layers

    private var orb: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [tint.opacity(0.95), tint.opacity(0.55)],
                    center: .init(x: 0.35, y: 0.3),
                    startRadius: 0,
                    endRadius: diameter * 0.7
                )
            )
            .overlay {
                // Glossy top highlight.
                Ellipse()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: diameter * 0.5, height: diameter * 0.32)
                    .blur(radius: diameter * 0.06)
                    .offset(y: -diameter * 0.2)
                    .blendMode(.screen)
            }
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: max(0.5, diameter * 0.02))
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: tint.opacity(0.55), radius: diameter * 0.18)
    }

    private func glow(t: TimeInterval, breathe: Double) -> some View {
        let listeningBoost = phase == .listening ? (0.4 + level * 0.6) : 1
        let base: Double = {
            switch phase {
            case .idle: return 0.18 + breathe * 0.10
            case .listening: return 0.45
            case .processing: return 0.4
            case .result: return 0.55
            }
        }()
        return Circle()
            .fill(tint)
            .frame(width: diameter, height: diameter)
            .scaleEffect(1.5)
            .blur(radius: diameter * 0.5)
            .opacity(base * listeningBoost)
    }

    /// The orb's "soul": how local you are, rendered as a thin ring (amber →
    /// emerald). Quietly present at all times so the thesis is always on screen.
    private var drainRing: some View {
        let lw = max(1, diameter * 0.07)
        let visible: Bool = {
            switch phase {
            case .result, .idle: return true
            default: return false
            }
        }()
        return ZStack {
            Circle()
                .trim(from: 0, to: localFraction)
                .stroke(HUDPalette.local, style: StrokeStyle(lineWidth: lw, lineCap: .round))
            Circle()
                .trim(from: localFraction, to: 1)
                .stroke(HUDPalette.cloud.opacity(0.9), style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
        .rotationEffect(.degrees(-90))
        .frame(width: diameter * 1.42, height: diameter * 1.42)
        .opacity(visible ? 0.85 : 0.0)
    }

    @ViewBuilder
    private func listeningLayers(t: TimeInterval) -> some View {
        // Sonar: two rings expanding out, amplitude scaled by live level.
        ForEach(0..<2, id: \.self) { i in
            let speed = 0.9
            let progress = (t * speed + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
            let amp = 0.4 + level * 0.7
            Circle()
                .stroke(HUDPalette.signal.opacity((1 - progress) * 0.5), lineWidth: 2)
                .frame(width: diameter, height: diameter)
                .scaleEffect(1 + CGFloat(progress) * 0.9 * amp)
        }
        // Live level ring hugging the orb.
        Circle()
            .stroke(HUDPalette.signal.opacity(0.7), lineWidth: max(1.5, diameter * 0.05))
            .frame(width: diameter, height: diameter)
            .scaleEffect(1.06 + level * 0.5)
        // Radial waveform from the mic level history.
        waveform(t: t)
    }

    private func waveform(t: TimeInterval) -> some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let inner = diameter * 0.62
            let count = levels.count
            guard count > 0 else { return }
            let spin = reduceMotion ? 0 : t * 0.5
            for i in 0..<count {
                let frac = Double(i) / Double(count)
                let angle = frac * 2 * .pi + spin
                let lvl = levels[i]
                let len = diameter * (0.05 + lvl * 0.42)
                let p0 = CGPoint(x: c.x + cos(angle) * inner, y: c.y + sin(angle) * inner)
                let p1 = CGPoint(x: c.x + cos(angle) * (inner + len), y: c.y + sin(angle) * (inner + len))
                var path = Path()
                path.move(to: p0)
                path.addLine(to: p1)
                ctx.stroke(
                    path,
                    with: .color(HUDPalette.signal.opacity(0.35 + Double(lvl) * 0.55)),
                    style: StrokeStyle(lineWidth: max(1, diameter * 0.04), lineCap: .round)
                )
            }
        }
        .frame(width: diameter * Self.reservedScale, height: diameter * Self.reservedScale)
        .allowsHitTesting(false)
    }

    private func processingArc(t: TimeInterval) -> some View {
        let lw = max(2, diameter * 0.08)
        return Circle()
            .trim(from: 0, to: 0.22)
            .stroke(
                AngularGradient(colors: [route.tint.opacity(0), route.tint], center: .center),
                style: StrokeStyle(lineWidth: lw, lineCap: .round)
            )
            .frame(width: diameter * 1.34, height: diameter * 1.34)
            .rotationEffect(.degrees(reduceMotion ? 0 : t * 320))
    }

    @ViewBuilder
    private var glyph: some View {
        switch phase {
        case .processing:
            Image(systemName: route.glyph)
                .font(.system(size: diameter * 0.4, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 1)
                .transition(.scale.combined(with: .opacity))
        case .result(let ok):
            Image(systemName: ok ? "checkmark" : "exclamationmark")
                .font(.system(size: diameter * 0.46, weight: .heavy))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 1)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
        case .idle, .listening:
            EmptyView()
        }
    }
}

// MARK: - Previews

#Preview("Circle states") {
    HStack(spacing: 36) {
        VStack { DynamicCircleView(state: .idle, diameter: 90); Text("idle") }
        VStack { DynamicCircleView(state: .listening(level: 0.7), diameter: 90); Text("listening") }
        VStack { DynamicCircleView(state: .processing, route: .cloud, diameter: 90); Text("cloud") }
        VStack { DynamicCircleView(state: .processing, route: .local, diameter: 90); Text("local") }
        VStack { DynamicCircleView(state: .result(ok: true), localFraction: 0.84, diameter: 90); Text("result") }
    }
    .padding(60)
    .background(Color.black)
    .foregroundStyle(.white)
}
