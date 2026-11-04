#!/bin/sh
# Builds Upshow's web app (by default the calendar-event-details worktree) into ~/.perch/upshow-web,
# where Perch's Calendar tab runs it. Nothing in the worktree changes. The Supabase settings are the
# public ones the live site ships; pass the worktree's frontend folder to build another one.
set -e
FRONTEND="${1:-$HOME/Dev/worktrees/calendar-event-details/frontend}"
MAIN=$(curl -s https://upshow.co.uk/app | grep -o '/assets/index-[^"]*\.js' | head -1)
KEY=$(curl -s "https://upshow.co.uk$MAIN" | grep -o 'eyJhbGci[A-Za-z0-9._-]*' | head -1)
[ -n "$KEY" ] || { echo "Could not read Upshow's public settings"; exit 1; }
cd "$FRONTEND"
VITE_SUPABASE_URL=https://iarvnasdtzwcryiuotqi.supabase.co VITE_SUPABASE_ANON_KEY="$KEY" \
  taskpolicy -c background npx vite build --outDir "$HOME/.perch/upshow-web" --emptyOutDir
