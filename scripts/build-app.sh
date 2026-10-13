#!/bin/sh
# Builds Perch.app and installs it to ~/Applications. Pass --run to (re)launch it.
set -e
cd "$(dirname "$0")/.."

swift build -c release -j 4

APP="$HOME/Applications/Perch.app"
pkill -x Perch 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
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
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

if [ "$1" = "--run" ]; then
  open "$APP"
fi
