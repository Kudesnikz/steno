#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-Steno}"
APP_VERSION="${APP_VERSION:-2.2.0}"
DMG_NAME="${DMG_NAME:-${APP_NAME}-${APP_VERSION}-universal.dmg}"
VOL_NAME="${VOL_NAME:-${APP_NAME}}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$DMG_NAME"
STAGING_DIR="$DIST_DIR/dmg-staging"

cd "$ROOT_DIR"

./script/build_and_run.sh build >/dev/null

if [ ! -d "$APP_BUNDLE" ]; then
  echo "error: app bundle not found: $APP_BUNDLE" >&2
  exit 1
fi

rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

cat >"$STAGING_DIR/README.txt" <<EOF
Steno native macOS app

Install:
1. Drag Steno.app to Applications.
2. On first launch, grant Screen Recording and Microphone permissions.

Logs:
- File log: ~/.steno/steno.log
- Unified log: log stream --info --style compact --predicate 'subsystem == "com.sergeygalay.steno"'
EOF

hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

hdiutil verify "$DMG_PATH" >/dev/null
rm -rf "$STAGING_DIR"

echo "$DMG_PATH"
