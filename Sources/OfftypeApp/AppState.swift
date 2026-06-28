import AppKit
import OfftypeCore
import Hotkey
import AudioCapture
import Transcription
import Cleanup
import LearningEngine
import Injection
import HUD

/// The composition root. Owns every module and wires the live pipeline:
///
///   hold Right-Command → AudioCapture → Parakeet STT → learned rewrite
///   (rules-first, cloud-skipped) → inject into the focused app → HUD result
///
/// Everything runs on the main actor; the hotkey and audio callbacks hop here
/// from their background threads. The learning loop (capture a correction →
/// crystallize rules → re-score the held-out manifest) is wired in `Learning`
/// once that store lands; the seams are marked below.
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

    // Learned state (in-memory for the live pipeline; persistence lands with the
    // store). Empty rules == passthrough, so dictation works from first launch.
    private var rules: [Rule] = []
    private var dictionary: [DictionaryEntry] = []
    private var flags = FeatureFlags.demoDefault

    /// Guards against overlapping captures (e.g. a key-repeat or a toggle race).
    private var isCapturing = false
    /// The most recent (raw, final) pair — the seed for a one-tap correction.
    private(set) var lastTranscript: Transcript?

    public init() {
        // A real key/model unlocks live STT; `OFFTYPE_STUB_STT` swaps in a
        // deterministic stand-in so the pipeline can be smoke-tested without a
        // microphone or the CoreML model present.
        if let canned = ProcessInfo.processInfo.environment["OFFTYPE_STUB_STT"] {
            transcriber = StubTranscriber(returning: canned)
        } else {
            transcriber = ParakeetTranscriber()
        }
        cleaner = NoopCleaner()
    }

    // MARK: - Lifecycle

    public func start() {
        panel.showAll()
        hud.setIdle(animated: false)

        hotkey.onPressStart = { [weak self] in
            Task { @MainActor in self?.beginCapture() }
        }
        hotkey.onPressEnd = { [weak self] in
            Task { @MainActor in await self?.endCapture() }
        }
        hotkey.onToggle = { [weak self] in
            Task { @MainActor in self?.toggleCapture() }
        }
        audio.onLevel = { [weak self] level in
            Task { @MainActor in self?.hud.updateLevel(level) }
        }
        hotkey.start()

        let perms = HotkeyMonitor.permissionStatus()
        if !perms.allGranted {
            Log.app.notice("Permissions pending — accessibility:\(perms.accessibility, privacy: .public) inputMonitoring:\(perms.inputMonitoring, privacy: .public)")
        }
        Log.app.notice("Offtype ready — hold Right-Command to dictate")
    }

    // MARK: - Capture

    private func toggleCapture() {
        if isCapturing {
            Task { await endCapture() }
        } else {
            beginCapture()
        }
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

            // Rules first; the cloud cleaner is only consulted for uncovered,
            // low-confidence spans, and only when cloud features are enabled.
            let rewrite = await router.rewrite(
                transcript,
                rules: rules,
                dictionary: dictionary,
                cleaner: flags.llmCleanupEnabled ? cleaner : nil,
                allowCloud: flags.cloudFeaturesEnabled && flags.llmCleanupEnabled
            )

            hud.apply(rewrite, rawText: transcript.rawText)

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

    // MARK: - Learning loop (M2 seam)
    //
    // Wired once the persistence store + DiffEngine land: take the last raw
    // transcript and the user's corrected text, distill rules via DiffEngine,
    // persist them, update Telemetry, then re-score the frozen manifest through
    // Eval and push the climbing numbers via `hud.setHero(...)`.

    /// Demo / big-screen controls.
    func toggleMirror() { panel.toggleMirror() }
    func startHUDDemo() { hud.startDemo() }
    func stopHUDDemo() { hud.stopDemo() }
}
