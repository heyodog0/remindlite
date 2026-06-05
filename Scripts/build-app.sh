#!/usr/bin/env bash
# Build RemindLite and assemble a runnable .app bundle (menu-bar agent).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="RemindLite"
BUNDLE_ID="com.heyodog0.remindlite"
VERSION="0.1.0"
APP="dist/$APP_NAME.app"

echo "▶ Building release binary…"
swift build -c release

echo "▶ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemindersFullAccessUsageDescription</key>
  <string>RemindLite shows your open reminders in the menu bar.</string>
  <key>NSRemindersUsageDescription</key>
  <string>RemindLite shows your open reminders in the menu bar.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>RemindLite shows your upcoming calendar events in the menu bar.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>RemindLite shows your upcoming calendar events in the menu bar.</string>
</dict>
</plist>
PLIST

# Sign with a STABLE self-signed identity if present, so macOS keeps the
# Reminders (TCC) grant across rebuilds. Falls back to ad-hoc elsewhere.
# (Create the identity once: Keychain Access ▸ Certificate Assistant ▸
#  Create a Certificate, type "Code Signing", named "RemindLite Self-Signed".)
SIGN_ID="RemindLite Self-Signed"
SIGN_KC="$HOME/Library/Keychains/remindlite-signing.keychain-db"
# .signing.env (gitignored) holds SIGN_KC_PASS for the dedicated signing keychain.
[ -f "$ROOT/.signing.env" ] && source "$ROOT/.signing.env"
[ -f "$SIGN_KC" ] && [ -n "${SIGN_KC_PASS:-}" ] && \
  security unlock-keychain -p "$SIGN_KC_PASS" "$SIGN_KC" 2>/dev/null || true

if [ -f "$SIGN_KC" ] && \
   codesign --force --deep --sign "$SIGN_ID" --keychain "$SIGN_KC" "$APP" 2>/dev/null; then
  echo "▶ Signed with stable identity — Reminders grant persists across rebuilds."
else
  echo "▶ Signed ad-hoc (grant won't persist across rebuilds)."
  codesign --force --sign - "$APP"
fi

echo "✓ Built $APP"
echo "  Run:  open \"$APP\""
echo "  First launch shows a Reminders permission prompt — click Allow."
