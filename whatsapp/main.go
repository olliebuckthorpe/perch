// perch-whatsapp links Perch to the user's WhatsApp as a linked device (like WhatsApp Web),
// using whatsmeow. It talks to Perch over stdin and stdout, one JSON object per line:
// commands come in as {"id": 1, "cmd": "...", ...}, replies go out as {"id": 1, "ok": true,
// "data": ...}, and events (a QR code to scan, a new message) go out as {"event": "..."}.
//
// Everything stays on the Mac, in ~/.perch/whatsapp: the session, a record of chats and
// messages, and any media the user asks to download. Nothing is sent anywhere but WhatsApp.
package main

import (
	"bufio"
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"go.mau.fi/whatsmeow/appstate"
	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	_ "modernc.org/sqlite"
)

var (
	dir    string
	client *whatsmeow.Client
	db     *sql.DB
	outMu  sync.Mutex
	ctx    = context.Background()
)

func out(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	outMu.Lock()
	os.Stdout.Write(append(b, '\n'))
	outMu.Unlock()
}

func emit(event string, fields map[string]any) {
	if fields == nil {
		fields = map[string]any{}
	}
	fields["event"] = event
	out(fields)
}

func main() {
	home, _ := os.UserHomeDir()
	dir = filepath.Join(home, ".perch", "whatsapp")
	os.MkdirAll(filepath.Join(dir, "media"), 0o700)
	os.Chmod(dir, 0o700)

	var err error
	db, err = sql.Open("sqlite", "file:"+filepath.Join(dir, "messages.db")+"?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		fail(err)
	}
	db.SetMaxOpenConns(4)
	setup()
	os.Chmod(filepath.Join(dir, "messages.db"), 0o600)

	// More than one connection: whatsmeow reads its keys while in the middle of saving them, and
	// a single connection made decrypting and sending wait on themselves forever.
	sessionDB, err := sql.Open("sqlite", "file:"+filepath.Join(dir, "session.db")+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(10000)&_pragma=journal_mode(WAL)")
	if err != nil {
		fail(err)
	}
	sessionDB.SetMaxOpenConns(4)
	container := sqlstore.NewWithDB(sessionDB, "sqlite3", waLog.Noop)
	if err := container.Upgrade(ctx); err != nil {
		fail(err)
	}
	os.Chmod(filepath.Join(dir, "session.db"), 0o600)
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		fail(err)
	}
	store.DeviceProps.Os = proto.String("Perch")
	client = whatsmeow.NewClient(device, waLog.Noop)
	// Perch decides when a chat has been read; nothing is marked read just by arriving.
	go work()
	client.AddEventHandler(enqueue)
	note("started, linked=%v", client.Store.ID != nil)

	go connect()
	commands()
}

func fail(err error) {
	emit("error", map[string]any{"message": err.Error()})
	os.Exit(1)
}

// connect logs in, showing a QR code to scan the first time.
func connect() {
	if client.Store.ID == nil {
		qr, _ := client.GetQRChannel(ctx)
		if err := client.Connect(); err != nil {
			emit("error", map[string]any{"message": err.Error()})
			return
		}
		for item := range qr {
			switch item.Event {
			case "code":
				emit("qr", map[string]any{"code": item.Code})
			case "success":
				emit("paired", nil)
			case "timeout":
				emit("qrTimeout", nil)
			default:
				if item.Error != nil {
					emit("error", map[string]any{"message": item.Error.Error()})
				}
			}
		}
		return
	}
	if err := client.Connect(); err != nil {
		emit("error", map[string]any{"message": err.Error()})
	}
}

func setup() {
	db.Exec(`CREATE TABLE IF NOT EXISTS chats (
		jid TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '', is_group INTEGER NOT NULL DEFAULT 0,
		last_ts INTEGER NOT NULL DEFAULT 0, unread INTEGER NOT NULL DEFAULT 0)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS messages (
		chat TEXT NOT NULL, id TEXT NOT NULL, sender TEXT NOT NULL DEFAULT '', sender_name TEXT NOT NULL DEFAULT '',
		from_me INTEGER NOT NULL DEFAULT 0, ts INTEGER NOT NULL, text TEXT NOT NULL DEFAULT '',
		kind TEXT NOT NULL DEFAULT 'text', mime TEXT NOT NULL DEFAULT '', filename TEXT NOT NULL DEFAULT '',
		raw BLOB, read INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (chat, id))`)
	db.Exec(`CREATE INDEX IF NOT EXISTS messages_ts ON messages (chat, ts)`)
	// Ticks for the user's own messages: 1 sent, 2 delivered, 3 read. And a small preview
	// picture that WhatsApp sends inside photo and video messages.
	db.Exec(`ALTER TABLE messages ADD COLUMN status INTEGER NOT NULL DEFAULT 0`)
	db.Exec(`ALTER TABLE messages ADD COLUMN thumb BLOB`)
	// Reactions to a message, as JSON: who reacted to what.
	db.Exec(`ALTER TABLE messages ADD COLUMN reactions TEXT NOT NULL DEFAULT '{}'`)
	// The message this one replies to, as JSON: its id, who sent it and a line of it.
	db.Exec(`ALTER TABLE messages ADD COLUMN quote TEXT NOT NULL DEFAULT ''`)
	// In a group, each member's receipt for each of the user's messages: 2 delivered, 3 read.
	// A group message only goes blue once everyone has read it, as in WhatsApp.
	var had string
	db.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'receipts'`).Scan(&had)
	db.Exec(`CREATE TABLE IF NOT EXISTS receipts (chat TEXT NOT NULL, id TEXT NOT NULL, who TEXT NOT NULL,
		level INTEGER NOT NULL, PRIMARY KEY (chat, id, who))`)
	if had == "" {
		// Group messages turned blue by the first reader before this was counted properly.
		db.Exec(`UPDATE messages SET status = 2 WHERE status = 3 AND from_me = 1 AND chat LIKE '%@g.us'`)
	}
}

// groupTick is where a group message's ticks stand from its members' receipts: blue once all of
// them have read it, two grey once all have it, one grey before that.
func groupTick(chat, id string, others int) int {
	if others <= 0 {
		return 1
	}
	var read, got int
	db.QueryRow(`SELECT COUNT(*) FROM receipts WHERE chat = ? AND id = ? AND level >= 3`, chat, id).Scan(&read)
	db.QueryRow(`SELECT COUNT(*) FROM receipts WHERE chat = ? AND id = ? AND level >= 2`, chat, id).Scan(&got)
	switch {
	case read >= others:
		return 3
	case got >= others:
		return 2
	}
	return 1
}

// MARK: Events

// note writes what happened to helper.log (event kinds and errors only, never message content).
func note(format string, args ...any) {
	f, err := os.OpenFile(filepath.Join(dir, "helper.log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	fmt.Fprintf(f, "%s %s\n", time.Now().Format("15:04:05"), fmt.Sprintf(format, args...))
	f.Close()
}

// queue hands events to a worker of their own. whatsmeow waits for each handler to return
// before it reads anything else, so asking WhatsApp a question inside one (a group's name, its
// size) waited on itself forever and nothing more came through. The worker can ask freely.
var queue = make(chan any, 4096)

func enqueue(evt any) {
	select {
	case queue <- evt:
	default:
		note("queue full, dropped %T", evt)
	}
}

func work() {
	for evt := range queue {
		handle(evt)
	}
}

func handle(evt any) {
	switch e := evt.(type) {
	case *events.Receipt, *events.Presence, *events.ChatPresence, *events.PushName:
	case *events.OfflineSyncPreview:
		note("offline preview: %d messages, %d receipts, %d notifications", e.Messages, e.Receipts, e.Notifications)
	case *events.Message:
		note("message: chat %s, from me %v, nil %v", e.Info.Chat.Server, e.Info.IsFromMe, e.Message == nil)
	default:
		note("event %T", evt)
	}
	switch e := evt.(type) {
	case *events.Connected:
		merge()
		learnGroups()
		me := ""
		if client.Store.ID != nil {
			me = client.Store.ID.ToNonAD().String()
		}
		emit("ready", map[string]any{"me": me, "name": client.Store.PushName})
	case *events.LoggedOut:
		emit("loggedOut", nil)
	case *events.Disconnected:
		emit("disconnected", nil)
	case *events.Message:
		m := record(e, true, 1)
		if m != nil {
			emit("message", m)
		}
	case *events.HistorySync:
		n := 0
		for _, conv := range e.Data.GetConversations() {
			chat, err := types.ParseJID(conv.GetID())
			if err != nil {
				continue
			}
			if name := conv.GetName(); name != "" {
				db.Exec(`INSERT INTO chats (jid, name, is_group) VALUES (?, ?, ?)
					ON CONFLICT(jid) DO UPDATE SET name = excluded.name`, key(chat), name, boolInt(chat.Server == types.GroupServer))
			}
			for _, hm := range conv.GetMessages() {
				evt, err := client.ParseWebMessage(chat, hm.GetMessage())
				if err != nil {
					continue
				}
				if record(evt, false, webStatus(int(hm.GetMessage().GetStatus()))) != nil {
					n++
				}
			}
			if u := conv.GetUnreadCount(); u > 0 {
				db.Exec(`UPDATE chats SET unread = ? WHERE jid = ?`, u, key(chat))
			}
		}
		emit("synced", map[string]any{"messages": n})
	case *events.Receipt:
		// The other side got, or read, the user's messages: the ticks move on.
		if !e.IsFromMe {
			tick := 0
			switch e.Type {
			case types.ReceiptTypeDelivered:
				tick = 2
			case types.ReceiptTypeRead, types.ReceiptTypePlayed:
				tick = 3
			}
			if tick > 0 && len(e.MessageIDs) > 0 && e.Chat.Server == types.GroupServer {
				// In a group each member's receipt counts on its own.
				chat, who := key(e.Chat), key(e.Sender)
				size, _ := groupShape(e.Chat)
				for _, id := range e.MessageIDs {
					db.Exec(`INSERT INTO receipts (chat, id, who, level) VALUES (?, ?, ?, ?)
						ON CONFLICT(chat, id, who) DO UPDATE SET level = MAX(level, excluded.level)`, chat, id, who, tick)
					status := groupTick(chat, id, size-1)
					db.Exec(`UPDATE messages SET status = MAX(status, ?) WHERE chat = ? AND id = ? AND from_me = 1`, status, chat, id)
					emit("status", map[string]any{"chat": chat, "ids": []string{id}, "status": status})
				}
			} else if tick > 0 && len(e.MessageIDs) > 0 {
				chat := key(e.Chat)
				for _, id := range e.MessageIDs {
					db.Exec(`UPDATE messages SET status = MAX(status, ?) WHERE chat = ? AND id = ? AND from_me = 1`, tick, chat, id)
				}
				emit("status", map[string]any{"chat": chat, "ids": e.MessageIDs, "status": tick})
			}
		}
		// Read on the phone or another device: it is read here too.
		if e.IsFromMe && (e.Type == types.ReceiptTypeRead || e.Type == types.ReceiptTypeReadSelf) {
			db.Exec(`UPDATE chats SET unread = 0 WHERE jid = ?`, key(e.Chat))
			db.Exec(`UPDATE messages SET read = 1 WHERE chat = ?`, key(e.Chat))
			emit("read", map[string]any{"chat": key(e.Chat)})
		}
	case *events.ChatPresence:
		// Someone typing (or recording a voice note) in a chat: only sent while Perch is online,
		// which it is while one of its WhatsApp chats is open.
		emit("typing", map[string]any{"chat": key(e.Chat), "who": nameOf(e.Sender), "group": e.IsGroup,
			"typing": e.State == types.ChatPresenceComposing, "audio": e.Media == types.ChatPresenceMediaAudio})
	case *events.MarkChatAsRead:
		if e.Action.GetRead() {
			db.Exec(`UPDATE chats SET unread = 0 WHERE jid = ?`, key(e.JID))
			emit("read", map[string]any{"chat": key(e.JID)})
		}
	}
}

// key is how a chat or person is filed: by phone number where WhatsApp has told us it, so the
// same person is not split between their number and their anonymous id.
func key(j types.JID) string {
	j = j.ToNonAD()
	if j.Server == types.HiddenUserServer && client != nil {
		if pn, err := client.Store.LIDs.GetPNForLID(ctx, j); err == nil && !pn.IsEmpty() {
			return pn.ToNonAD().String()
		}
	}
	return j.String()
}

// merge files chats kept under an anonymous id under the phone number instead, once it is known.
func merge() {
	rows, err := db.Query(`SELECT jid FROM chats WHERE jid LIKE '%@lid'`)
	if err != nil {
		return
	}
	var lids []string
	for rows.Next() {
		var j string
		rows.Scan(&j)
		lids = append(lids, j)
	}
	rows.Close()
	for _, l := range lids {
		lid, err := types.ParseJID(l)
		if err != nil {
			continue
		}
		pn := key(lid)
		if pn == l {
			continue
		}
		db.Exec(`UPDATE OR IGNORE messages SET chat = ? WHERE chat = ?`, pn, l)
		db.Exec(`UPDATE messages SET sender = ? WHERE sender = ?`, pn, l)
		db.Exec(`INSERT INTO chats (jid, name, is_group, last_ts, unread) SELECT ?, name, is_group, last_ts, unread FROM chats WHERE jid = ?
			ON CONFLICT(jid) DO UPDATE SET last_ts = MAX(chats.last_ts, excluded.last_ts), unread = chats.unread + excluded.unread`, pn, l)
		db.Exec(`DELETE FROM messages WHERE chat = ?`, l)
		db.Exec(`DELETE FROM chats WHERE jid = ?`, l)
	}
	note("merged %d anonymous-id chats", len(lids))
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// record saves a message and returns it as Perch sees it, or nil for things that are not
// messages to show (reactions, edits, protocol noise).
// react records a reaction on a message (an empty one takes it away) and tells Perch.
func react(chat, id, who, emoji string, mine, live bool) {
	var stored, original, kind string
	var originalMine bool
	db.QueryRow(`SELECT reactions, text, kind, from_me FROM messages WHERE chat = ? AND id = ?`, chat, id).Scan(&stored, &original, &kind, &originalMine)
	actor := "You"
	if !mine {
		if jid, err := types.ParseJID(who); err == nil {
			actor = nameOf(jid)
		}
	}
	all := map[string]string{}
	json.Unmarshal([]byte(stored), &all)
	if mine {
		who = "me"
	}
	previous := all[who]
	if emoji == "" {
		delete(all, who)
	} else {
		all[who] = emoji
	}
	b, _ := json.Marshal(all)
	db.Exec(`UPDATE messages SET reactions = ? WHERE chat = ? AND id = ?`, string(b), chat, id)
	if live && previous != emoji {
		jid, _ := types.ParseJID(chat)
		emit("reaction", map[string]any{"chat": chat, "id": id, "reactions": all,
			"emoji": emoji, "fromMe": mine, "actorName": actor, "chatName": chatName(jid),
			"group": jid.Server == types.GroupServer, "originalText": original, "originalKind": kind,
			"originalFromMe": originalMine})
	}
}

// webStatus turns WhatsApp's own message status into ticks: 1 sent, 2 delivered, 3 read.
func webStatus(s int) int {
	switch {
	case s >= 4:
		return 3
	case s == 3:
		return 2
	default:
		return 1
	}
}

func record(e *events.Message, live bool, status int) map[string]any {
	msg := e.Message
	// Status updates are not chats: never stored, shown or notified.
	if msg == nil || e.Info.Chat.Server == types.BroadcastServer {
		return nil
	}
	if inner := msg.GetEphemeralMessage().GetMessage(); inner != nil {
		msg = inner
	}
	if inner := msg.GetViewOnceMessage().GetMessage(); inner != nil {
		msg = inner
	}
	if r := msg.GetReactionMessage(); r != nil {
		react(key(e.Info.Chat), r.GetKey().GetID(), key(e.Info.Sender), r.GetText(), e.Info.IsFromMe, live)
		return nil
	}
	text, kind, mimeType, filename := describe(msg)
	if kind == "" {
		// Which parts the message had (names only, no content), to see what is not handled.
		var parts []string
		msg.ProtoReflect().Range(func(fd protoreflect.FieldDescriptor, _ protoreflect.Value) bool {
			parts = append(parts, string(fd.Name()))
			return true
		})
		note("skipped message with %v", parts)
		return nil
	}
	chat := key(e.Info.Chat)
	sender := key(e.Info.Sender)
	senderName := e.Info.PushName
	if senderName == "" {
		senderName = nameOf(e.Info.Sender)
	}
	var raw []byte
	if kind != "text" {
		raw, _ = proto.Marshal(msg)
	}
	ts := e.Info.Timestamp.Unix()
	thumb := msg.GetImageMessage().GetJPEGThumbnail()
	if thumb == nil {
		thumb = msg.GetVideoMessage().GetJPEGThumbnail()
	}
	if !e.Info.IsFromMe {
		status = 0
	}
	quote := quoteOf(msg)
	res, err := db.Exec(`INSERT OR IGNORE INTO messages (chat, id, sender, sender_name, from_me, ts, text, kind, mime, filename, raw, read, status, thumb, quote)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, chat, e.Info.ID, sender, senderName, boolInt(e.Info.IsFromMe), ts, text,
		kind, mimeType, filename, raw, boolInt(e.Info.IsFromMe || !live), status, thumb, quote)
	if err != nil {
		note("store failed: %v", err)
		return nil
	}
	if added, _ := res.RowsAffected(); added == 0 {
		note("already had it")
		return nil
	}
	note("saved %s", kind)
	isGroup := e.Info.Chat.Server == types.GroupServer
	db.Exec(`INSERT INTO chats (jid, is_group, last_ts) VALUES (?, ?, ?)
		ON CONFLICT(jid) DO UPDATE SET last_ts = MAX(last_ts, excluded.last_ts)`, chat, boolInt(isGroup), ts)
	if live && !e.Info.IsFromMe {
		db.Exec(`UPDATE chats SET unread = unread + 1 WHERE jid = ?`, chat)
	}
	if live && e.Info.IsFromMe {
		db.Exec(`UPDATE chats SET unread = 0 WHERE jid = ?`, chat)
	}
	size, community := 0, false
	if isGroup {
		size, community = groupShape(e.Info.Chat)
	}
	return map[string]any{
		"mentionsMe": mentionsMe(msg), "groupSize": size, "community": community,
		"chat": chat, "chatName": chatName(e.Info.Chat), "group": isGroup, "id": e.Info.ID, "sender": sender,
		"senderName": senderName, "fromMe": e.Info.IsFromMe, "ts": ts, "text": text, "kind": kind,
		"mime": mimeType, "filename": filename, "status": status, "thumb": thumb, "quote": quoteMap(quote),
	}
}

func quoteMap(stored string) map[string]string {
	if stored == "" {
		return nil
	}
	q := map[string]string{}
	json.Unmarshal([]byte(stored), &q)
	return q
}

var (
	shapes   = map[string][2]int{}
	shapesMu sync.Mutex
)

// groupShape is how many people are in a group, and whether it belongs to a Community (or is
// an announcement channel), which decides how loudly it gets to notify. Asked once per group.
// learnGroups reads every group the user is in with one request, so whether each one is a
// big group or part of a Community is known up front instead of guessed when a lookup fails.
func learnGroups() {
	groups, err := client.GetJoinedGroups(ctx)
	if err != nil {
		note("joined groups failed: %v", err)
		return
	}
	communities := 0
	shapesMu.Lock()
	for _, info := range groups {
		community := info.IsParent || !info.LinkedParentJID.IsEmpty() || info.IsDefaultSubGroup || info.IsAnnounce
		communities += boolInt(community)
		shapes[key(info.JID)] = [2]int{len(info.Participants), boolInt(community)}
	}
	shapesMu.Unlock()
	note("learned %d groups, %d in communities", len(groups), communities)
}

func groupShape(j types.JID) (int, bool) {
	k := key(j)
	shapesMu.Lock()
	known, ok := shapes[k]
	shapesMu.Unlock()
	if ok {
		return known[0], known[1] == 1
	}
	info, err := client.GetGroupInfo(ctx, j)
	if err != nil || info == nil {
		note("group info failed: %v", err)
		return 0, false
	}
	community := info.IsParent || !info.LinkedParentJID.IsEmpty() || info.IsDefaultSubGroup || info.IsAnnounce
	if info.Name != "" {
		db.Exec(`INSERT INTO chats (jid, name, is_group) VALUES (?, ?, 1) ON CONFLICT(jid) DO UPDATE SET name = excluded.name`, k, info.Name)
	}
	shapesMu.Lock()
	shapes[k] = [2]int{len(info.Participants), boolInt(community)}
	shapesMu.Unlock()
	return len(info.Participants), community
}

// mentionsMe is true when a group message @-mentions the user or replies to one of theirs.
func contextOf(m *waE2E.Message) *waE2E.ContextInfo {
	switch {
	case m.GetExtendedTextMessage() != nil:
		return m.GetExtendedTextMessage().GetContextInfo()
	case m.GetImageMessage() != nil:
		return m.GetImageMessage().GetContextInfo()
	case m.GetVideoMessage() != nil:
		return m.GetVideoMessage().GetContextInfo()
	case m.GetDocumentMessage() != nil:
		return m.GetDocumentMessage().GetContextInfo()
	case m.GetAudioMessage() != nil:
		return m.GetAudioMessage().GetContextInfo()
	case m.GetStickerMessage() != nil:
		return m.GetStickerMessage().GetContextInfo()
	}
	return nil
}

// quoteOf is the message this one replies to, as stored JSON ("" when it is not a reply).
func quoteOf(m *waE2E.Message) string {
	info := contextOf(m)
	if info == nil || info.GetStanzaID() == "" {
		return ""
	}
	text, kind := "", ""
	if q := info.GetQuotedMessage(); q != nil {
		text, kind, _, _ = describe(q)
	}
	who := ""
	if p, err := types.ParseJID(info.GetParticipant()); err == nil && !p.IsEmpty() {
		if client.Store.ID != nil && (p.User == client.Store.ID.User || p.User == client.Store.LID.User) {
			who = "You"
		} else {
			who = nameOf(p)
		}
	}
	out, _ := json.Marshal(map[string]string{"id": info.GetStanzaID(), "sender": who, "text": text, "kind": kind})
	return string(out)
}

func mentionsMe(m *waE2E.Message) bool {
	if client.Store.ID == nil {
		return false
	}
	info := contextOf(m)
	if info == nil {
		return false
	}
	mine := map[string]bool{client.Store.ID.User: true}
	if !client.Store.LID.IsEmpty() {
		mine[client.Store.LID.User] = true
	}
	for _, j := range info.GetMentionedJID() {
		if parsed, err := types.ParseJID(j); err == nil && mine[parsed.User] {
			return true
		}
	}
	if parsed, err := types.ParseJID(info.GetParticipant()); err == nil && mine[parsed.User] {
		return true
	}
	return false
}

// describe pulls the readable part out of a message: its text, and what sort of thing it is.
func describe(m *waE2E.Message) (text, kind, mimeType, filename string) {
	switch {
	case m.GetConversation() != "":
		return m.GetConversation(), "text", "", ""
	case m.GetExtendedTextMessage() != nil:
		return m.GetExtendedTextMessage().GetText(), "text", "", ""
	case m.GetImageMessage() != nil:
		return m.GetImageMessage().GetCaption(), "image", m.GetImageMessage().GetMimetype(), ""
	case m.GetVideoMessage() != nil:
		return m.GetVideoMessage().GetCaption(), "video", m.GetVideoMessage().GetMimetype(), ""
	case m.GetAudioMessage() != nil:
		return "", "audio", m.GetAudioMessage().GetMimetype(), ""
	case m.GetDocumentMessage() != nil:
		d := m.GetDocumentMessage()
		return d.GetCaption(), "document", d.GetMimetype(), d.GetFileName()
	case m.GetStickerMessage() != nil:
		return "", "sticker", m.GetStickerMessage().GetMimetype(), ""
	case m.GetContactMessage() != nil:
		return "Contact: " + m.GetContactMessage().GetDisplayName(), "text", "", ""
	case m.GetLocationMessage() != nil:
		return "Location: " + m.GetLocationMessage().GetName(), "text", "", ""
	}
	return "", "", "", ""
}

// nameOf finds the best name for a person: theirs in the contact list, or what they call themselves.
func nameOf(j types.JID) string {
	j = j.ToNonAD()
	// The same person can be on file under their number and their anonymous id, with the name
	// they gave WhatsApp kept under either: look under both.
	look := []types.JID{j}
	if j.Server == types.HiddenUserServer {
		if pn, err := client.Store.LIDs.GetPNForLID(ctx, j); err == nil && !pn.IsEmpty() {
			look = append(look, pn)
		}
	} else if j.Server == types.DefaultUserServer {
		if lid, err := client.Store.LIDs.GetLIDForPN(ctx, j); err == nil && !lid.IsEmpty() {
			look = append(look, lid)
		}
	}
	for _, id := range look {
		if c, err := client.Store.Contacts.GetContact(ctx, id); err == nil && c.Found {
			for _, n := range []string{c.FullName, c.FirstName, c.BusinessName, c.PushName} {
				if n != "" {
					return n
				}
			}
		}
	}
	for _, id := range look {
		if id.Server == types.DefaultUserServer {
			return "+" + id.User
		}
	}
	return j.User
}

// personName is someone's name for their chat: as saved in the contacts, or what they call
// themselves on WhatsApp (shown there as "~Name"), and only then their number.
func personName(j types.JID, chat string) string {
	name := nameOf(j)
	if !strings.HasPrefix(name, "+") && name != j.User {
		return name
	}
	var pushed string
	db.QueryRow(`SELECT sender_name FROM messages WHERE chat = ? AND from_me = 0 AND sender_name != '' AND sender_name NOT LIKE '+%'
		ORDER BY ts DESC LIMIT 1`, chat).Scan(&pushed)
	if pushed != "" {
		return pushed
	}
	var stored string
	db.QueryRow(`SELECT name FROM chats WHERE jid = ?`, chat).Scan(&stored)
	if stored != "" {
		return stored
	}
	return name
}

// chatName is a person's name for a direct chat, or the group's subject.
func chatName(j types.JID) string {
	k := key(j)
	var name string
	db.QueryRow(`SELECT name FROM chats WHERE jid = ?`, k).Scan(&name)
	if name != "" {
		return name
	}
	if j.Server == types.GroupServer {
		if info, err := client.GetGroupInfo(ctx, j); err == nil && info.Name != "" {
			db.Exec(`INSERT INTO chats (jid, name, is_group) VALUES (?, ?, 1) ON CONFLICT(jid) DO UPDATE SET name = excluded.name`, k, info.Name)
			return info.Name
		}
		return "Group"
	}
	return personName(j, k)
}

// MARK: Commands

type command struct {
	ID      int    `json:"id"`
	Cmd     string `json:"cmd"`
	Chat    string `json:"chat"`
	Text    string `json:"text"`
	Path    string `json:"path"`
	Message string `json:"message"`
	Limit   int    `json:"limit"`
}

func commands() {
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 1<<20), 16<<20)
	for in.Scan() {
		var c command
		if json.Unmarshal(in.Bytes(), &c) != nil {
			continue
		}
		go func(c command) {
			data, err := run(c)
			if err != nil {
				note("command %s failed: %v", c.Cmd, err)
				out(map[string]any{"id": c.ID, "ok": false, "error": err.Error()})
			} else {
				out(map[string]any{"id": c.ID, "ok": true, "data": data})
			}
		}(c)
	}
	// Perch has gone: leave cleanly.
	client.Disconnect()
}

func run(c command) (any, error) {
	switch c.Cmd {
	case "status":
		return map[string]any{"linked": client.Store.ID != nil, "connected": client.IsConnected()}, nil
	case "chats":
		return chats(c.Limit)
	case "history":
		return history(c.Chat, c.Limit)
	case "send":
		return send(c.Chat, c.Text, c.Message)
	case "sendFile":
		return sendFile(c.Chat, c.Path, c.Text)
	case "markRead":
		return nil, markRead(c.Chat)
	case "download":
		return download(c.Chat, c.Message)
	case "avatar":
		return avatar(c.Chat)
	case "contacts":
		return contacts()
	case "react":
		return sendReaction(c.Chat, c.Message, c.Text)
	case "watch":
		// A chat is open in Perch: be online, as WhatsApp Web is while in use, so typing comes
		// through. For a person, typing only arrives once subscribed to them.
		if err := client.SendPresence(ctx, types.PresenceAvailable); err != nil {
			return nil, err
		}
		if j, err := types.ParseJID(c.Chat); err == nil && j.Server != types.GroupServer {
			client.SubscribePresence(ctx, j)
		}
		return nil, nil
	case "unwatch":
		// No chat open: offline again, so the phone keeps getting its notifications.
		return nil, client.SendPresence(ctx, types.PresenceUnavailable)
	case "logout":
		err := client.Logout(ctx)
		return nil, err
	}
	return nil, fmt.Errorf("unknown command %q", c.Cmd)
}

func chats(limit int) (any, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := db.Query(`SELECT c.jid, c.name, c.is_group, c.last_ts, c.unread,
		COALESCE((SELECT text FROM messages m WHERE m.chat = c.jid ORDER BY ts DESC LIMIT 1), ''),
		COALESCE((SELECT kind FROM messages m WHERE m.chat = c.jid ORDER BY ts DESC LIMIT 1), ''),
		COALESCE((SELECT from_me * 10 + status FROM messages m WHERE m.chat = c.jid ORDER BY ts DESC LIMIT 1), 0),
		(SELECT thumb FROM messages m WHERE m.chat = c.jid ORDER BY ts DESC LIMIT 1)
		FROM chats c WHERE c.last_ts > 0 ORDER BY c.last_ts DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	type row struct {
		jid, name, last, kind   string
		group, ts, unread, mine int64
		thumb                   []byte
	}
	var found []row
	for rows.Next() {
		var r row
		rows.Scan(&r.jid, &r.name, &r.group, &r.ts, &r.unread, &r.last, &r.kind, &r.mine, &r.thumb)
		found = append(found, r)
	}
	// Names are looked up only once the list has been read, never while it is still open:
	// looking up inside the read waited on itself.
	rows.Close()
	var list []map[string]any
	for _, r := range found {
		j, err := types.ParseJID(r.jid)
		if err == nil && j.Server == types.BroadcastServer {
			continue
		}
		name := r.name
		if err == nil {
			if r.group == 1 {
				if name == "" {
					name = chatName(j)
				}
			} else {
				// A person: their name in the contacts, or else the name they gave WhatsApp.
				name = personName(j, r.jid)
			}
		}
		entry := map[string]any{"chat": r.jid, "name": name, "group": r.group == 1, "ts": r.ts,
			"unread": r.unread, "last": r.last, "lastKind": r.kind, "lastMine": r.mine >= 10, "lastStatus": r.mine % 10, "lastThumb": r.thumb}
		// How big a group is, for deciding whether it may notify. Asked only for unread groups.
		if r.group == 1 && r.unread > 0 && err == nil {
			size, community := groupShape(j)
			entry["groupSize"] = size
			entry["community"] = community
		}
		list = append(list, entry)
	}
	return list, nil
}

func history(chat string, limit int) (any, error) {
	if limit <= 0 {
		limit = 80
	}
	rows, err := db.Query(`SELECT id, sender, sender_name, from_me, ts, text, kind, mime, filename, status, thumb, reactions, quote FROM
		(SELECT * FROM messages WHERE chat = ? ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC`, chat, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []map[string]any
	for rows.Next() {
		var id, sender, senderName, text, kind, mimeType, filename string
		var fromMe, ts, status int64
		var thumb []byte
		var reactions, quote string
		rows.Scan(&id, &sender, &senderName, &fromMe, &ts, &text, &kind, &mimeType, &filename, &status, &thumb, &reactions, &quote)
		all := map[string]string{}
		json.Unmarshal([]byte(reactions), &all)
		list = append(list, map[string]any{"id": id, "sender": sender, "senderName": senderName, "fromMe": fromMe == 1,
			"ts": ts, "text": text, "kind": kind, "mime": mimeType, "filename": filename, "status": status, "thumb": thumb,
			"reactions": all, "quote": quoteMap(quote)})
	}
	return list, nil
}

// send posts a text message. With replyTo, it goes as a reply quoting that message, the way
// swiping on a message in WhatsApp does.
func send(chat, text, replyTo string) (any, error) {
	to, err := types.ParseJID(chat)
	if err != nil {
		return nil, err
	}
	msg := &waE2E.Message{Conversation: proto.String(text)}
	quote := ""
	if replyTo != "" {
		var sender, quotedText, kind string
		var fromMe int
		var raw []byte
		if db.QueryRow(`SELECT sender, from_me, text, kind, raw FROM messages WHERE chat = ? AND id = ?`, chat, replyTo).
			Scan(&sender, &fromMe, &quotedText, &kind, &raw) == nil {
			quoted := &waE2E.Message{}
			if len(raw) == 0 || proto.Unmarshal(raw, quoted) != nil {
				quoted = &waE2E.Message{Conversation: proto.String(quotedText)}
			}
			participant := sender
			if fromMe == 1 && client.Store.ID != nil {
				participant = client.Store.ID.ToNonAD().String()
			}
			msg = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{Text: proto.String(text),
				ContextInfo: &waE2E.ContextInfo{StanzaID: proto.String(replyTo), Participant: proto.String(participant),
					QuotedMessage: quoted}}}
			who := "You"
			if fromMe == 0 {
				if j, err := types.ParseJID(sender); err == nil {
					who = nameOf(j)
				}
			}
			out, _ := json.Marshal(map[string]string{"id": replyTo, "sender": who, "text": quotedText, "kind": kind})
			quote = string(out)
		}
	}
	resp, err := client.SendMessage(ctx, to, msg)
	if err != nil {
		return nil, err
	}
	keep(chat, resp.ID, resp.Timestamp, text, "text", "", "", nil)
	if quote != "" {
		db.Exec(`UPDATE messages SET quote = ? WHERE chat = ? AND id = ?`, quote, chat, resp.ID)
	}
	return map[string]any{"id": resp.ID, "ts": resp.Timestamp.Unix()}, nil
}

func sendFile(chat, path, caption string) (any, error) {
	to, err := types.ParseJID(chat)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	mimeType := mime.TypeByExtension(strings.ToLower(filepath.Ext(path)))
	if mimeType == "" {
		mimeType = http.DetectContentType(data)
	}
	name := filepath.Base(path)
	var msg *waE2E.Message
	kind := "document"
	switch {
	case strings.HasPrefix(mimeType, "image/") && mimeType != "image/gif":
		up, err := client.Upload(ctx, data, whatsmeow.MediaImage)
		if err != nil {
			return nil, err
		}
		kind = "image"
		msg = &waE2E.Message{ImageMessage: &waE2E.ImageMessage{Caption: proto.String(caption), Mimetype: proto.String(mimeType),
			URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256,
			FileSHA256: up.FileSHA256, FileLength: proto.Uint64(uint64(len(data)))}}
	case strings.HasPrefix(mimeType, "audio/") || strings.EqualFold(filepath.Ext(path), ".ogg"):
		if strings.EqualFold(filepath.Ext(path), ".ogg") {
			mimeType = "audio/ogg; codecs=opus"
		}
		up, err := client.Upload(ctx, data, whatsmeow.MediaAudio)
		if err != nil {
			return nil, err
		}
		kind = "audio"
		msg = &waE2E.Message{AudioMessage: &waE2E.AudioMessage{Mimetype: proto.String(mimeType),
			PTT: proto.Bool(strings.EqualFold(filepath.Ext(path), ".ogg")),
			URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256,
			FileSHA256: up.FileSHA256, FileLength: proto.Uint64(uint64(len(data)))}}
	case strings.HasPrefix(mimeType, "video/"):
		up, err := client.Upload(ctx, data, whatsmeow.MediaVideo)
		if err != nil {
			return nil, err
		}
		kind = "video"
		msg = &waE2E.Message{VideoMessage: &waE2E.VideoMessage{Caption: proto.String(caption), Mimetype: proto.String(mimeType),
			URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256,
			FileSHA256: up.FileSHA256, FileLength: proto.Uint64(uint64(len(data)))}}
	default:
		up, err := client.Upload(ctx, data, whatsmeow.MediaDocument)
		if err != nil {
			return nil, err
		}
		msg = &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{Caption: proto.String(caption), Mimetype: proto.String(mimeType),
			FileName: proto.String(name), Title: proto.String(name),
			URL: &up.URL, DirectPath: &up.DirectPath, MediaKey: up.MediaKey, FileEncSHA256: up.FileEncSHA256,
			FileSHA256: up.FileSHA256, FileLength: proto.Uint64(uint64(len(data)))}}
	}
	resp, err := client.SendMessage(ctx, to, msg)
	if err != nil {
		return nil, err
	}
	raw, _ := proto.Marshal(msg)
	keep(chat, resp.ID, resp.Timestamp, caption, kind, mimeType, name, raw)
	return map[string]any{"id": resp.ID, "ts": resp.Timestamp.Unix()}, nil
}

// keep records something the user sent from Perch, so it shows straight away.
func keep(chat, id string, at time.Time, text, kind, mimeType, filename string, raw []byte) {
	me := ""
	if client.Store.ID != nil {
		me = key(*client.Store.ID)
	}
	db.Exec(`INSERT OR IGNORE INTO messages (chat, id, sender, sender_name, from_me, ts, text, kind, mime, filename, raw, read)
		VALUES (?, ?, ?, 'You', 1, ?, ?, ?, ?, ?, ?, 1)`, chat, id, me, at.Unix(), text, kind, mimeType, filename, raw)
	db.Exec(`UPDATE messages SET status = MAX(status, 1) WHERE chat = ? AND id = ?`, chat, id)
	db.Exec(`UPDATE chats SET last_ts = MAX(last_ts, ?), unread = 0 WHERE jid = ?`, at.Unix(), chat)
}

// markRead sends read receipts for what has arrived in a chat, as opening it on the phone would.
func markRead(chat string) error {
	j, err := types.ParseJID(chat)
	if err != nil {
		return err
	}
	rows, err := db.Query(`SELECT id, sender FROM messages WHERE chat = ? AND from_me = 0 AND read = 0`, chat)
	if err != nil {
		return err
	}
	bySender := map[string][]types.MessageID{}
	for rows.Next() {
		var id, sender string
		rows.Scan(&id, &sender)
		bySender[sender] = append(bySender[sender], id)
	}
	rows.Close()
	for sender, ids := range bySender {
		s, _ := types.ParseJID(sender)
		if j.Server != types.GroupServer {
			s = types.EmptyJID
		}
		if err := client.MarkRead(ctx, ids, time.Now(), j, s); err != nil {
			return err
		}
	}
	db.Exec(`UPDATE messages SET read = 1 WHERE chat = ?`, chat)
	db.Exec(`UPDATE chats SET unread = 0 WHERE jid = ?`, chat)
	// Read receipts tick the messages, but the chat's own unread marker (the green dot on the
	// phone and in WhatsApp's desktop app) is synced separately. Clear that too, every time.
	var id, sender string
	var fromMe, ts int64
	if db.QueryRow(`SELECT id, sender, from_me, ts FROM messages WHERE chat = ? ORDER BY ts DESC LIMIT 1`, chat).
		Scan(&id, &sender, &fromMe, &ts) == nil {
		msgKey := &waCommon.MessageKey{RemoteJID: proto.String(j.String()), FromMe: proto.Bool(fromMe == 1), ID: proto.String(id)}
		if j.Server == types.GroupServer && fromMe == 0 && sender != "" {
			msgKey.Participant = proto.String(sender)
		}
		if err := client.SendAppState(ctx, appstate.BuildMarkChatAsRead(j, true, time.Unix(ts, 0), msgKey)); err != nil {
			note("chat read marker failed: %v", err)
		}
	}
	return nil
}

func download(chat, id string) (any, error) {
	var raw []byte
	var kind, mimeType, filename string
	if err := db.QueryRow(`SELECT raw, kind, mime, filename FROM messages WHERE chat = ? AND id = ?`, chat, id).
		Scan(&raw, &kind, &mimeType, &filename); err != nil {
		return nil, err
	}
	if len(raw) == 0 {
		return nil, fmt.Errorf("nothing to download")
	}
	var msg waE2E.Message
	if err := proto.Unmarshal(raw, &msg); err != nil {
		return nil, err
	}
	data, err := client.DownloadAny(ctx, &msg)
	if err != nil {
		return nil, err
	}
	name := filename
	if name == "" {
		ext := ".bin"
		if exts, _ := mime.ExtensionsByType(strings.Split(mimeType, ";")[0]); len(exts) > 0 {
			ext = exts[len(exts)-1]
		}
		name = id + ext
	}
	path := filepath.Join(dir, "media", strings.ReplaceAll(id, "/", "_")+"-"+filepath.Base(name))
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return nil, err
	}
	return map[string]any{"path": path}, nil
}

// contacts is everyone in the user's WhatsApp contacts, by the name they are saved under, with
// their newer anonymous id too, so a chat already filed under that id is found.
func contacts() (any, error) {
	all, err := client.Store.Contacts.GetAllContacts(ctx)
	if err != nil {
		return nil, err
	}
	var list []map[string]any
	for jid, c := range all {
		name := c.FullName
		if name == "" {
			name = c.FirstName
		}
		if name == "" {
			name = c.BusinessName
		}
		if name == "" || jid.Server != types.DefaultUserServer {
			continue
		}
		lid := ""
		if l, err := client.Store.LIDs.GetLIDForPN(ctx, jid); err == nil && !l.IsEmpty() {
			lid = l.String()
		}
		list = append(list, map[string]any{"jid": jid.String(), "lid": lid, "name": name, "pushName": c.PushName})
	}
	return list, nil
}

// sendReaction reacts to a message with an emoji (or takes the reaction away, given none).
func sendReaction(chat, id, emoji string) (any, error) {
	to, err := types.ParseJID(chat)
	if err != nil {
		return nil, err
	}
	var sender string
	var fromMe int
	if err := db.QueryRow(`SELECT sender, from_me FROM messages WHERE chat = ? AND id = ?`, chat, id).Scan(&sender, &fromMe); err != nil {
		return nil, err
	}
	who, _ := types.ParseJID(sender)
	if fromMe == 1 && client.Store.ID != nil {
		who = client.Store.ID.ToNonAD()
	} else if who.IsEmpty() && to.Server != types.GroupServer {
		// Messages synced from the phone's history can lack a sender. In a one-to-one chat it is
		// the other person; without this the reaction pointed at one of the user's own messages
		// and WhatsApp quietly dropped it.
		who = to
	}
	if _, err := client.SendMessage(ctx, to, client.BuildReaction(to, who, id, emoji)); err != nil {
		note("reaction failed: %v", err)
		return nil, err
	}
	react(chat, id, "me", emoji, true, true)
	note("reaction sent")
	return map[string]any{"ok": true}, nil
}

func avatar(chat string) (any, error) {
	j, err := types.ParseJID(chat)
	if err != nil {
		return nil, err
	}
	info, err := client.GetProfilePictureInfo(ctx, j, &whatsmeow.GetProfilePictureParams{Preview: true})
	// Someone known by their anonymous id: try their phone number instead.
	if (err != nil || info == nil) && j.Server == types.HiddenUserServer {
		if pn, perr := client.Store.LIDs.GetPNForLID(ctx, j); perr == nil && !pn.IsEmpty() {
			info, err = client.GetProfilePictureInfo(ctx, pn, &whatsmeow.GetProfilePictureParams{Preview: true})
		}
	}
	if err != nil || info == nil {
		return map[string]any{"url": ""}, nil
	}
	return map[string]any{"url": info.URL}, nil
}
