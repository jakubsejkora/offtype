# Security Policy

## Reporting a vulnerability

Please report security issues privately via [GitHub Security Advisories](https://github.com/jakubsejkora/offtype/security/advisories/new) rather than a public issue. We aim to acknowledge within a few days.

## Threat model & posture

Offtype is **local-first**. The core dictation pipeline performs **no network I/O**; all learning data stays in `~/Library/Application Support/Offtype/`.

- **Secrets / BYOK.** The optional Gemini API key is supplied by the user and stored only in the macOS **Keychain** (`SecureStore`). It is never written to the repository, the app bundle, or any config file. CI scans every commit (`gitleaks`) and verifies the built binary contains no `AIza…` key. Per Google's 2026-06-19 requirement, keys must be **restricted** to the Generative Language API.
- **No telemetry.** Nothing is phoned home. The only optional outbound traffic is the cloud computer‑use path, which the user explicitly enables, and which is indicated by a menu‑bar network light.
- **Cloud computer‑use safety.** Gemini's `safety_decision == require_confirmation` is always honored with a human‑in‑the‑loop confirmation. A denylist blocks sensitive apps (System Settings, Keychain Access, Terminal, password managers) and gates sensitive actions ("send", "pay", "delete", …). A global kill‑switch cancels the loop and releases held modifiers. Prompt‑injection detection is enabled, and OCR'd on‑screen text is treated as data, never as instructions.
- **Text injection.** Before any synthetic keystroke, Offtype checks `IsSecureEventInputEnabled()` and refuses to inject into secure fields (e.g. password fields). The pasteboard is saved and restored around injection (no clipboard theft).
- **Permissions** are least‑privilege and requested just‑in‑time: Microphone, Input Monitoring, Accessibility, and — only for optional screen features — Screen Recording.
- **Distribution integrity.** Release builds are Developer‑ID signed with the hardened runtime and notarized; nested binaries are signed inside‑out.

## Supported versions

The latest release on the default branch is supported during the hackathon period.
