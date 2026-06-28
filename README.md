<div align="center">

# Offtype

**A privacy-first, local-first macOS dictation app that gets *cheaper* the more you use it.**

*Every correction becomes a rule.*

</div>

---

Every cloud dictation app gets **more** expensive the more you use it — every sentence is another API call, forever, and it never learns *your* words. **Offtype inverts that curve.** It runs entirely on your Mac, and every time you correct it, that correction **crystallizes into a deterministic local rule**. The next time it hears that word, the rule fires instantly — `0 tokens · 0 ms · no cloud`. The more you talk, the less it needs the cloud or any LLM.

Built at the **AI Engineer World's Fair 2026 Hackathon** (theme: *Continual Learning*).

### It learns — measured, not asserted

After a **single** correction, re-scored on a *frozen, held-out* set of 12 jargon phrases the correction never touched (computed by the real engine — `swift test` prints these, they are not hardcoded):

| Metric | Before | After one correction |
|---|---|---|
| Proper-noun accuracy | 19.4% | **80.6%** |
| Local-Only % (no cloud) | 67.0% | **94.2%** |
| Word error rate | 49.5% | **9.7%** |
| Anti-overfit (look-alike neighbors) | — | **7/7 preserved** |

It generalizes (unseen phrases), it doesn't overfit (the country "Cuba" stays "Cuba"), and the cloud token meter stays frozen at zero. See **[DEMO.md](DEMO.md)** for the 3-minute runbook.

## What it does

- **Hold Right‑Command and talk.** Audio is captured and transcribed **on‑device** (Parakeet TDT, CoreML/ANE). Release to inject the text into whatever app has focus.
- **It learns your vocabulary.** Correct a mistake once — `Cuba → Kuba`, `off type → Offtype`, `gemma quant → GemmaQuant` — and Offtype distills it into a rule + a personal‑dictionary entry. A live **"Local‑Only %"** climbs as more of your speech is handled by free, instant, on‑device rules instead of a cloud model.
- **It proves it isn't faking.** A frozen held‑out audio set is re‑scored after a single correction (generalization to *unseen* phrases), the raw recognizer output stays visibly wrong while the learned layer fixes it, and the cloud token meter stays frozen at zero.
- **Optional — Gemini 3.5 computer‑use.** Speak a command and Gemini 3.5 Flash drives the Mac via the Interactions API; a verified action sequence then **crystallizes into a deterministic macro** that replays with **zero Gemini calls**. Same "wean off the cloud" idea, second surface.
- **Optional — screen awareness.** With your permission, Offtype reads on‑screen names (e.g. on LinkedIn) into your personal dictionary so it spells the people you see correctly.

## Privacy — what leaves your Mac

**By default, nothing.** The entire core pipeline runs on‑device:

| Stays on your Mac (always) | Leaves your Mac (only if you turn on Cloud features) |
|---|---|
| Microphone audio (in‑memory, on‑device STT, never written to disk) | Computer‑use: the instruction text, one screenshot of the relevant region, and minimal action history → Gemini |
| Transcripts, corrections, personal dictionary, rules, all learning data (`~/Library/Application Support/Offtype/`) | *(that's it)* |
| Local Gemma cleanup (your local Ollama) | Your audio, dictionary, and learning store are **never** uploaded |

A menu‑bar indicator lights up **only** during a cloud call. Cloud features are **off by default**; the Gemini key is stored in your **Keychain** (BYOK) and never touches the repo or the binary. No telemetry.

## Build from source

Requires macOS 26 (Apple Silicon), Xcode 26 toolchain, [Ollama](https://ollama.com) (optional, for local Gemma cleanup).

```bash
git clone https://github.com/jakubsejkora/offtype.git
cd offtype
swift test                      # pure-logic tests (no permissions needed)
scripts/build-app.sh debug --run   # builds & launches Offtype.app (menu bar)
```

On first run, grant **Input Monitoring** + **Accessibility** (for the hotkey and text injection), and **Microphone** (on first dictation). Screen Recording is requested only if you enable screen‑awareness or computer‑use. Models live outside the bundle at `~/Models` to keep the app lean.

> **Signing note (saves your sanity):** sign dev builds with a stable identity (`scripts/build-app.sh` uses your `Apple Development` identity). Ad‑hoc signing changes the binary's hash every build, which makes macOS reset your TCC permission grants.

## Architecture

A clean Swift Package Manager workspace. The demo‑critical brain (`OfftypeCore`, `LearningEngine`, `Persistence`, `Eval`, `Telemetry`) is **pure Swift with zero OS‑permission surface** — fully unit‑testable without launching the app.

```
OfftypeApp ── composition root (menu bar, wiring)
├─ Hotkey · AudioCapture · Injection · Transcription · Cleanup   (OS glue)
├─ LearningEngine ★  diff → rules → router → confidence gate     (pure logic)
├─ Persistence (GRDB) · Eval ★ · Telemetry                       (pure logic)
├─ HUD          Dynamic Circle, Learned panel, debug strip       (SwiftUI)
└─ ScreenContext · ComputerUse · SecureStore                     (T2, optional)
```

## Provenance

This repository is **100% new work, written during the AI Engineer World's Fair 2026 Hackathon**. "Offtype" is the project name; no prior code, repository, or product is reused. The commit history is the record. See [`AGENTS.md`](AGENTS.md).

## License

[Apache‑2.0](LICENSE) — matching the Gemma license, with an explicit patent grant.
