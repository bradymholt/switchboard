#!/usr/bin/env bash
# Builds Switchboard.app into ./build. Pass --install to copy it to /Applications, --run to launch it.
# Set VERSION and BUILD_NUMBER to stamp the app's Info.plist (used by the release workflow).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
bin="$(swift build -c release --show-bin-path)"
app="build/Switchboard.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Switchboard" "$app/Contents/MacOS/Switchboard"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$app/Contents/Info.plist"
fi
codesign --force --sign - "$app"
echo "Built $app"

for arg in "$@"; do
  case "$arg" in
    --install)
      pkill -x Switchboard || true
      rm -rf /Applications/Switchboard.app
      cp -R "$app" /Applications/
      app="/Applications/Switchboard.app"
      echo "Installed $app"
      ;;
    --run)
      pkill -x Switchboard && sleep 1.5 || true
      open "$app"
      ;;
  esac
done
