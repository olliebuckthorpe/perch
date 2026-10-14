#!/bin/sh
# Saves one Slack workspace's two keys for Perch, straight from the clipboard, so they are never
# typed out or shown. Usage: ./slack/add-workspace.sh <name> <priority> [alerts]
#   name      a short label, e.g. upshow
#   priority  1 is most important
#   alerts    "apps" to also show alerts posted by apps (SendPilot and the like), or "people"
#             for DMs and @mentions only. Defaults to apps.
set -e
NAME="$1"; PRIORITY="$2"; ALERTS="${3:-apps}"
[ -n "$NAME" ] && [ -n "$PRIORITY" ] || { echo "usage: $0 <name> <priority> [apps|people]"; exit 1; }
DIR="$HOME/.perch/slack"; mkdir -p "$DIR"; chmod 700 "$DIR"

echo "1. Copy the App-Level Token (starts xapp-), then press Return."
read _; APP=$(pbpaste | tr -d '[:space:]')
case "$APP" in xapp-*) ;; *) echo "That is not an xapp- token. Nothing saved."; exit 1 ;; esac

echo "2. Copy the User OAuth Token (starts xoxp-), then press Return."
read _; USER=$(pbpaste | tr -d '[:space:]')
case "$USER" in xoxp-*) ;; *) echo "That is not an xoxp- token. Nothing saved."; exit 1 ;; esac

umask 077
printf '{"name":"%s","priority":%s,"alerts":"%s","app":"%s","user":"%s"}\n' "$NAME" "$PRIORITY" "$ALERTS" "$APP" "$USER" > "$DIR/$NAME.json"
printf '' | pbcopy
echo "Saved $NAME. Clipboard cleared. Perch picks it up within a few seconds."
