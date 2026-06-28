import XCTest
import AppKit
import OfftypeCore
@testable import HUD

@MainActor
final class HUDSmokeTests: XCTestCase {

    func testDrivingAPITransitions() {
        let m = HUDModel()
        XCTAssertEqual(m.state.hudPhase, .idle)

        m.beginListening()
        XCTAssertEqual(m.state.hudPhase, .listening)
        XCTAssertFalse(m.networkActive)

        m.updateLevel(0.5)
        XCTAssertEqual(m.state.hudLevel, 0.5, accuracy: 0.0001)

        m.beginProcessing(route: .cloud)
        XCTAssertEqual(m.state.hudPhase, .processing)
        XCTAssertEqual(m.route, .cloud)
        XCTAssertTrue(m.networkActive, "cloud route must light the network dot")

        m.finish(ok: true)
        XCTAssertEqual(m.state.hudPhase, .result(ok: true))
        XCTAssertFalse(m.networkActive, "result must turn the network dot off")
    }

    func testApplyDerivesRouteAndBadge() {
        let m = HUDModel()

        m.apply(DemoData.baselineRewrite, rawText: DemoData.rawSentence)
        XCTAssertEqual(m.route, .cloud)
        XCTAssertFalse(m.networkActive)
        XCTAssertEqual(m.finalText, DemoData.rawSentence, "cloud baseline stays wrong")
        XCTAssertTrue(m.statusText.contains("cloud"))

        m.apply(DemoData.fixedRewrite, rawText: DemoData.rawSentence)
        XCTAssertEqual(m.route, .local)
        XCTAssertFalse(m.networkActive)
        XCTAssertEqual(m.finalText, DemoData.fixedSentence)
        XCTAssertEqual(m.statusText, "rule applied · 0 tokens · 0 ms")
    }

    func testBadgeFormatting() {
        XCTAssertEqual(HUDModel.badge(for: DemoData.baselineRewrite), "cloud · 610 tokens · 780 ms")
        XCTAssertEqual(HUDModel.badge(for: DemoData.fixedRewrite), "rule applied · 0 tokens · 0 ms")
    }

    func testDemoDataIntegrity() {
        XCTAssertEqual(DemoData.baselineRewrite.tokensUsed, 610)
        XCTAssertEqual(DemoData.baselineRewrite.decisions.reduce(0) { $0 + $1.latencyMS }, 780)
        XCTAssertEqual(DemoData.baselineRewrite.finalText, DemoData.rawSentence)

        XCTAssertEqual(DemoData.fixedRewrite.tokensUsed, 0)
        XCTAssertEqual(DemoData.fixedRewrite.localOnlyFraction, 1.0, accuracy: 0.0001)
        XCTAssertEqual(DemoData.fixedRewrite.finalText, DemoData.fixedSentence)
        // Same misheard originals on both passes — the model never changed.
        XCTAssertEqual(DemoData.baselineRewrite.decisions.map(\.original),
                       DemoData.fixedRewrite.decisions.map(\.original))
    }

    func testSetHeroSnapshotsBaseline() {
        let m = HUDModel()
        m.setHero(DemoData.beforeHero, animated: false)
        XCTAssertNil(m.heroBaseline)

        m.setHero(DemoData.afterHero, animated: true)
        XCTAssertEqual(m.heroBaseline, DemoData.beforeHero)
        XCTAssertEqual(m.hero, DemoData.afterHero)

        m.clearHeroBaseline()
        XCTAssertNil(m.heroBaseline)
    }

    func testDemoModelIsWinningState() {
        let m = HUDModel.demo
        XCTAssertEqual(m.route, .local)
        XCTAssertFalse(m.networkActive)
        XCTAssertEqual(m.hero, DemoData.afterHero)
        XCTAssertEqual(m.heroBaseline, DemoData.beforeHero)
        XCTAssertEqual(m.stats.rulesLearned, 16)
        XCTAssertEqual(m.state.hudPhase, .result(ok: true))
    }

    func testDemoTaskLifecycle() {
        let m = HUDModel()
        XCTAssertNil(m.demoTask)
        m.startDemo()
        XCTAssertNotNil(m.demoTask)
        m.stopDemo()
        XCTAssertNil(m.demoTask)
    }

    /// Constructing the panel controller builds two NSPanels + SwiftUI hosting
    /// views — a real crash smoke test for the AppKit path.
    func testPanelControllerConstructs() {
        _ = NSApplication.shared
        let m = HUDModel.demo
        let controller = NotchPanelController(model: m)
        XCTAssertFalse(controller.isMirrorVisible)
        controller.hideAll() // must be safe before any show
    }
}
