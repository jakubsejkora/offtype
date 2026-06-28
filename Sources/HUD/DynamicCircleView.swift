import SwiftUI
import OfftypeCore

// AGENT(HUD): build the signature "Dynamic Circle" — a borderless, always-on-top
// NSPanel anchored to the right of the MacBook notch — plus the Learned panel,
// the debug strip (raw vs final), and the network indicator. Drive it from an
// observable view-model holding PipelineState + LearnedStats + last RewriteResult.
// Animate idle → listening (live waveform from mic level) → processing
// (local glyph vs cloud glyph) → result (checkmark + badge). Mirror the hero
// number + Learned panel center-screen too (projectors clip the notch edge).

/// Placeholder view so the package compiles before implementation.
public struct DynamicCircleView: View {
    public var state: PipelineState
    public init(state: PipelineState = .idle) { self.state = state }
    public var body: some View {
        Circle()
            .fill(.secondary)
            .frame(width: 28, height: 28)
            .accessibilityLabel("Offtype status")
    }
}
