# Perch

Your agents, in the Mac notch. Grok Bot agents sit on the left of the notch, Claude Code
and Codex sessions on the right. Hover to open the list, click a row to read the latest
message and reply. When a session needs a permission, asks a question, or finishes, the
island opens by itself with just that prompt.

A personal build inspired by Look Alive.

## Build and run

```sh
./scripts/build-app.sh --run      # builds ~/Applications/Perch.app and launches it
python3 scripts/install-hooks.py  # adds the Claude Code and Codex hooks (backs up first)
python3 scripts/install-hooks.py --uninstall
```

## How it gets its data

- **Claude Code and Codex**: hooks call `~/.perch/perch-hook`, which posts the event to the
  app over an owner-only unix socket (`~/.perch/perch.sock`). Permission, question and
  end-of-turn hooks are held open until you answer in the notch. If Perch is not running
  the hook exits silently and the agent behaves as normal.
- **Codex** is also read from its rollout files in `~/.codex/sessions`, so sessions show
  even before the hooks are trusted in Codex.
- **Grok Bot**: the `grokbot` CLI from the Claude Code plugin (event stream plus roster).
  This uses Grok Bot's private interface and can break when the app updates.

## Replying

- Grok bots: sent straight to the agent.
- Claude Code and Codex, just finished: the island holds the end of the turn open for a
  while (default one minute, see the gear menu). A reply in that window becomes the
  session's next prompt.
- Later than that: the reply resumes the session in the background with
  `claude -p --resume` or `codex exec resume`. The `claude` CLI must be logged in.

If the agent's own app is frontmost, the notch does not hold anything: you answer there.
