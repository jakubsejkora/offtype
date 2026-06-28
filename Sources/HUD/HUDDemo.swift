import SwiftUI
import AppKit
import Foundation
import OfftypeCore

// MARK: - Demo data
//
// The hackathon "money shot", as mock data so the entire HUD can be shown with
// no microphone, no model, and no network. The hero sentence and its predicted
// raw ASR come straight from the demo script in the plan.
public enum DemoData {
    public static let rawSentence =
        "Ship the off type evil harness to Cuba — use Parakeet and Gemma Quant, then ping Cuba about Hetzner."
    public static let fixedSentence =
        "Ship the Offtype eval harness to Kuba — use Parakeet and GemmaQuant, then ping Kuba about Hetzner."

    static func dec(_ original: String, _ output: String, _ source: RewriteSource,
                    _ tokens: Int = 0, _ ms: Double = 0) -> SpanDecision {
        SpanDecision(original: original, output: output, source: source,
                     ruleID: source == .rule ? UUID() : nil, tokensUsed: tokens, latencyMS: ms)
    }

    /// Baseline pass: the cloud is billed (~610 tokens · 780 ms) and STILL gets the
    /// jargon wrong — the case against renting an LLM forever.
    public static let baselineRewrite = RewriteResult(
        finalText: rawSentence,
        decisions: [
            dec("Ship the", "Ship the", .unchanged),
            dec("off type", "off type", .cloudLLM, 170, 220),
            dec("evil", "evil", .cloudLLM, 90, 110),
            dec("harness to", "harness to", .unchanged),
            dec("Cuba", "Cuba", .cloudLLM, 110, 130),
            dec("— use Parakeet and", "— use Parakeet and", .unchanged),
            dec("Gemma Quant", "Gemma Quant", .cloudLLM, 140, 180),
            dec(", then ping", ", then ping", .unchanged),
            dec("Cuba", "Cuba", .cloudLLM, 100, 140),
            dec("about Hetzner.", "about Hetzner.", .unchanged),
        ]
    )

    /// Re-dictation after one correction: every jargon span fixed by a local rule
    /// or dictionary entry — 0 tokens, 0 ms, no cloud. The raw stays mis-heard.
    public static let fixedRewrite = RewriteResult(
        finalText: fixedSentence,
        decisions: [
            dec("Ship the", "Ship the", .unchanged),
            dec("off type", "Offtype", .rule),
            dec("evil", "eval", .rule),
            dec("harness to", "harness to", .unchanged),
            dec("Cuba", "Kuba", .rule),
            dec("— use Parakeet and", "— use Parakeet and", .unchanged),
            dec("Gemma Quant", "GemmaQuant", .dictionary),
            dec(", then ping", ", then ping", .unchanged),
            dec("Cuba", "Kuba", .rule),
            dec("about Hetzner.", "about Hetzner.", .unchanged),
        ]
    )

    public static let beforeHero = HeroMetrics(properNounAccuracy: 0.43, localOnlyPercent: 0.31, wer: 0.186)
    public static let afterHero = HeroMetrics(properNounAccuracy: 0.92, localOnlyPercent: 0.84, wer: 0.042)

    public static var beforeStats: LearnedStats {
        var s = LearnedStats()
        s.rulesLearned = 12; s.wordsAdded = 30; s.localOnlyPercent = 31
        return s
    }

    public static var afterStats: LearnedStats {
        var s = LearnedStats()
        s.rulesLearned = 16; s.wordsAdded = 34; s.llmCallsAvoided = 9
        s.tokensSaved = 2310; s.latencySavedMS = 7020; s.localOnlyPercent = 84
        return s
    }
}

// MARK: - Static demo model (previews / a frozen "after" screenshot)

public extension HUDModel {
    /// A model frozen on the winning state: numbers climbed, strip all green.
    static var demo: HUDModel {
        let m = HUDModel()
        m.update(stats: DemoData.afterStats, animated: false)
        m.setHero(DemoData.afterHero, animated: false)
        m.heroBaseline = DemoData.beforeHero
        m.apply(DemoData.fixedRewrite, rawText: DemoData.rawSentence)
        m.state = .result(ok: true)
        m.route = .local
        m.networkActive = false
        return m
    }
}

// MARK: - Self-running demo script

extension HUDModel {
    /// The looping narrative: baseline (cloud, wrong, billed) → one correction →
    /// re-dictation (local, perfect, free) → numbers climb → reset.
    func runDemoScript() async {
        await demoReset()
        while !Task.isCancelled {
            await demoBaselinePass()
            if Task.isCancelled { return }
            await demoLearn()
            if Task.isCancelled { return }
            await demoFixedPass()
            if Task.isCancelled { return }
            await demoSleep(3000)
            await demoReset()
        }
    }

    private func demoBaselinePass() async {
        beginListening()
        await demoFeedLevels(1700)
        beginProcessing(route: .cloud)      // network dot lights amber
        await demoSleep(950)
        finish(ok: true)
        apply(DemoData.baselineRewrite, rawText: DemoData.rawSentence)
        await demoSleep(2400)               // let the audience read "paid, still wrong"
    }

    private func demoLearn() async {
        statusText = "Learned +4 rules"
        update(stats: DemoData.afterStats)  // counters climb
        await demoSleep(1500)
    }

    private func demoFixedPass() async {
        beginListening()
        await demoFeedLevels(1400)
        beginProcessing(route: .local)      // network stays dark
        await demoSleep(550)                // local is fast
        finish(ok: true)
        apply(DemoData.fixedRewrite, rawText: DemoData.rawSentence)
        setHero(DemoData.afterHero, animated: true)  // 43→92, 18.6→4.2, 31→84
        await demoSleep(2900)               // the money shot
    }

    private func demoReset() async {
        setIdle()
        update(stats: DemoData.beforeStats, animated: false)
        setHero(DemoData.beforeHero, animated: false)
        withAnimation(.easeOut(duration: 0.3)) {
            rawText = ""
            finalText = ""
            lastRewrite = nil
            statusText = ""
        }
        networkActive = false
        route = .local
        await demoSleep(900)
    }

    private func demoFeedLevels(_ ms: Int) async {
        let steps = max(1, ms / 40)
        for i in 0..<steps {
            if Task.isCancelled { return }
            let secs = Double(i) * 0.04
            let base = abs(sin(secs * 7.0)) * 0.6 + 0.18
            let level = Float(min(1.0, base + Double.random(in: 0...0.22)))
            updateLevel(level)
            await demoSleep(40)
        }
    }

    private func demoSleep(_ ms: Int) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }
}

// MARK: - Standalone entry point

@MainActor
private enum HUDDemoRetainer {
    static var model: HUDModel?
    static var controller: NotchPanelController?
}

/// Stand up the full HUD (notch orb + projector mirror) driven entirely by mock
/// data, then run the app. Lets the signature UI be demoed without the real
/// pipeline — call this from a tiny `@main`, or paste the body into a scratch
/// executable. Blocks in `NSApplication.run()`.
@MainActor
public func runHUDDemo() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let model = HUDModel()
    let controller = NotchPanelController(model: model)
    HUDDemoRetainer.model = model
    HUDDemoRetainer.controller = controller

    controller.showAll()
    model.startDemo()
    app.run()
}

// MARK: - Previews

#Preview("Notch overlay") {
    NotchOverlayView(model: .demo)
        .frame(width: 340, height: 72, alignment: .leading)
        .padding(24)
        .background(Color.black)
}

#Preview("Live demo") {
    DemoPreviewHost()
}

private struct DemoPreviewHost: View {
    @State private var model = HUDModel()
    var body: some View {
        HUDDashboardView(model: model)
            .padding(30)
            .background(Color.black)
            .task { model.startDemo() }
            .onDisappear { model.stopDemo() }
    }
}
