#!/usr/bin/env bash
# Build Offtype.app from the SPM executable, sign it with a STABLE identity so
# macOS TCC permission grants (Accessibility / Input Monitoring / Screen
# Recording) persist across rebuilds, and (optionally) launch it.
#
#   scripts/build-app.sh [debug|release] [--run] [--hardened]
#
set -euo pipefail

CONFIG="${1:-debug}"
RUN=false
HARDENED=false
for arg in "${@:2}"; do
  case "$arg" in
    --run) RUN=true ;;
    --hardened) HARDENED=true ;;
  esac
done

APP_NAME="Offtype"
# Stable identity → stable code-signing designated requirement → TCC grants stick.
SIGN_ID="${OFFTYPE_SIGN_ID:-Apple Development: JAKUB SEJKORA (8372XQ4VUF)}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="dist/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

SIGN_ARGS=(--force --timestamp=none --entitlements Resources/Offtype.entitlements --sign "$SIGN_ID")
if [ "$HARDENED" = true ]; then SIGN_ARGS=(--options runtime "${SIGN_ARGS[@]}"); fi
echo "▶ codesign ($([ "$HARDENED" = true ] && echo hardened || echo dev))"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --verbose=2 "$APP" || true

echo "✓ Built $APP"
if [ "$RUN" = true ]; then
  echo "▶ launching"
  open "$APP"
fi
