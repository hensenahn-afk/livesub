#!/bin/bash
# LiveSub.app 빌드:  bash build_app.sh <출력 .app 경로>
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$SRC/LiveSub.app}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
TMP="$(mktemp -d)"
BINS=()
for A in ${ARCHS:-$(uname -m)}; do
  swiftc -O -swift-version 5 "$SRC/LiveSub.swift" -o "$TMP/LiveSub-$A" -target "$A-apple-macos13.0" \
    -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework AVFoundation
  BINS+=("$TMP/LiveSub-$A")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/LiveSub"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LiveSub</string>
  <key>CFBundleDisplayName</key><string>LiveSub 실시간 자막</string>
  <key>CFBundleIdentifier</key><string>ai.rlwrld.livesub</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>LiveSub</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -f "$SRC/icon.png" ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$SRC/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$SRC/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || true
fi
codesign --force --deep --sign - "$APP"
echo "built: $APP"
