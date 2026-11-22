package service

import (
	"app/backend"
	"context"
	"fmt"
	"testing"
	"time"
)

type catalogFake struct {
	pages   map[string]backend.GunshotAlbumPage
	wait    chan struct{}
	entered chan struct{}
}

func (f *catalogFake) List(ctx context.Context, account, token string) (backend.GunshotAlbumPage, error) {
	if f.entered != nil {
		select {
		case f.entered <- struct{}{}:
		default:
		}
	}
	if f.wait != nil {
		select {
		case <-f.wait:
		case <-ctx.Done():
			return backend.GunshotAlbumPage{}, ctx.Err()
		}
	}
	return f.pages[token], nil
}
func TestCatalogAsyncAndPagination(t *testing.T) {
	e := &Engine{catalogs: map[string]*albumCatalog{}}
	f := &catalogFake{pages: map[string]backend.GunshotAlbumPage{"": {Albums: []backend.GunshotAlbumEntry{{AlbumKey: "a", Name: "A"}}, Next: "next"}, "next": {Albums: []backend.GunshotAlbumEntry{{AlbumKey: "b", Name: "B"}}}}, wait: make(chan struct{}), entered: make(chan struct{}, 1)}
	e.catalogLister = f
	e.mu.Lock()
	v, _ := e.catalogView("one", 0, false)
	e.mu.Unlock()
	if v.State != "loading" {
		t.Fatalf("state=%s", v.State)
	}
	<-f.entered
	ping := make(chan []byte, 1)
	go func() { ping <- e.HandleJSON([]byte(`{"op":"ping"}`), "settings") }()
	select {
	case reply := <-ping:
		if string(reply) != `{"data":{"version":1},"ok":true}` {
			t.Fatalf("ping failed during catalog load: %s", reply)
		}
	case <-time.After(time.Second):
		close(f.wait)
		e.Close()
		t.Fatal("catalog network request blocked the engine")
	}
	close(f.wait)
	deadline := time.Now().Add(time.Second)
	for {
		e.mu.Lock()
		v, _ = e.catalogView("one", 0, false)
		e.mu.Unlock()
		if v.State != "loading" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(time.Millisecond)
	}
	if v.State != "ready" || len(v.Albums) != 2 {
		t.Fatalf("result=%+v", v)
	}
	e.Close()
}
func TestAlbumViewFailedCreatesAreAccountScoped(t *testing.T) {
	e := &Engine{state: State{AlbumTargets: map[string]*AlbumTarget{
		"a": {ID: "a", Account: "a", State: "failed", Name: "failed"},
		"b": {ID: "b", Account: "b", State: "failed"},
		"c": {ID: "c", Account: "a", State: "failed", AlbumKey: "key", Name: "repair"},
	}, AlbumTasks: []*AlbumTask{{TargetID: "c", State: "failed"}}}}
	v := e.albumView("a")
	if v["failedCreates"] != 1 {
		t.Fatalf("failed creates: %v", v["failedCreates"])
	}
	targets := v["repairableTargets"].([]map[string]string)
	if len(targets) != 1 || targets[0]["name"] != "repair" {
		t.Fatalf("targets: %v", targets)
	}
}

func waitCatalog(t *testing.T, e *Engine, account string) catalogResponse {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for {
		e.mu.Lock()
		v, err := e.catalogView(account, 0, false)
		e.mu.Unlock()
		if err != nil {
			t.Fatal(err)
		}
		if v.State != "loading" {
			return v
		}
		if time.Now().After(deadline) {
			t.Fatal("catalog timeout")
		}
		time.Sleep(time.Millisecond)
	}
}
func TestCatalogCycleFailsAndRefreshRecovers(t *testing.T) {
	e := &Engine{catalogLister: &catalogFake{pages: map[string]backend.GunshotAlbumPage{"": {Next: "x"}, "x": {Next: "x"}}}}
	if v := waitCatalog(t, e, "a"); v.State != "failed" || v.Error == "" {
		t.Fatalf("%+v", v)
	}
	e.mu.Lock()
	e.catalogLister = &catalogFake{pages: map[string]backend.GunshotAlbumPage{"": {Albums: []backend.GunshotAlbumEntry{{AlbumKey: "ok"}}}}}
	_, err := e.catalogView("a", 0, true)
	e.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	if v := waitCatalog(t, e, "a"); v.State != "ready" || len(v.Albums) != 1 {
		t.Fatalf("%+v", v)
	}
	e.Close()
}
func TestCatalogPagesAndAccounts(t *testing.T) {
	entries := make([]backend.GunshotAlbumEntry, 51)
	for i := range entries {
		entries[i].AlbumKey = fmt.Sprintf("AF1Qip-key-%d", i)
	}
	e := &Engine{catalogLister: &catalogFake{pages: map[string]backend.GunshotAlbumPage{"": {Albums: entries}}}}
	v := waitCatalog(t, e, "a")
	if len(v.Albums) != 50 || v.Next != 50 {
		t.Fatalf("%+v", v)
	}
	e.mu.Lock()
	v, err := e.catalogView("a", 50, false)
	e.mu.Unlock()
	if err != nil || len(v.Albums) != 1 || v.Next != -1 {
		t.Fatalf("%+v %v", v, err)
	}
	e.mu.Lock()
	e.catalogLister = &catalogFake{pages: map[string]backend.GunshotAlbumPage{"": {}}}
	e.mu.Unlock()
	if v = waitCatalog(t, e, "b"); v.State != "ready" || len(v.Albums) != 0 {
		t.Fatalf("%+v", v)
	}
	if v = waitCatalog(t, e, "a"); len(v.Albums) != 50 {
		t.Fatal("account cache changed")
	}
	e.Close()
}

func TestCatalogDeduplicatesOverlappingRemotePages(t *testing.T) {
	entries := make([]backend.GunshotAlbumEntry, 3000)
	for i := range entries {
		entries[i].AlbumKey = fmt.Sprintf("AF1Qip-key-%d", i)
	}
	e := &Engine{catalogLister: &catalogFake{pages: map[string]backend.GunshotAlbumPage{
		"": {Albums: entries, Next: "more"}, "more": {Albums: entries},
	}}}
	defer e.Close()
	v := waitCatalog(t, e, "a")
	if v.State != "ready" {
		t.Fatalf("overlapping pages exhausted unique-album limit: %s", v.Error)
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if len(e.catalogs["a"].albums) != 3000 {
		t.Fatal("duplicate albums across pages")
	}
}

func TestCatalogRemovedAccountCancelsAndEvicts(t *testing.T) {
	e := relayEngine(t, nil)
	nativeValidationServer(t)
	relayRequest(t, e, "googlephotos", Request{Op: "account_native", Account: "a@example.com", NativeID: "old", Secret: "synthetic-native-bearer"}, true)
	e.mu.Lock()
	e.catalogLister = &catalogFake{wait: make(chan struct{})}
	_, _ = e.catalogView("a@example.com", 0, false)
	old := e.catalogs["a@example.com"]
	t.Cleanup(old.cancel)
	e.mu.Unlock()
	relayRequest(t, e, "settings", Request{Op: "account_remove", Account: "a@example.com"}, true)
	e.mu.Lock()
	_, stale := e.catalogs["a@example.com"]
	e.mu.Unlock()
	if stale {
		t.Fatal("removed account retained album metadata")
	}
	finished := make(chan struct{})
	go func() { e.wg.Wait(); close(finished) }()
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("removed-account discovery did not finish after cancellation")
	}
	if old.state != "failed" {
		t.Fatal("in-flight discovery was not cancelled")
	}
	relayRequest(t, e, "googlephotos", Request{Op: "account_native", Account: "a@example.com", NativeID: "new", Secret: "synthetic-native-bearer"}, true)
	e.mu.Lock()
	e.catalogLister = &catalogFake{pages: map[string]backend.GunshotAlbumPage{"": {Albums: []backend.GunshotAlbumEntry{{AlbumKey: "AF1Qip-new"}}}}}
	e.mu.Unlock()
	if v := waitCatalog(t, e, "a@example.com"); v.State != "ready" || len(v.Albums) != 1 || v.Albums[0].AlbumKey != "AF1Qip-new" {
		t.Fatal("reconnected identity received a stale catalog")
	}
	// Even replacing an existing binding must invalidate the cached discovery.
	relayRequest(t, e, "googlephotos", Request{Op: "account_native", Account: "a@example.com", NativeID: "replacement", Secret: "synthetic-native-bearer"}, true)
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.catalogs["a@example.com"] != nil {
		t.Fatal("replaced identity retained album cache")
	}
}
func TestCatalogCloseCancelsWorker(t *testing.T) {
	e := &Engine{catalogLister: &catalogFake{wait: make(chan struct{})}}
	e.mu.Lock()
	_, _ = e.catalogView("a", 0, false)
	e.mu.Unlock()
	done := make(chan struct{})
	go func() { e.Close(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("close blocked")
	}
	e.mu.Lock()
	_, err := e.catalogView("b", 0, false)
	e.mu.Unlock()
	if err == nil {
		t.Fatal("started after close")
	}
}
