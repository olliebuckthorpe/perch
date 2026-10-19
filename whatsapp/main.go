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
	db.SetMaxOpenConns(1)
	setup()
	os.Chmod(filepath.Join(dir, "messages.db"), 0o600)

	sessionDB, err := sql.Open("sqlite", "file:"+filepath.Join(dir, "session.db")+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)")
	if err != nil {
		fail(err)
	}
	sessionDB.SetMaxOpenConns(1)
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
	switch evt.(type) {
	case *events.Message, *events.Connected, *events.Disconnected, *events.LoggedOut, *events.HistorySync, *events.StreamReplaced:
		note("event %T", evt)
	}
	switch e := evt.(type) {
	case *events.Connected:
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
		m := record(e, true)
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
				if record(evt, false) != nil {
					n++
				}
			}
			if u := conv.GetUnreadCount(); u > 0 {
				db.Exec(`UPDATE chats SET unread = ? WHERE jid = ?`, u, key(chat))
			}
		}
		emit("synced", map[string]any{"messages": n})
	case *events.Receipt:
		// Read on the phone or another device: it is read here too.
		if e.IsFromMe && (e.Type == types.ReceiptTypeRead || e.Type == types.ReceiptTypeReadSelf) {
			db.Exec(`UPDATE chats SET unread = 0 WHERE jid = ?`, key(e.Chat))
			db.Exec(`UPDATE messages SET read = 1 WHERE chat = ?`, key(e.Chat))
			emit("read", map[string]any{"chat": key(e.Chat)})
		}
	case *events.MarkChatAsRead:
		if e.Action.GetRead() {
			db.Exec(`UPDATE chats SET unread = 0 WHERE jid = ?`, key(e.JID))
			emit("read", map[string]any{"chat": key(e.JID)})
		}
	}
}

func key(j types.JID) string { return j.ToNonAD().String() }

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// record saves a message and returns it as Perch sees it, or nil for things that are not
// messages to show (reactions, edits, protocol noise).
func record(e *events.Message, live bool) map[string]any {
	msg := e.Message
	if msg == nil {
		return nil
	}
	if inner := msg.GetEphemeralMessage().GetMessage(); inner != nil {
		msg = inner
	}
	if inner := msg.GetViewOnceMessage().GetMessage(); inner != nil {
		msg = inner
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
	res, err := db.Exec(`INSERT OR IGNORE INTO messages (chat, id, sender, sender_name, from_me, ts, text, kind, mime, filename, raw, read)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, chat, e.Info.ID, sender, senderName, boolInt(e.Info.IsFromMe), ts, text,
		kind, mimeType, filename, raw, boolInt(e.Info.IsFromMe || !live))
	if err != nil {
		note("store failed: %v", err)
		return nil
	}
	if added, _ := res.RowsAffected(); added == 0 {
		return nil
	}
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
		"mime": mimeType, "filename": filename,
	}
}

var (
	shapes   = map[string][2]int{}
	shapesMu sync.Mutex
)

// groupShape is how many people are in a group, and whether it belongs to a Community (or is
// an announcement channel), which decides how loudly it gets to notify. Asked once per group.
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
func mentionsMe(m *waE2E.Message) bool {
	if client.Store.ID == nil {
		return false
	}
	var info *waE2E.ContextInfo
	switch {
	case m.GetExtendedTextMessage() != nil:
		info = m.GetExtendedTextMessage().GetContextInfo()
	case m.GetImageMessage() != nil:
		info = m.GetImageMessage().GetContextInfo()
	case m.GetVideoMessage() != nil:
		info = m.GetVideoMessage().GetContextInfo()
	case m.GetDocumentMessage() != nil:
		info = m.GetDocumentMessage().GetContextInfo()
	}
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
	look := []types.JID{j}
	if j.Server == types.HiddenUserServer {
		if pn, err := client.Store.LIDs.GetPNForLID(ctx, j); err == nil && !pn.IsEmpty() {
			look = append(look, pn)
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
	return nameOf(j)
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
		return send(c.Chat, c.Text)
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
		COALESCE((SELECT kind FROM messages m WHERE m.chat = c.jid ORDER BY ts DESC LIMIT 1), '')
		FROM chats c WHERE c.last_ts > 0 ORDER BY c.last_ts DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []map[string]any
	for rows.Next() {
		var jid, name, last, kind string
		var group, ts, unread int64
		rows.Scan(&jid, &name, &group, &ts, &unread, &last, &kind)
		if name == "" {
			if j, err := types.ParseJID(jid); err == nil {
				name = chatName(j)
			}
		}
		if j, err := types.ParseJID(jid); err == nil && j.Server == types.BroadcastServer {
			continue
		}
		list = append(list, map[string]any{"chat": jid, "name": name, "group": group == 1, "ts": ts,
			"unread": unread, "last": last, "lastKind": kind})
	}
	return list, nil
}

func history(chat string, limit int) (any, error) {
	if limit <= 0 {
		limit = 80
	}
	rows, err := db.Query(`SELECT id, sender, sender_name, from_me, ts, text, kind, mime, filename FROM
		(SELECT * FROM messages WHERE chat = ? ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC`, chat, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var list []map[string]any
	for rows.Next() {
		var id, sender, senderName, text, kind, mimeType, filename string
		var fromMe, ts int64
		rows.Scan(&id, &sender, &senderName, &fromMe, &ts, &text, &kind, &mimeType, &filename)
		list = append(list, map[string]any{"id": id, "sender": sender, "senderName": senderName, "fromMe": fromMe == 1,
			"ts": ts, "text": text, "kind": kind, "mime": mimeType, "filename": filename})
	}
	return list, nil
}

func send(chat, text string) (any, error) {
	to, err := types.ParseJID(chat)
	if err != nil {
		return nil, err
	}
	resp, err := client.SendMessage(ctx, to, &waE2E.Message{Conversation: proto.String(text)})
	if err != nil {
		return nil, err
	}
	keep(chat, resp.ID, resp.Timestamp, text, "text", "", "", nil)
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
