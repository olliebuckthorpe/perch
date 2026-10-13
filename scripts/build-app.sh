#!/bin/sh
# Builds Perch.app and installs it to ~/Applications. Pass --run to (re)launch it.
set -e
cd "$(dirname "$0")/.."

swift build -c release -j 4

APP="$HOME/Applications/Perch.app"
pkill -x Perch 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bridge/grok-bridge.mjs "$APP/Contents/Resources/grok-bridge.mjs"
cp .build/release/Perch "$APP/Contents/MacOS/Perch"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Perch</string>
  <key>CFBundleDisplayName</key><string>Perch</string>
  <key>CFBundleIdentifier</key><string>app.perch.notch</string>
  <key>CFBundleExecutable</key><string>Perch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>Web link</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
    </dict>
  </array>
  <key>NSMicrophoneUsageDescription</key><string>Perch listens while you dictate a reply to an agent.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Perch turns what you say into the text of your reply.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
# Sign with the permanent local certificate when it exists, so macOS sees every build as the
# same app and permissions (Accessibility, microphone) survive a rebuild. Ad-hoc otherwise.
if security find-certificate -c "Perch Signing" >/dev/null 2>&1 && codesign --force --sign "Perch Signing" "$APP" >/dev/null 2>&1; then
  echo "Signed with Perch Signing"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
  echo "Signed ad hoc"
fi
echo "Built $APP"

if [ "$1" = "--run" ]; then
  # Launch Services sometimes refuses a relaunch straight after the old copy quits.
  sleep 1
  open "$APP" 2>/dev/null || { sleep 2; open "$APP"; }
fi
