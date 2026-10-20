#!/bin/bash
# Builds "build/Screenplay Writer.app". Usage: ./build.sh [--install]  (--install copies it to /Applications)
set -euo pipefail
cd "$(dirname "$0")"

MIN_MACOS=14.0   # keep in sync with platforms: in Package.swift
SDK=$(xcrun --show-sdk-version)

# SwiftPM records the deployment target as the SDK version, which would give the app the old look:
# pass the real SDK to the linker so macOS 26+ draws Liquid Glass.
swift build -c release -Xlinker -platform_version -Xlinker macos -Xlinker "$MIN_MACOS" -Xlinker "$SDK"
BIN="$(swift build -c release --show-bin-path)/ScreenplayWriter"

APP="build/Screenplay Writer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenplayWriter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_MACOS" "$APP/Contents/Info.plist"
for lproj in Resources/*.lproj; do cp -R "$lproj" "$APP/Contents/Resources/"; done
# AppIcon.icon is an Icon Composer document: actool compiles it into Assets.car (Liquid Glass
# on macOS 26+) plus an AppIcon.icns for older systems.
xcrun actool AppIcon.icon --compile "$APP/Contents/Resources" --app-icon AppIcon \
  --include-all-app-icons --platform macosx --target-device mac \
  --minimum-deployment-target "$MIN_MACOS" --output-partial-info-plist "$(mktemp -t screenplay-icon)" \
  --output-format human-readable-text >/dev/null
touch "$APP"   # make the Finder and the Dock notice the new icon
codesign --force --sign - "$APP"

echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Screenplay Writer.app"
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Screenplay Writer.app"
fi
