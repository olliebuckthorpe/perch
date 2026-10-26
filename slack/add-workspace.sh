#!/bin/sh
# Adds (or updates) one Slack workspace for Perch. Its two keys go straight from the clipboard to
# Perch, which keeps them in the macOS Keychain: they are never typed, shown, written to a file
# or passed as a command argument. Perch must be running.
# Usage: ./slack/add-workspace.sh <name> <priority> [alerts]
#   name      a short label, e.g. upshow
#   priority  1 is most important
#   alerts    "apps" to also show alerts posted by apps (SendPilot and the like), or "people"
#             for DMs and @mentions only. Defaults to apps.
set -e
NAME="$1"; PRIORITY="$2"; ALERTS="${3:-apps}"
[ -n "$NAME" ] && [ -n "$PRIORITY" ] || { echo "usage: $0 <name> <priority> [apps|people]"; exit 1; }
SOCK="$HOME/.perch/perch.sock"
[ -S "$SOCK" ] || { echo "Perch is not running. Open Perch, then try again."; exit 1; }

echo "1. Copy the App-Level Token (starts xapp-), then press Return."
read _; APP=$(pbpaste | tr -d '[:space:]')
case "$APP" in xapp-*) ;; *) echo "That is not an xapp- token. Nothing saved."; exit 1 ;; esac

echo "2. Copy the User OAuth Token (starts xoxp-), then press Return."
read _; USER=$(pbpaste | tr -d '[:space:]')
case "$USER" in xoxp-*) ;; *) echo "That is not an xoxp- token. Nothing saved."; exit 1 ;; esac

# printf is built into the shell, so the keys never appear in the list of running commands.
OUT=$(printf '{"name":"%s","priority":%s,"alerts":"%s","app":"%s","user":"%s"}' "$NAME" "$PRIORITY" "$ALERTS" "$APP" "$USER" \
  | curl -s --unix-socket "$SOCK" -X POST -H "Content-Type: application/json" -H "X-Perch-Slack: save" --data-binary @- http://perch/slack)
APP=""; USER=""
printf '' | pbcopy
case "$OUT" in
  *'"ok":true'*) echo "Saved $NAME in the Keychain and connected. Clipboard cleared." ;;
  *) echo "Perch could not save that. Clipboard cleared."; exit 1 ;;
esac
