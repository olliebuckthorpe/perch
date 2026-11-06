#!/bin/sh
# Builds MediaRemoteAdapter.framework into the folder given (default .build/mediaremote).
# Rebuilt only when a source file is newer than the built framework.
set -e
cd "$(dirname "$0")"
OUT="${1:-../../.build/mediaremote}"
FW="$OUT/MediaRemoteAdapter.framework"
BIN="$FW/Versions/A/MediaRemoteAdapter"
VERSION=0.7.7

if [ -f "$BIN" ] && [ -z "$(find src include -newer "$BIN" -type f | head -1)" ]; then
  exit 0
fi

rm -rf "$FW"
mkdir -p "$FW/Versions/A/Resources"
clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -O2 \
  -fobjc-arc -fvisibility=default -Iinclude -Isrc \
  src/adapter/*.m src/private/MediaRemote.m src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name @rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter \
  -o "$BIN"
cat > "$FW/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
  <key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
  <key>CFBundleName</key><string>MediaRemoteAdapter</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
</dict>
</plist>
EOF
ln -s A "$FW/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FW/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$FW/Resources"
