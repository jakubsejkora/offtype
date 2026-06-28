# Privacy

Offtype is designed so that, **by default, nothing leaves your Mac.**

## Stays on your device (always)
- **Microphone audio** — transcribed on‑device (Parakeet TDT, CoreML/ANE), held in memory, never written to disk.
- **Transcripts, corrections, your personal dictionary, and all learned rules** — stored locally in `~/Library/Application Support/Offtype/offtype.sqlite`.
- **Local text cleanup** — runs against your own local Ollama (Gemma), on `127.0.0.1`.

## Leaves your device — only when you turn it on
Cloud features are **off by default**. If you enable **Cloud Computer‑Use**:
- What is sent to Google (Gemini): the instruction text, a screenshot of the relevant screen region, and the minimal action history for the current step.
- What is **never** sent: your audio, your personal dictionary, or your learning store.
- On‑device screen OCR (for learning names) runs locally; only the minimal context required is uploaded.

A menu‑bar indicator lights up **only** while a cloud request is in flight, so you can always see when the network is used.

## No tracking
Offtype includes **no analytics and no telemetry**. There is no account, and nothing is phoned home.

## Your control
- The Gemini API key is yours (BYOK), stored only in the macOS Keychain.
- A single switch disables all cloud features and networking.
- All learned data is a local file you can inspect, export, or delete.
