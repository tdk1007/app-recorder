#!/bin/zsh
# Builds "App Recorder.app" into ./build and installs it to /Applications.
set -euo pipefail
cd "${0:A:h}"
APP="build/App Recorder.app"
SDK=$(xcrun --sdk macosx --show-sdk-path)
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos14.4 -sdk "$SDK" \
  Sources/*.swift -o "$APP/Contents/MacOS/AppRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset; mkdir -p $ICONSET
  swift make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $ICONSET -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity keeps the macOS recording permission from resetting on every rebuild.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"

if [[ "${1:-}" != "--no-install" ]]; then
  osascript -e 'quit app "App Recorder"' 2>/dev/null || true
  rm -rf "/Applications/App Recorder.app"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/App Recorder.app"
fi
