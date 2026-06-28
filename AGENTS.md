# AGENTS.md

Guidance for AI agents (and humans) working in this repository.

## Provenance & hackathon compliance

**This codebase is 100% new work, authored during the AI Engineer World's Fair 2026 Hackathon (Jun 27–28, 2026).** "Offtype" is only the project name. **No prior code, repository, or shipped product is reused** — the entire implementation here was written within the event window, and the git history is the verifiable record. This satisfies the hackathon's "new work only" rule.

## What Offtype is

A privacy-first, local-first macOS (Apple Silicon, macOS 26) menu-bar dictation app whose thesis is **"the more you use it, the less it needs the cloud/LLM."** Every user correction crystallizes into a deterministic local rule; a per-span router decides local-rule vs cloud; a live "Local-Only %" climbs as on-device rules replace cloud calls.

## Repository map

| Path | What |
|---|---|
| `Sources/OfftypeCore` | Shared models + protocols (the cross-module contract). |
| `Sources/LearningEngine` | ★ Pure-logic brain: diff → rule extraction, rule application, confidence gate, router. |
| `Sources/Persistence` | GRDB store (dictionary, rules, corrections, stats). |
| `Sources/Eval` | ★ Frozen held-out manifest → WER + proper-noun accuracy + Local-Only %. |
| `Sources/Telemetry` | "Learned" panel counters. |
| `Sources/Hotkey` `AudioCapture` `Injection` `Transcription` `Cleanup` | OS glue. |
| `Sources/HUD` | SwiftUI Dynamic Circle, Learned panel, debug strip. |
| `Sources/ScreenContext` `ComputerUse` `SecureStore` | T2: screen-awareness + Gemini computer-use + Keychain (optional, degrade gracefully). |
| `Sources/OfftypeApp` | Menu-bar app + composition root. |
| `scripts/build-app.sh` | Build & sign `Offtype.app` from SPM. |
| `demo/` | Frozen held-out manifest + seed data for the deterministic demo. |

## Conventions

- **Swift 6, strict concurrency.** Honor `Sendable` / `@MainActor`; no data races.
- **No force-unwraps / `try!` / `fatalError` on recoverable paths.** Typed errors (`OfftypeError`).
- **Privacy:** never log transcripts, keys, or screenshots without `privacy: .private`. No network unless `FeatureFlags.cloudFeaturesEnabled`.
- **Secrets:** never commit API keys. BYOK lives in the Keychain (`SecureStore`).
- **Pure-logic modules stay pure** (no OS imports) so they remain unit-testable.
- Run `swift test` before committing logic changes.

## Skills (for managed/computer-use agents)

- **dictation-correction** — capture a (raw → corrected) pair, distill it into alias→canonical rules + dictionary terms, apply rules-first so the cloud is skipped.
- **computer-use-macro** — run a short voice command via Gemini 3.5 computer-use, verify success, then crystallize the action sequence into a deterministic macro replayed with zero model calls.
