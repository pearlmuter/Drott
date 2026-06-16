#!/usr/bin/env bash
#
# Make a trained checkpoint playable in the Drott app, in one step:
#   1) export it to CoreML (gated on numerical parity with PyTorch)
#   2) drop it into Sources/Drott/models/  (auto-bundled, auto-listed in the app)
#   3) rebuild the app bundle (Drott.app)
#
#   ./publish.sh                                       # newest checkpoint → next free Astrid_vN
#   ./publish.sh python/temp/checkpoint_60.pth.tar     # a specific checkpoint
#   ./publish.sh python/temp/checkpoint_60.pth.tar Astrid_strong   # + a custom name
#
# After it finishes, relaunch the app — the new model is in the Astrid dropdown.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

# 1. Pick the checkpoint (default: the newest accepted one).
CKPT_IN="${1:-$(ls -t "$ROOT"/python/temp/checkpoint_*.pth.tar 2>/dev/null | head -1 || true)}"
if [ -z "${CKPT_IN:-}" ] || [ ! -f "$CKPT_IN" ]; then
  echo "No checkpoint found. Train one first:  ./train.sh" >&2
  exit 1
fi
CKPT_ABS="$(cd "$(dirname "$CKPT_IN")" && pwd)/$(basename "$CKPT_IN")"

# 2. Pick the model name (default: next free Astrid_vN, never overwriting).
NAME="${2:-}"
if [ -z "$NAME" ]; then
  n=1; while [ -e "$ROOT/Sources/Drott/models/Astrid_v$n.mlpackage" ]; do n=$((n+1)); done
  NAME="Astrid_v$n"
fi
OUT_ABS="$ROOT/Sources/Drott/models/$NAME.mlpackage"

echo "==> Exporting $(basename "$CKPT_ABS")  →  models/$NAME.mlpackage"
mkdir -p "$ROOT/Sources/Drott/models"
( cd "$ROOT/python" && python3 export_coreml.py "$CKPT_ABS" "$OUT_ABS" )

echo "==> swift build -c release"
( cd "$ROOT" && swift build -c release )

echo "==> Rebuilding Drott.app"
APP="$ROOT/Drott.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Drott" "$APP/Contents/MacOS/Drott"
cp -R "$ROOT/.build/release/Drott_Drott.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Drott</string>
  <key>CFBundleIdentifier</key><string>com.emildanielsen.drott</string>
  <key>CFBundleName</key><string>Drott</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" 2>/dev/null || true

echo
echo "==> Done. '$(echo "$NAME" | tr _ ' ')' is bundled."
echo "    Relaunch:   pkill -x Drott; open '$APP'"
echo "    Then pick it under Black/Red Player → Astrid → model dropdown."
