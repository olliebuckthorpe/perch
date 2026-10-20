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
- Codex: `codex queue --thread <id> --message <text>` submits through the shared daemon,
  including when the desktop app owns the chat or a turn is already running. A successful
  command acknowledges queuing; the rollout watcher supplies the actual response. Failed
  deliveries show Try again and survive restarting Perch.
- Claude Code, just finished: the island holds the end of the turn open for a
  while (default one minute, see the gear menu). A reply in that window becomes the
  session's next prompt.
- Later than that: the reply resumes the session in the background with
  `claude -p --resume`. The `claude` CLI must be logged in.

If the agent's own app is frontmost, the notch does not hold anything: you answer there.

## Reply and WhatsApp updates (19 October 2026)

Codex replies prefer the CLI bundled with ChatGPT/Codex so its session and model support
match the desktop app. Standalone CLI lookup remains a fallback. Failed background runs
show their actual diagnostic. Codex replies use the shared queue rather than creating a
second session writer. Known older rollout files are also watched when their chats resume.

WhatsApp voice messages play inline. Click the microphone to record, stop to attach the
recording, then press Send. Cancel discards an unfinished recording. Opus decoding and
recording conversion use the locally installed `ffmpeg`; other supported audio formats use
AVFoundation directly. Perch suppresses its WhatsApp banners while the WhatsApp desktop app
is frontmost. Chat image previews now use larger widths and preserve their aspect ratio.

The direct Upshow calendar integration has been investigated; see
[the integration notes](docs/upshow-calendar.md) for existing endpoints and the remaining
sign-in, agenda and scheduling work.

## WhatsApp notification previews

Notifications carry the attachment type, a thumbnail when WhatsApp supplies one, and up to
six lines of caption or message text. Compact banners show three lines. WhatsApp sidebar
rows follow the native list layout: circular avatar, name and timestamp, one line of caption
with an inline camera icon, and a green unread badge. Hovering a full notification expands
its text; opening the chat still loads the full image.

Reactions update the sidebar with the emoji and original message. Own reactions sync quietly;
new reactions from other people to the user's messages may notify. Duplicate reaction events
are ignored. Notifications from a different direct chat remain visible while another chat is open.

`cd whatsapp && go test ./...` checks photo captions/thumbnails, reaction context and duplicate
reaction handling with an isolated temporary database. `notificationview:<PNG path>` on the
local debug socket renders photo and reaction preview fixtures without contacting WhatsApp.

## Draft photo attachments

Reply attachments are saved immediately to `~/.perch/draft-attachments.json`, keyed by chat.
The saved record retains each file's path, name and identity, so reopening Perch restores the
same photos in the same order. Removing or sending them updates that record. Files are kept
on disk, and chats with unsent drafts are retained across restarts and ordinary pruning.

Run the draft storage regression check on macOS:

```sh
swiftc Sources/Perch/Shell.swift Sources/Perch/Attachments.swift tests/draft-attachments/main.swift -o /tmp/perch-draft-check
/tmp/perch-draft-check
```

## Codex questions and stable sidebar

Codex's `request_user_input_async` cards are read incrementally from its rollout records.
Perch shows the question, choices, and a typed-answer field. Answers are sent through the
running Codex app's queue with the original tool-call and question identifiers. A failed
send leaves the question and selections available to retry. Answering in Codex also clears
the Perch card. This relay is for choice/text questions, not command or permission approvals.

While the sidebar is open, background status changes keep existing rows in place. New
conversations append; explicit drag, pin and remove actions still apply. Remmi stays above
the independently scrolling chat list, and hover buttons keep fixed space in their rows.

Standalone regression checks on macOS:

```sh
swiftc Sources/Perch/CodexQuestions.swift tests/codex-questions/main.swift -o /tmp/perch-question-check
/tmp/perch-question-check
swiftc Sources/Perch/SidebarOrder.swift tests/sidebar-order/main.swift -o /tmp/perch-sidebar-check
/tmp/perch-sidebar-check
```
