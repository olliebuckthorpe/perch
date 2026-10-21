#!/bin/sh
# Builds Perch.app and installs it to ~/Applications. Pass --run to (re)launch it.
set -e
cd "$(dirname "$0")/.."

swift build -c release -j 4

APP="$HOME/Applications/Perch.app"
# Quit the running copy. Matched by its full path: matching by name has silently missed it,
# leaving an old build running while the new one sat unused on disk.
for pid in $(ps -Ao pid=,command= | awk -v app="$APP/Contents/MacOS/Perch" '$2 == app {print $1}'); do
  kill "$pid" 2>/dev/null || true
done
for i in 1 2 3 4 5 6 7 8 9 10; do
  ps -Ao command= | grep -qx "$APP/Contents/MacOS/Perch" || break
  sleep 0.5
done
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bridge/grok-bridge.mjs "$APP/Contents/Resources/grok-bridge.mjs"
# The on-device search model (bge-small, 8-bit), compiled once and reused while unchanged.
if [ ! -d .build/bge-small.mlmodelc ] || [ models/bge-small-int8.mlpackage -nt .build/bge-small.mlmodelc ]; then
  rm -rf .build/bge-compiled && mkdir -p .build/bge-compiled
  xcrun coremlcompiler compile models/bge-small-int8.mlpackage .build/bge-compiled >/dev/null
  rm -rf .build/bge-small.mlmodelc && mv .build/bge-compiled/bge-small-int8.mlmodelc .build/bge-small.mlmodelc
fi
rm -rf "$APP/Contents/Resources/bge-small.mlmodelc"
cp -R .build/bge-small.mlmodelc "$APP/Contents/Resources/bge-small.mlmodelc"
cp models/bge-vocab.txt "$APP/Contents/Resources/bge-vocab.txt"
# The WhatsApp helper (whatsmeow), rebuilt when its source changes.
if command -v go >/dev/null; then
  if [ ! -f whatsapp/perch-whatsapp ] || [ whatsapp/main.go -nt whatsapp/perch-whatsapp ]; then
    (cd whatsapp && GOTOOLCHAIN=local go build -o perch-whatsapp .)
  fi
fi
[ -f whatsapp/perch-whatsapp ] && cp whatsapp/perch-whatsapp "$APP/Contents/Resources/perch-whatsapp"
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
  <key>NSBluetoothAlwaysUsageDescription</key><string>Perch connects your headphones to this Mac when you ask it to.</string>
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
# The WhatsApp command line (perch-wa), kept current next to the hook script.
mkdir -p "$HOME/.perch" && install -m 755 "$(dirname "$0")/../hooks/perch-wa" "$HOME/.perch/perch-wa"
echo "Built $APP"

if [ "$1" = "--run" ]; then
  # Launch Services sometimes refuses a relaunch straight after the old copy quits.
  sleep 1
  # In the background, so a relaunch never takes the keyboard from whatever is being typed in.
  open -g "$APP" 2>/dev/null || { sleep 2; open -g "$APP"; }
fi
