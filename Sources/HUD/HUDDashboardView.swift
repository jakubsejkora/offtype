import SwiftUI
import OfftypeCore

// MARK: - Notch overlay (the signature, compact)
//
// What the notch panel hosts: the orb, plus a Dynamic-Island-style pill that
// slides out to the right with the current status while anything is happening,
// then tucks away in idle. Leading-aligned so the orb sits at a fixed point next
// to the notch and the pill grows into the menu-bar gap.
@MainActor
public struct NotchOverlayView: View {
    public var model: HUDModel
    public var orbDiameter: CGFloat

    public init(model: HUDModel, orbDiameter: CGFloat = 28) {
        self.model = model
        self.orbDiameter = orbDiameter
    }

    private var showsPill: Bool { model.state.hudPhase != .idle && !model.statusText.isEmpty }

    public var body: some View {
        HStack(spacing: 6) {
            DynamicCircleView(
                state: model.state,
                route: model.route,
                localFraction: model.hero.localOnlyPercent,
                diameter: orbDiameter
            )
            if showsPill {
                pill.transition(.move(edge: .leading).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        // Fill the panel so the orb stays vertically centered on the menu bar
        // regardless of how the host sizes the content.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: showsPill)
        .animation(.snappy(duration: 0.3), value: model.statusText)
    }

    private var pill: some View {
        HStack(spacing: 6) {
            if model.networkActive {
                NetworkIndicator(active: true, showsLabel: false)
            }
            Text(model.statusText)
                .font(.hudMono(11, .semibold))
                .foregroundStyle(HUDPalette.ink)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(model.route.tint.opacity(0.5), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

// MARK: - Full dashboard (the projector mirror + the preview surface)

/// The whole HUD on one surface: brand + network dot, the live scoreboard, the
/// orb stage, the Learned panel, and the proof strip. This is what mirrors to
/// center-screen for projectors (the notch edge clips on external displays) and
/// what the previews / demo render.
@MainActor
public struct HUDDashboardView: View {
    public var model: HUDModel

    public init(model: HUDModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HeroMetricsView(hero: model.hero, baseline: model.heroBaseline)
            HStack(alignment: .top, spacing: 16) {
                stage.frame(width: 280)
                LearnedPanelView(stats: model.stats, localOnlyFraction: model.hero.localOnlyPercent)
            }
            DebugStripView(rawText: model.rawText, finalText: model.finalText, rewrite: model.lastRewrite)
        }
        .padding(24)
        .frame(width: 880)
        .background { DashboardBackground() }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Offtype")
                    .font(.hudNumber(24, .heavy))
                    .foregroundStyle(HUDPalette.ink)
                Text("every correction becomes a rule")
                    .font(.hudLabel(11, .medium))
                    .foregroundStyle(HUDPalette.inkDim)
            }
            Spacer()
            NetworkIndicator(active: model.networkActive)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassCard(radius: 14)
        }
    }

    private var stage: some View {
        VStack(spacing: 12) {
            Eyebrow("Dictation")
            DynamicCircleView(
                state: model.state,
                route: model.route,
                localFraction: model.hero.localOnlyPercent,
                diameter: 104
            )
            .frame(width: 230, height: 150)
            .clipped()
            Text(model.state.hudPhase.word)
                .font(.hudNumber(20, .semibold))
                .foregroundStyle(HUDPalette.ink)
                .contentTransition(.opacity)
            if !model.statusText.isEmpty {
                Pill(model.statusText, tint: model.route.tint, filled: model.route == .local)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .top)
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .glassCard()
    }
}

/// Dark, slightly tinted backdrop so the glass cards read on a projector.
struct DashboardBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [HUDPalette.rgb(11, 14, 20), HUDPalette.rgb(17, 22, 33)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [HUDPalette.local.opacity(0.10), .clear],
                center: .topTrailing, startRadius: 0, endRadius: 520
            )
            RadialGradient(
                colors: [HUDPalette.signal.opacity(0.08), .clear],
                center: .bottomLeading, startRadius: 0, endRadius: 480
            )
        }
    }
}

// MARK: - Preview

#Preview("Dashboard — after climb") {
    HUDDashboardView(model: .demo)
        .padding(30)
        .background(Color.black)
}
