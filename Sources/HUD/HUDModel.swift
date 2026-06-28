import SwiftUI
import Observation
import OfftypeCore

// MARK: - Hero metrics

/// The three "money shot" numbers, kept as 0...1 fractions and formatted as
/// percentages at the edge. `wer` is lower-is-better; the others higher-is-better.
public struct HeroMetrics: Sendable, Equatable, Codable {
    public var properNounAccuracy: Double
    public var localOnlyPercent: Double
    public var wer: Double

    public init(properNounAccuracy: Double = 0, localOnlyPercent: Double = 0, wer: Double = 0) {
        self.properNounAccuracy = properNounAccuracy
        self.localOnlyPercent = localOnlyPercent
        self.wer = wer
    }

    public static let zero = HeroMetrics()
}

// MARK: - HUDModel

/// The single observable surface that drives the entire HUD. The app mutates
/// these properties (ideally through the driving API below) and SwiftUI animates
/// the Dynamic Circle, the Learned panel, the proof strip, and the network dot.
///
/// All UI lives on the main actor; this model does too.
@MainActor
@Observable
public final class HUDModel {

    // MARK: Live pipeline

    /// Drives the Dynamic Circle: idle → listening(level) → processing → result.
    public var state: PipelineState = .idle

    /// Whether the current/last unit of work was handled locally or by the cloud.
    /// Picks the orb glyph and the green-vs-amber story.
    public var route: HUDRoute = .local

    /// The privacy proof. Lit ONLY while bytes are actually in flight to the cloud.
    /// Stays dark for the entire on-device path — that darkness is the pitch.
    public var networkActive: Bool = false

    // MARK: Proof strip (raw vs final)

    /// Verbatim recognizer output — preserved so the strip can show the model
    /// still mis-hears while the learned layer fixes the result.
    public var rawText: String = ""

    /// Text after the learned rewrite layer.
    public var finalText: String = ""

    /// Per-span accounting behind the proof strip badges.
    public var lastRewrite: RewriteResult?

    // MARK: Counters

    /// Cumulative "Learned" panel counters.
    public var stats: LearnedStats = LearnedStats()

    // MARK: Hero numbers (with a before/after baseline for animated deltas)

    /// Currently displayed hero numbers (animate toward new values).
    public var hero: HeroMetrics = .zero

    /// Snapshot of the hero numbers before the most recent learning event, so the
    /// UI can render "43% → 92%" deltas. Nil once a delta has been acknowledged.
    public var heroBaseline: HeroMetrics?

    // MARK: Ambient

    /// Short status used by the notch pill (e.g. "rule applied · 0 tokens · 0 ms").
    public var statusText: String = ""

    /// Backing task for the self-running demo (see `HUDModel+Demo`).
    @ObservationIgnored var demoTask: Task<Void, Never>?

    public init() {}

    // MARK: - Demo control

    /// Start the looping, mock-driven demo (no real pipeline needed).
    public func startDemo() {
        stopDemo()
        demoTask = Task { @MainActor [weak self] in await self?.runDemoScript() }
    }

    /// Stop the demo loop and leave the HUD wherever it is.
    public func stopDemo() {
        demoTask?.cancel()
        demoTask = nil
    }

    // MARK: - Driving API (what the app calls)

    /// Return the orb to its dim, dormant state.
    public func setIdle(animated: Bool = true) {
        run(animated, .snappy(duration: 0.3)) {
            self.state = .idle
            self.statusText = ""
        }
    }

    /// Enter the live listening state. Follow with repeated `updateLevel(_:)`.
    public func beginListening() {
        networkActive = false
        route = .local
        run(true, .snappy(duration: 0.28)) {
            self.state = .listening(level: 0)
            self.statusText = "Listening"
        }
    }

    /// Feed the live mic RMS (0...1) for the waveform. Cheap; call at ~30–60 Hz.
    /// Intentionally NOT animated — the waveform should track audio in real time.
    public func updateLevel(_ level: Float) {
        state = .listening(level: max(0, min(1, level)))
    }

    /// Begin the rewrite pass. `route` decides local (emerald, dot dark) vs cloud
    /// (amber, dot lit). This is the one place the network indicator turns on.
    public func beginProcessing(route: HUDRoute) {
        self.route = route
        networkActive = (route == .cloud)
        run(true, .snappy(duration: 0.28)) {
            self.state = .processing
            self.statusText = route == .cloud ? "Cleaning up · cloud" : "Applying rules · local"
        }
    }

    /// Land on the result state (checkmark + badge). Turns the network dot off.
    public func finish(ok: Bool) {
        networkActive = false
        run(true, .spring(duration: 0.4, bounce: 0.35)) {
            self.state = .result(ok: ok)
        }
    }

    /// Publish a completed rewrite to the proof strip. Derives the route, the
    /// network state (a result is never mid-flight), and the status badge from the
    /// per-span decisions — the un-fakeable accounting.
    public func apply(_ rewrite: RewriteResult, rawText: String) {
        self.rawText = rawText
        self.finalText = rewrite.finalText
        self.lastRewrite = rewrite
        let usedCloud = rewrite.decisions.contains { $0.source == .cloudLLM }
        route = usedCloud ? .cloud : .local
        networkActive = false
        statusText = Self.badge(for: rewrite)
    }

    /// Update the cumulative counters (animated bump by default).
    public func update(stats newStats: LearnedStats, animated: Bool = true) {
        run(animated, .snappy(duration: 0.5)) { self.stats = newStats }
    }

    /// Set the hero numbers. When animated, snapshots the previous values as the
    /// baseline so the UI can show the climb (e.g. proper-noun 43% → 92%).
    public func setHero(_ metrics: HeroMetrics, animated: Bool = true) {
        if animated {
            heroBaseline = hero
            run(true, .smooth(duration: 0.9)) { self.hero = metrics }
        } else {
            heroBaseline = nil
            hero = metrics
        }
    }

    /// Dismiss the before/after delta chips once the audience has seen the climb.
    public func clearHeroBaseline() {
        run(true, .easeOut(duration: 0.4)) { self.heroBaseline = nil }
    }

    // MARK: - Helpers

    /// The compact "source · tokens · ms" badge summarizing a rewrite.
    public static func badge(for rewrite: RewriteResult) -> String {
        let tokens = rewrite.tokensUsed
        let ms = rewrite.decisions.reduce(0) { $0 + $1.latencyMS }
        if tokens == 0 {
            return "rule applied · 0 tokens · 0 ms"
        }
        return "cloud · \(tokens.formatted()) tokens · \(Int(ms.rounded())) ms"
    }

    /// Run a mutation inside (or outside) a SwiftUI animation transaction.
    private func run(_ animated: Bool, _ animation: Animation, _ body: () -> Void) {
        if animated {
            withAnimation(animation, body)
        } else {
            body()
        }
    }
}
