import SwiftUI
import OfftypeCore

// MARK: - HUD-side view of PipelineState
//
// The HUD animates on a coarse `phase` (so the live mic `level` can update every
// frame without re-triggering spring transitions), while reading `level`
// directly for the waveform.

/// The four visual phases of the Dynamic Circle, derived from `PipelineState`.
public enum HUDPhase: Sendable, Equatable {
    case idle
    case listening
    case processing
    case result(ok: Bool)
}

public extension PipelineState {
    /// Coarse phase used to key spring transitions (ignores the live mic level).
    var hudPhase: HUDPhase {
        switch self {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .processing
        case .result(let ok): return .result(ok: ok)
        }
    }

    /// The live mic level in 0...1 while listening, else 0.
    var hudLevel: Double {
        if case .listening(let level) = self { return Double(max(0, min(1, level))) }
        return 0
    }
}

public extension HUDPhase {
    /// Short status word for the notch pill / accessibility.
    var word: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .processing: return "Working"
        case .result(let ok): return ok ? "Done" : "Check"
        }
    }
}
