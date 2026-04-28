#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Steno"
BUNDLE_ID="com.sergeygalay.steno"
MIN_SYSTEM_VERSION="15.0"
APP_VERSION="0.2.0"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

cd "$ROOT_DIR"

CODESIGN_BIN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime)
CODESIGN_APP_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ROOT_DIR/entitlements.plist")
if [ "$SIGN_IDENTITY" = "-" ]; then
  # TCC stores Screen Recording grants against the app's designated requirement.
  # The default ad-hoc requirement is cdhash-based, so it changes on every build.
  CODESIGN_APP_ARGS+=(--requirements "=designated => identifier \"$BUNDLE_ID\"")
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
if ! swift build "${BUILD_ARGS[@]}"; then
  echo "warning: Universal build failed; falling back to current architecture only." >&2
  BUILD_ARGS=(-c release)
  swift build "${BUILD_ARGS[@]}"
fi
BUILD_BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES/assets" "$APP_RESOURCES/bin"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

find "$BUILD_BIN_DIR" -maxdepth 1 -name '*.bundle' -type d -exec cp -R {} "$APP_RESOURCES/" \;

cp -R assets/. "$APP_RESOURCES/assets/"
if [ -d bin ]; then
  cp -R bin/. "$APP_RESOURCES/bin/"
  find "$APP_RESOURCES/bin" -type f -exec chmod +x {} \;
fi

if [ -f assets/app_icon.icns ]; then
  cp assets/app_icon.icns "$APP_RESOURCES/app_icon.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleIconFile</key>
  <string>app_icon</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Steno records microphone audio while recording meetings.</string>
  <key>NSScreenCaptureUsageDescription</key>
  <string>Steno records the screen to save meeting videos.</string>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
</dict>
</plist>
PLIST

while IFS= read -r binary; do
  /usr/bin/codesign "${CODESIGN_BIN_ARGS[@]}" "$binary" >/dev/null
done < <(find "$APP_RESOURCES/bin" -type f -perm -111 -print0 2>/dev/null | xargs -0 file 2>/dev/null | awk -F: '/Mach-O/ {print $1}')

/usr/bin/codesign "${CODESIGN_APP_ARGS[@]}" "$APP_BUNDLE" >/dev/null
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  build|--build)
    echo "$APP_BUNDLE"
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [build|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
