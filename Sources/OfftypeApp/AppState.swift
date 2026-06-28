import AppKit
import OfftypeCore
import Hotkey
import AudioCapture
import Transcription
import Cleanup
import LearningEngine
import Persistence
import Eval
import Telemetry
import Injection
import HUD
import ComputerUse
import ScreenContext
import SecureStore

/// The composition root. Owns every module and wires the live pipeline:
///
///   hold Right-Command → AudioCapture → Parakeet STT → learned rewrite
///   (rules-first, cloud-skipped) → inject into the focused app → HUD result
///
/// …and the continual-learning loop that is the whole point:
///
///   user corrects the last dictation → DiffEngine distills rules → persist →
///   the rules apply next time with 0 tokens, and the Local-Only % climbs.
///
/// Everything runs on the main actor; hotkey/audio callbacks hop here from their
/// background threads.
@MainActor
public final class AppState {
    // UI
    let hud = HUDModel()
    private(set) lazy var panel = NotchPanelController(model: hud)

    // OS glue
    private let hotkey = HotkeyMonitor()
    private let audio = AudioCapturer()
    private let injector = TextInjector()

    // Brain
    private let transcriber: any Transcriber
    private let router = Router()
    private let cleaner: any Cleaner
    private let diff = DiffEngine()
    private let evaluator = Evaluator()

    // On-device learning store (nil only if SQLite can't open — the app still
    // runs, just without persistence across launches).
    private let store: Store?
    let telemetry: Telemetry

    // Computer-use (M3): key in Keychain; deterministic macro replay is the payoff.
    let keychain = KeychainStore()
    let crystallizer = MacroCrystallizer()
    var lastMacro: ComputerUseMacro?
    var pendingCUConfirmation: PendingComputerUseConfirmation?
    /// When false (default), computer-use runs DRY: it plans + crystallizes macros
    /// without moving your mouse/keyboard. Flip on for a rehearsed live run.
    var computerUseExecuteForReal = false
    /// Held across an async run so a safety confirmation can resume the same loop.
    var cuAgent: ComputerUseAgent?

    // Learned state held in memory for the live pipeline; loaded from `store` at
    // launch. Empty rules == passthrough, so dictation works from first run.
    private var rules: [Rule] = []
    private var dictionary: [DictionaryEntry] = []
    var flags = FeatureFlags.demoDefault

    private var isCapturing = false
    /// The last (raw, final) pair — seeds the one-tap correction.
    private(set) var lastTranscript: Transcript?
    private(set) var lastFinalText: String = ""
    var demoTask: Task<Void, Never>?

    public init() {
        if let canned = ProcessInfo.processInfo.environment["OFFTYPE_STUB_STT"] {
            transcriber = StubTranscriber(returning: canned)
        } else {
            transcriber = ParakeetTranscriber()
        }
        cleaner = NoopCleaner()

        let openedStore = try? Store()
        store = openedStore
        let savedStats = (try? openedStore?.stats.load()) ?? nil
        telemetry = Telemetry(stats: savedStats ?? LearnedStats())
        if openedStore == nil {
            Log.app.error("Persistence unavailable — learning won't survive relaunch this session")
        }
    }

    // MARK: - Lifecycle

    public func start() {
        loadPersistedLearning()

        panel.showAll()
        hud.setIdle(animated: false)
        hud.update(stats: telemetry.stats, animated: false)

        hotkey.onPressStart = { [weak self] in Task { @MainActor in self?.beginCapture() } }
        hotkey.onPressEnd = { [weak self] in Task { @MainActor in await self?.endCapture() } }
        hotkey.onToggle = { [weak self] in Task { @MainActor in self?.toggleCapture() } }
        audio.onLevel = { [weak self] level in Task { @MainActor in self?.hud.updateLevel(level) } }
        hotkey.start()

        let perms = HotkeyMonitor.permissionStatus()
        if !perms.allGranted {
            Log.app.notice("Permissions pending — accessibility:\(perms.accessibility, privacy: .public) inputMonitoring:\(perms.inputMonitoring, privacy: .public)")
        }
        Log.app.notice("Offtype ready — hold Right-Command to dictate (\(self.rules.count, privacy: .public) rules loaded)")
    }

    private func loadPersistedLearning() {
        guard let store else { return }
        rules = (try? store.rules.enabled()) ?? []
        dictionary = (try? store.dictionary.all()) ?? []
    }

    // MARK: - Capture (M1)

    private func toggleCapture() {
        if isCapturing { Task { await endCapture() } } else { beginCapture() }
    }

    private func beginCapture() {
        guard !isCapturing else { return }
        do {
            try audio.start()
            isCapturing = true
            hud.beginListening()
        } catch {
            Log.app.error("Capture start failed: \(error.localizedDescription, privacy: .public)")
            hud.statusText = (error as? OfftypeError) == .permissionDenied("microphone")
                ? "Microphone permission needed" : "Couldn't start the mic"
            hud.finish(ok: false)
        }
    }

    private func endCapture() async {
        guard isCapturing else { return }
        isCapturing = false
        let samples = audio.stop()
        guard samples.duration > 0.15 else { hud.setIdle(); return }

        hud.beginProcessing(route: .local)
        do {
            let transcript = try await transcriber.transcribe(samples)
            lastTranscript = transcript

            let rewrite = await router.rewrite(
                transcript,
                rules: rules,
                dictionary: dictionary,
                cleaner: flags.llmCleanupEnabled ? cleaner : nil,
                allowCloud: flags.cloudFeaturesEnabled && flags.llmCleanupEnabled
            )
            lastFinalText = rewrite.finalText
            hud.apply(rewrite, rawText: transcript.rawText)

            telemetry.record(rewrite)
            persistStats()
            hud.update(stats: telemetry.stats)

            let injected = (try? injector.inject(rewrite.finalText)) ?? false
            if !injected {
                Log.app.notice("Injection unavailable (secure field or permission) — text shown in HUD only")
            }
            hud.finish(ok: true)
        } catch {
            Log.app.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            hud.statusText = "Transcription unavailable"
            hud.finish(ok: false)
        }
    }

    // MARK: - Continual learning (M2)

    /// Distill the user's correction of the last dictation into durable rules.
    /// This is the heart of the product: one correction, learned forever.
    func learn(correctedText: String) {
        let raw = lastTranscript?.rawText ?? lastFinalText
        let corrected = correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !corrected.isEmpty, corrected != raw else { return }

        let correction = Correction(rawText: raw, correctedText: corrected, appBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let outcome = diff.learn(from: correction)
        guard !outcome.rules.isEmpty || !outcome.terms.isEmpty else {
            hud.statusText = "No new rules from that correction"
            return
        }

        if let store {
            try? store.rules.saveAll(outcome.rules)
            try? store.dictionary.saveAll(outcome.terms)
            try? store.corrections.save(correction)
            rules = (try? store.rules.enabled()) ?? (rules + outcome.rules)
            dictionary = (try? store.dictionary.all()) ?? (dictionary + outcome.terms)
        } else {
            rules += outcome.rules
            dictionary += outcome.terms
        }

        telemetry.recordLearning(rulesLearned: outcome.rules.count, wordsAdded: outcome.terms.count)
        persistStats()
        hud.update(stats: telemetry.stats)
        hud.statusText = "Learned \(outcome.rules.count) rule\(outcome.rules.count == 1 ? "" : "s") · applies next time with 0 tokens"
        Log.learning.notice("Crystallized \(outcome.rules.count, privacy: .public) rules, \(outcome.terms.count, privacy: .public) terms")
    }

    func persistStats() {
        guard let store else { return }
        try? store.stats.save(telemetry.stats)
    }

    // MARK: - The money-shot: a REAL learning demo on the frozen manifest

    /// Runs the actual engine (not a mock) over the committed held-out manifest:
    /// score the baseline → learn the seed correction → re-score → the hero
    /// numbers climb, then the anti-overfit challenge proves no neighbors broke.
    func runLearningDemo() {
        demoTask?.cancel()
        demoTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard
                let manifest = try? DemoData.manifest(),
                let nearMiss = try? DemoData.nearMiss(),
                let learned = try? DemoData.learnedFromSeed()
            else {
                self.hud.statusText = "Demo data not found"
                return
            }

            self.panel.showAll()
            let before = self.evaluator.run(manifest: manifest, rules: [])
            self.hud.setIdle(animated: false)
            self.hud.setHero(Self.hero(before), animated: false)
            self.hud.statusText = "Baseline · \(Self.pct(before.properNounAccuracy)) of names right"
            if (try? await Task.sleep(for: .seconds(2.2))) == nil { return }

            self.hud.beginProcessing(route: .local)
            self.hud.statusText = "One correction → \(learned.rules.count) rules, \(learned.terms.count) terms"
            self.telemetry.recordLearning(rulesLearned: learned.rules.count, wordsAdded: learned.terms.count)
            self.hud.update(stats: self.telemetry.stats)
            if (try? await Task.sleep(for: .seconds(1.6))) == nil { return }

            let after = self.evaluator.run(manifest: manifest, rules: learned.rules, dictionary: learned.terms)
            self.hud.setHero(Self.hero(after), animated: true)
            self.hud.finish(ok: true)
            if (try? await Task.sleep(for: .seconds(1.8))) == nil { return }

            let anti = self.evaluator.runAntiOverfit(nearMiss: nearMiss, rules: learned.rules, dictionary: learned.terms)
            self.hud.statusText = "Anti-overfit · \(anti.preserved)/\(anti.total) neighbors preserved · \(anti.regressions.count) regressions"
            Log.app.notice("Demo: PN \(Self.pct(before.properNounAccuracy), privacy: .public)→\(Self.pct(after.properNounAccuracy), privacy: .public), Local-Only \(Self.pct(before.localOnlyPercent), privacy: .public)→\(Self.pct(after.localOnlyPercent), privacy: .public)")
        }
    }

    private static func hero(_ r: EvalResult) -> HeroMetrics {
        HeroMetrics(properNounAccuracy: r.properNounAccuracy, localOnlyPercent: r.localOnlyPercent, wer: r.wer)
    }

    private static func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    // MARK: - Menu helpers

    func toggleMirror() { panel.toggleMirror() }
    func startHUDDemo() { hud.startDemo() }
    func stopHUDDemo() { hud.stopDemo(); demoTask?.cancel() }
}
