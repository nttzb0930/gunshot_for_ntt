package service

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func rebackupTest(t *testing.T, e *Engine, asset string) (*Job, string) {
	t.Helper()
	b, _ := json.Marshal(map[string]any{"account": "a@example.com", "quality": "original", "resources": []Resource{{Name: "photo.jpg", Size: 3}}, "rebackupAssetID": asset})
	var request Request
	if err := json.Unmarshal(b, &request); err != nil {
		t.Fatal(err)
	}
	v, err := e.begin(request, "photos")
	if err != nil {
		t.Fatal(err)
	}
	j := e.find(v.(map[string]any)["id"].(string))
	if err = e.appendChunk(j, Request{Index: 0, Data: []byte("abc")}); err != nil {
		t.Fatal(err)
	}
	v, err = e.seal(j)
	if err != nil {
		t.Fatal(err)
	}
	return j, v.(map[string]any)["id"].(string)
}

func TestRebackupDoesNotReuseHistoricalOutcome(t *testing.T) {
	for _, state := range []string{"completed", "failed"} {
		t.Run(state, func(t *testing.T) {
			e := newEngine(t, nil)
			old := importTest(t, e, "original")
			old.State, old.OriginalPolicy = state, 1
			fresh, id := rebackupTest(t, e, "local-photo/L0/001")
			if id == old.ID || fresh.State != "pending" {
				t.Fatalf("rebackup reused historical %s instead of queueing new upload", state)
			}
			b, _ := json.Marshal(fresh)
			if !strings.Contains(string(b), `"rebackupAssetID":"local-photo/L0/001"`) {
				t.Fatal("local source missing from durable upload history")
			}
			summary, _ := json.Marshal(e.uploadSummary())
			if strings.Contains(string(summary), "local-photo") || strings.Contains(string(summary), "rebackupAssetID") {
				t.Fatal("local photo identifier leaked into upload diagnostics")
			}
			reopened, err := Open(e.root, nil)
			if err != nil {
				t.Fatal(err)
			}
			if reopened.find(fresh.ID).RebackupAssetID != "local-photo/L0/001" {
				t.Fatal("reopening the queue lost the local photo association")
			}
		})
	}
}

func TestRebackupReusesActiveUploadAndKeepsSingleHistoryRow(t *testing.T) {
	e := newEngine(t, nil)
	old := importTest(t, e, "original")
	fresh, id := rebackupTest(t, e, "local-photo/L0/001")
	if id != old.ID || fresh.State != "cancelled" {
		t.Fatal("rebackup duplicated an active upload")
	}
	b, _ := json.Marshal(old)
	if !strings.Contains(string(b), `"rebackupAssetID":"local-photo/L0/001"`) {
		t.Fatal("reused job is not linked to local photo")
	}
	b, _ = json.Marshal(fresh)
	if strings.Contains(string(b), "rebackupAssetID") {
		t.Fatal("duplicate import would appear as a cancelled rebackup")
	}
}

func TestRebackupRejectsInvalidSource(t *testing.T) {
	for _, asset := range []string{"\x00", "photo\nidentifier", strings.Repeat("x", 1025)} {
		e := newEngine(t, nil)
		b, _ := json.Marshal(map[string]any{"account": "a", "quality": "original", "resources": []Resource{{Name: "p.jpg", Size: 3}}, "rebackupAssetID": asset})
		var request Request
		_ = json.Unmarshal(b, &request)
		if _, err := e.begin(request, "photos"); err == nil {
			t.Fatal("accepted invalid local source")
		}
	}
}

func TestRebackupInvalidatesHistoricalCompletionForNativeImports(t *testing.T) {
	for _, state := range []string{"completed", "failed"} {
		e := newEngine(t, nil)
		old := importTest(t, e, "original")
		old.State, old.OriginalPolicy = state, 1
		fresh, _ := rebackupTest(t, e, "local-photo/L0/001")
		// Native backup can notice consent was restored while explicit upload runs.
		duplicate, id := rebackupTest(t, e, "")
		if duplicate.State != "cancelled" || id != fresh.ID || fresh.State != "pending" {
			t.Fatal("native import can still reuse a superseded upload outcome")
		}
	}
}

func TestRebackupCompletesOnlyAfterNewRunnerResult(t *testing.T) {
	calls := 0
	e := newEngine(t, func(_ context.Context, _ []string, _, _ string, progress func(Progress)) (string, error) {
		calls++
		progress(Progress{State: "committing", Uploaded: 3, Total: 3})
		return "new-cloud-copy", nil
	})
	old := importTest(t, e, "original")
	old.State, old.OriginalPolicy, old.MediaKey = "completed", 1, "deleted-cloud-copy"
	fresh, _ := rebackupTest(t, e, "local-photo/L0/001")
	if fresh.State != "pending" || fresh.MediaKey != "" {
		t.Fatal("rebackup reported a server result before uploading")
	}
	e.online, e.wifi = true, true
	e.Tick()
	waitIdle(t, e)
	if calls != 1 || fresh.State != "completed" || fresh.MediaKey != "new-cloud-copy" {
		t.Fatal("rebackup did not wait for a fresh upload result")
	}
	reopened, err := Open(e.root, nil)
	if err != nil || reopened.find(fresh.ID).State != "completed" {
		t.Fatal("rebackup completion did not survive reopening the queue")
	}
}

func TestRebackupRejectsCorruptPersistedSource(t *testing.T) {
	e := newEngine(t, nil)
	j := importTest(t, e, "original")
	j.RebackupAssetID = "invalid\nidentifier"
	if err := e.save(); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(e.root, nil); err == nil {
		t.Fatal("restored an invalid local source identifier")
	}
}
