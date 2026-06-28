import AppKit
import OfftypeCore
import ComputerUse
import ScreenContext
import SecureStore

// M3 — the Gemini 3.5 computer-use beat, same thesis on a second surface:
// a voice command runs through Gemini 3.5 (Interactions API) once; the verified
// action sequence crystallizes into a deterministic MACRO that replays with ZERO
// Gemini calls. The cloud teaches once; the local macro retires it.
//
// Safety: runs DRY by default (plans + crystallizes without touching the
// mouse/keyboard); flip `computerUseExecuteForReal` for a rehearsed live run.
// Model `require_confirmation` and the app denylist are honored; cancel() is a
// hard kill-switch.

/// No-op executor: logs the planned action without moving the mouse/keyboard.
final class DryRunExecutor: ComputerUseActionExecuting, @unchecked Sendable {
    func execute(_ action: ComputerUseAction, display: ScreenDisplayCapture?) async throws {
        let intent = action.intent.map { " — \($0)" } ?? ""
        Log.screen.notice("[dry-run] \(action.actionLabel, privacy: .public)\(intent, privacy: .public)")
    }
    func releaseModifiersAndButtons() {}
}

@MainActor
extension AppState {
    public var hasGeminiKey: Bool {
        (keychain.get(account: KeychainStore.geminiAPIKeyAccount)?.isEmpty == false)
    }

    /// Store the user's restricted Gemini key in the Keychain (BYOK) and enable
    /// the cloud computer-use path.
    func setGeminiAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.set(trimmed, account: KeychainStore.geminiAPIKeyAccount)
            flags.cloudFeaturesEnabled = true
            flags.computerUseEnabled = true
            hud.statusText = "Gemini key saved · computer-use enabled"
        } catch {
            hud.statusText = "Couldn't save key to Keychain"
        }
    }

    func setComputerUseExecuteForReal(_ on: Bool) {
        computerUseExecuteForReal = on
        hud.statusText = on ? "Computer-use will EXECUTE actions" : "Computer-use is dry-run (safe)"
    }

    /// Run a natural-language command. Uses Gemini when a key is present + cloud is
    /// enabled, otherwise a safe scripted mock so the loop + macro story still demos.
    func runComputerUseCommand(_ instruction: String) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let usingCloud = hasGeminiKey && flags.cloudFeaturesEnabled && flags.computerUseEnabled
        let provider: any ComputerUseProvider
        if usingCloud, let gemini = try? GeminiInteractionsClient(featureFlags: flags, keychain: keychain) {
            provider = gemini
        } else {
            provider = MockComputerUseProvider(scriptedActions: Self.safeDemoScript)
        }
        let executor: any ComputerUseActionExecuting =
            computerUseExecuteForReal ? CGEventActionExecutor() : DryRunExecutor()
        let agent = ComputerUseAgent(loop: AgentLoop(provider: provider, executor: executor))
        cuAgent = agent

        hud.beginProcessing(route: usingCloud ? .cloud : .local)
        hud.statusText = usingCloud ? "Gemini 3.5 computer-use…" : "Computer-use (mock · dry-run)…"

        Task { @MainActor in
            let state = await agent.run(trimmed)
            self.handle(state, instruction: trimmed)
        }
    }

    /// Resume a run the model asked us to confirm (sensitive action).
    func acknowledgeComputerUseConfirmation() {
        guard let agent = cuAgent, pendingCUConfirmation != nil else { return }
        pendingCUConfirmation = nil
        hud.statusText = "Confirmed — continuing…"
        Task { @MainActor in
            let state = await agent.acknowledgeSafety()
            self.handle(state, instruction: "")
        }
    }

    /// Hard kill-switch — cancels the loop and releases any held keys/buttons.
    func cancelComputerUse() {
        let agent = cuAgent
        Task { await agent?.cancel() }
        hud.networkActive = false
        hud.finish(ok: false)
        hud.statusText = "Computer-use stopped"
    }

    /// The on-theme payoff: replay the last crystallized macro deterministically —
    /// zero Gemini calls — and count the avoided call.
    func replayLastMacro() {
        guard let macro = lastMacro else {
            hud.statusText = "No macro yet — run a command first"
            return
        }
        let executor: any ComputerUseActionExecuting =
            computerUseExecuteForReal ? CGEventActionExecutor() : DryRunExecutor()
        hud.beginProcessing(route: .local) // local: the cloud never wakes up
        Task { @MainActor in
            do {
                let actions = try await crystallizer.replay(macro, values: [:], executor: executor)
                telemetry.recordMacroReplay(geminiCallsAvoided: 1)
                persistStats()
                hud.update(stats: telemetry.stats)
                hud.finish(ok: true)
                hud.statusText = "Macro replayed · \(actions.count) actions · 0 Gemini calls"
            } catch {
                hud.finish(ok: false)
                hud.statusText = "Macro replay failed"
            }
        }
    }

    private func handle(_ state: ComputerUseRunState, instruction: String) {
        switch state {
        case .completed(let actions):
            if !actions.isEmpty {
                lastMacro = crystallizer.recordVerifiedSequence(
                    name: "voice-macro",
                    slotTemplate: instruction.isEmpty ? "command" : instruction,
                    slots: [],
                    actions: actions
                )
            }
            hud.networkActive = false
            hud.finish(ok: true)
            hud.statusText = "Done · \(actions.count) action\(actions.count == 1 ? "" : "s") · macro saved (replay = 0 Gemini calls)"
        case .pendingConfirmation(let pending):
            pendingCUConfirmation = pending
            hud.statusText = "Confirmation required: \(pending.reason)"
        case .blocked(let reason):
            hud.networkActive = false; hud.finish(ok: false); hud.statusText = "Blocked: \(reason)"
        case .cancelled:
            hud.networkActive = false; hud.finish(ok: false); hud.statusText = "Cancelled"
        case .unavailable(let why), .failed(let why):
            hud.networkActive = false; hud.finish(ok: false); hud.statusText = "Computer-use unavailable: \(why)"
        }
    }

    /// A harmless scripted plan used when no key is set — types a short note, so the
    /// loop + macro-crystallization story still lands. Dry-run by default.
    static var safeDemoScript: [ComputerUseAction] {
        [ComputerUseAction(kind: .type, text: "filed by Offtype", intent: "type a short note into the focused field")]
    }
}
