package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"go.mau.fi/whatsmeow"
	"io"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func fixtureDB(t *testing.T) {
	t.Helper()
	var err error
	db, err = sql.Open("sqlite", filepath.Join(t.TempDir(), "messages.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	setup()
	_, err = db.Exec(`INSERT INTO chats (jid,name,is_group,last_ts) VALUES ('fixture@g.us','Fixture group',1,100)`)
	if err != nil {
		t.Fatal(err)
	}
}

func TestChatPreviewCarriesPhotoAndCaption(t *testing.T) {
	fixtureDB(t)
	_, err := db.Exec(`INSERT INTO messages (chat,id,ts,text,kind,thumb) VALUES ('fixture@g.us','photo',100,'Full caption','image',?)`, []byte{1, 2, 3})
	if err != nil {
		t.Fatal(err)
	}
	data, err := chats(20)
	if err != nil {
		t.Fatal(err)
	}
	rows := data.([]map[string]any)
	if len(rows) != 1 || rows[0]["last"] != "Full caption" || rows[0]["lastKind"] != "image" {
		t.Fatalf("Wrong preview: %#v", rows)
	}
	if len(rows[0]["lastThumb"].([]byte)) != 3 {
		t.Fatal("Photo thumbnail was lost")
	}
	_, err = db.Exec(`INSERT INTO messages (chat,id,ts,text,kind) VALUES ('fixture@g.us','text',101,'New text','text')`)
	if err != nil {
		t.Fatal(err)
	}
	data, err = chats(20)
	if err != nil {
		t.Fatal(err)
	}
	latest := data.([]map[string]any)[0]
	if latest["last"] != "New text" || len(latest["lastThumb"].([]byte)) != 0 {
		t.Fatal("Old photo remained on a newer text preview")
	}
}

func reactionOutput(t *testing.T, run func()) []map[string]any {
	t.Helper()
	previous := os.Stdout
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	os.Stdout = write
	defer func() { os.Stdout = previous; read.Close(); write.Close() }()
	run()
	write.Close()
	payload, err := io.ReadAll(read)
	if err != nil {
		t.Fatal(err)
	}
	var result []map[string]any
	decoder := json.NewDecoder(bytes.NewReader(payload))
	for {
		var row map[string]any
		if err := decoder.Decode(&row); err == io.EOF {
			break
		} else if err != nil {
			t.Fatal(err)
		}
		result = append(result, row)
	}
	return result
}

func TestReactionNoticeIncludesContextAndDeduplicates(t *testing.T) {
	fixtureDB(t)
	_, err := db.Exec(`INSERT INTO messages (chat,id,ts,text,kind,from_me) VALUES ('fixture@g.us','original',100,'See you tomorrow','text',1)`)
	if err != nil {
		t.Fatal(err)
	}
	events := reactionOutput(t, func() {
		react("fixture@g.us", "original", "fixture@s.whatsapp.net", "👍", true, true)
		react("fixture@g.us", "original", "fixture@s.whatsapp.net", "👍", true, true)
	})
	if len(events) != 1 {
		t.Fatalf("Expected one event, got %d", len(events))
	}
	e := events[0]
	if e["emoji"] != "👍" || e["actorName"] != "You" || e["originalText"] != "See you tomorrow" || e["originalFromMe"] != true || e["chatName"] != "Fixture group" {
		t.Fatalf("Incomplete reaction: %#v", e)
	}
	removed := reactionOutput(t, func() { react("fixture@g.us", "original", "fixture@s.whatsapp.net", "", true, true) })
	if len(removed) != 1 || removed[0]["emoji"] != "" {
		t.Fatal("Reaction removal not reported")
	}
	if len(removed[0]["reactions"].(map[string]any)) != 0 {
		t.Fatal("Removed reaction remained in the message")
	}
}

func TestKeepTryingRetriesUntilConnected(t *testing.T) {
	calls, reports := 0, 0
	keepTrying(context.Background(), func() error {
		calls++
		if calls < 3 {
			return errors.New("no such host")
		}
		return nil
	}, time.Millisecond, func(error) { reports++ })
	if calls != 3 || reports != 2 {
		t.Fatalf("calls %d, reports %d", calls, reports)
	}
}

func TestKeepTryingStopsWhenCancelledOrAlreadyConnected(t *testing.T) {
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	calls := 0
	keepTrying(cancelled, func() error { calls++; return errors.New("down") }, time.Hour, func(error) {})
	if calls != 1 {
		t.Fatalf("cancelled: %d calls", calls)
	}
	calls = 0
	keepTrying(context.Background(), func() error { calls++; return whatsmeow.ErrAlreadyConnected }, time.Hour, func(error) {})
	if calls != 1 {
		t.Fatalf("already connected: %d calls", calls)
	}
}
