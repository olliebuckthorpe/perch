#!/bin/sh
# Installs (or updates to) the newest released Perch, and the Claude Code / Codex hooks.
# Needs the GitHub CLI signed in with access to this repo: `gh auth login`.
# Run it again any time to update.
set -e
cd "$(dirname "$0")/.."

command -v gh >/dev/null || { echo "Install the GitHub CLI first: brew install gh, then gh auth login" >&2; exit 1; }
git pull --ff-only --quiet || true

TMP="$(mktemp -d)"
gh release download --pattern Perch.zip --dir "$TMP"
ditto -x -k "$TMP/Perch.zip" "$TMP"

APP="$HOME/Applications/Perch.app"
mkdir -p "$HOME/Applications"
pkill -f "$APP/Contents/MacOS/Perch" 2>/dev/null || true
sleep 1
rm -rf "$APP"
mv "$TMP/Perch.app" "$APP"
# Downloaded apps are held back by Gatekeeper until opened by hand; this one comes from the repo.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
rm -rf "$TMP"

mkdir -p "$HOME/.perch"
install -m 755 hooks/perch-wa "$HOME/.perch/perch-wa"
python3 scripts/install-hooks.py

open "$APP"
echo "Perch $(defaults read "$APP/Contents/Info" CFBundleShortVersionString) installed."
