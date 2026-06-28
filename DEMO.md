# Offtype — 3-Minute Demo Runbook

**Pitch:** *Every dictation app gets more expensive the more you use it. Offtype gets cheaper — every correction becomes a local rule, so it needs the cloud less the more you talk.*

The hero numbers are **computed live by the real engine** on a frozen held-out set (verified in CI: `swift test` prints them). They are not hardcoded.

| | Before | After one correction |
|---|---|---|
| Proper-noun accuracy | 19.4% | **80.6%** |
| Local-Only % | 67.0% | **94.2%** |
| WER | 49.5% | **9.7%** |
| Anti-overfit (near-miss neighbors) | — | **7/7 preserved** |

---

## Pre-flight (do this before you walk up)

1. **Build & launch:** `scripts/build-app.sh debug --run` → the ◎ icon appears in the menu bar.
2. **Grant permissions once** (System Settings → Privacy & Security): **Input Monitoring**, **Accessibility**, **Microphone**. (Screen Recording only if you'll run live computer-use.) The signed `.app` keeps these across rebuilds.
3. **Turn on Do Not Disturb.** Close email/banking. Use a wired/onboard mic (not AirPods).
4. **Show the big screen:** menu → **Toggle Big-Screen Mirror** (the notch orb clips on projectors; the mirror is center-screen and legible).
5. **Pre-warm:** run **Run Learning Demo** once in the green room so models/caches are hot, then quit & relaunch for a clean baseline.
6. *(Optional, for the Gemini beat)* menu → **Computer Use → Set Gemini API Key…** (restricted key). Leave **Execute Actions for Real** OFF unless you've rehearsed the live action.
7. **Backups ready:** a screen-recording of a perfect run; this file open.

---

## The script (0:00 → 3:00)

**0:00 — Hook (say it, point at the mirror).**
> "Every dictation app gets *more* expensive the more you use it — every sentence is another API call. This one gets *cheaper*. Watch this number." *(point at Local-Only %)*

**0:18 — Live dictation (the human moment).** Hold **Right-Command** and say:
> *"Ship the Offtype eval harness to Kuba — use Parakeet and GemmaQuant, then ping Kuba about Hetzner."*

It mis-hears the jargon (off type / Cuba / Gemma Quant) — the **debug strip shows raw vs final**. That's honest: the model doesn't know your words.

**0:45 — Teach it once.** Menu → **Correct Last Dictation…**, fix the text to the real spelling, **Learn**. The Learned panel ticks up: **+4 rules, +3 terms**.

**1:05 — The money-shot (bulletproof, deterministic).** Menu → **Run Learning Demo**. The mirror animates:
- Baseline scored on 12 held-out phrases → **PN 19.4%, Local-Only 67%**.
- One correction crystallizes → **+4 rules**.
- Re-scored on the *same unseen* phrases → **PN 80.6%, Local-Only 94.2%, WER 9.7%** — numbers climb on screen.
- **Anti-overfit:** 7/7 neighbors preserved — the country "Cuba" stays "Cuba", the word "evil" stays "evil".

> "Same twelve phrases I never touched — 19 to 81% of names right, and cloud dependence dropped to 6%. One correction generalized to everything. The raw model still mis-hears; the *learned layer* fixes it locally, for free, in zero milliseconds. The cloud never woke up."

**2:15 — (Optional) Gemini 3.5 computer-use, second surface.** Menu → **Computer Use → Run Command…** ("file a task…"). Gemini acts once; then **Replay Last Macro** → badge **`macro · 0 Gemini calls`**.
> "Same idea, second surface: Gemini teaches it once, then the local macro retires it."

**2:45 — Close.**
> "Continual learning you can *feel*: cheaper, faster, and more *yours* every day — and private, because it all runs on your Mac. Offtype is the only dictation that's trying to put the cloud out of a job."

---

## Q&A defense

- **"Just a Wispr clone?"** → It inverts the cost curve. Usage drives cost and cloud-dependence *down*; that climbing Local-Only number is the whole difference. And it's local-first/private.
- **"Did you fake it?"** → Three reasons you can't: the re-scored set is *unseen* (generalization, not memorization); the raw ASR stays wrong on screen; the token meter is frozen at zero. Pick any word — I'll teach it live.
- **"Why Gemini?"** → Gemini 3.5 is the cloud *teacher* we distill into free local rules, and the computer-use engine we wean into macros. The highest-leverage use of Gemini is one that learns to need it less.

---

## Quitting Offtype

It's a **menu-bar-only app** — no Dock icon, and it **won't appear in Force Quit**. Quit it from the **waveform menu-bar icon → "Quit Offtype"**. If the icon is hidden behind the notch (crowded menu bar), run **`scripts/stop.sh`** (or `pkill -x Offtype`).

## If something flakes

- **Mic mis-hears / room noise:** the metric path (**Run Learning Demo**) uses cached audio and is deterministic — it always lands. The live dictation is just the human intro; skip it if needed.
- **Gemini beat flakes / no key:** it runs a safe mock in dry-run; or skip it (it's marked optional) and **Replay Last Macro** still tells the 0-calls story. Worst case, play the backup recording.
- **Projector clips the notch orb:** you already turned on the **Big-Screen Mirror** (center-screen).
- **A permission got reset:** menu → re-grant; the signed `.app` normally persists grants.
