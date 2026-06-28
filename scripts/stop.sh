#!/usr/bin/env bash
# Quit Offtype. It's a menu-bar-only app (LSUIElement), so it never appears in
# Force Quit — quit it from the ◎/waveform menu-bar icon → "Quit Offtype", or run
# this. Tries a graceful quit first, then a hard kill.
set -euo pipefail

if ! pgrep -x Offtype >/dev/null; then
  echo "Offtype is not running."
  exit 0
fi

osascript -e 'tell application "Offtype" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 30); do pgrep -x Offtype >/dev/null || { echo "✓ Offtype quit."; exit 0; }; done

pkill -x Offtype 2>/dev/null || true
for _ in $(seq 1 30); do pgrep -x Offtype >/dev/null || { echo "✓ Offtype stopped."; exit 0; }; done

pkill -9 -x Offtype 2>/dev/null || true
echo "✓ Offtype force-stopped."
