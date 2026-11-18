#!/bin/bash
# Builds both apps (Release, universal) and packs them into dist/iMacDisplay.dmg.
# Used locally and by the Release workflow.
#
#   scripts/make-dmg.sh               # version from the Xcode project
#   scripts/make-dmg.sh 1.3 42        # MARKETING_VERSION 1.3, build 42
set -euo pipefail
cd "$(dirname "$0")/.."

version=${1:-}
overrides=()
[ -n "$version" ] && overrides+=("MARKETING_VERSION=$version")
[ -n "${2:-}" ] && overrides+=("CURRENT_PROJECT_VERSION=$2")

rm -rf build dist
xcodebuild -project iMacDisplay.xcodeproj \
  -target iMacDisplay -target "iMacDisplay Receiver" \
  -configuration Release \
  ${overrides[@]+"${overrides[@]}"} \
  build

# Audio output driver (AudioDriver/), shipped inside the Mac app, which installs it
# into /Library/Audio/Plug-Ins/HAL from its Settings.
driver="build/Release/iMacDisplay.app/Contents/Resources/iMacDisplay Audio.driver"
mkdir -p "$driver/Contents/MacOS"
cp AudioDriver/Info.plist "$driver/Contents/"
clang -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=14.2 -O2 -Wall \
  -framework CoreFoundation -o "$driver/Contents/MacOS/iMacDisplayAudio" AudioDriver/iMacDisplayAudio.c

# Sign with the stable certificate from scripts/make-signing-cert.sh, so macOS
# keeps the apps' permissions across versions. Without it they stay ad-hoc
# signed and every update asks for Screen Recording, Accessibility… again.
# The driver is signed first: adding it changed the app, so the app is re-signed too.
identity="iMacDisplay Signing"
if ! security find-certificate -c "$identity" >/dev/null 2>&1; then
  echo "warning: no '$identity' certificate in the keychain, apps are ad-hoc signed" >&2
  identity="-"
fi
codesign --force --sign "$identity" "$driver"
codesign --force --sign "$identity" build/Release/iMacDisplay.app "build/Release/iMacDisplay Receiver.app"

mkdir -p dist/dmg
ditto build/Release/iMacDisplay.app "dist/dmg/iMacDisplay.app"
ditto "build/Release/iMacDisplay Receiver.app" "dist/dmg/iMacDisplay Receiver.app"
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "iMacDisplay${version:+ $version}" -srcfolder dist/dmg \
  -ov -format UDZO dist/iMacDisplay.dmg
rm -rf dist/dmg

echo "Apps: build/Release/  DMG: dist/iMacDisplay.dmg"
