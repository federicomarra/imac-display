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

# Sign with the stable certificate from scripts/make-signing-cert.sh, so macOS
# keeps the apps' permissions across versions. Without it they stay ad-hoc
# signed and every update asks for Screen Recording, Accessibility… again.
identity="iMacDisplay Signing"
if security find-certificate -c "$identity" >/dev/null 2>&1; then
  codesign --force --sign "$identity" build/Release/iMacDisplay.app "build/Release/iMacDisplay Receiver.app"
else
  echo "warning: no '$identity' certificate in the keychain, apps are ad-hoc signed" >&2
fi

mkdir -p dist/dmg
ditto build/Release/iMacDisplay.app "dist/dmg/iMacDisplay.app"
ditto "build/Release/iMacDisplay Receiver.app" "dist/dmg/iMacDisplay Receiver.app"
ln -s /Applications dist/dmg/Applications
hdiutil create -volname "iMacDisplay${version:+ $version}" -srcfolder dist/dmg \
  -ov -format UDZO dist/iMacDisplay.dmg
rm -rf dist/dmg

echo "Apps: build/Release/  DMG: dist/iMacDisplay.dmg"
