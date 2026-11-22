package service

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

type fakeAlbums struct {
	creates, adds     int
	keys              []string
	createErr, addErr error
}

func (f *fakeAlbums) Create(context.Context, string, string) (string, error) {
	f.creates++
	return "AF1Qip-created", f.createErr
}

func TestAlbumExistingTitleMetadataSurvivesRestart(t *testing.T) {
	e, _, _ := albumEngine(t, "existing")
	name := strings.Repeat("ảnh ", 80) // Cloud titles need not fit the new-album input limit.
	if err := e.configureAlbum("a@example.com", AlbumSettings{Enabled: true, Mode: "existing", AlbumKey: "AF1Qip-existing", Name: name}); err != nil {
		t.Fatal(err)
	}
	settings := e.albumView("a@example.com")["settings"].(AlbumSettings)
	if settings.Name != strings.TrimSpace(name) {
		t.Fatal("selecting the same album did not refresh its displayed name")
	}
	if err := e.restoreAlbums(); err != nil {
		t.Fatalf("valid cloud album title would prevent restart: %v", err)
	}
	for _, mode := range []string{"existing", "create"} {
		tooLong := strings.Repeat("x", 4097)
		if err := e.configureAlbum("a@example.com", AlbumSettings{Enabled: true, Mode: mode, AlbumKey: "AF1Qip-existing", Name: tooLong}); err == nil {
			t.Fatal("unbounded album name accepted")
		}
	}
	if err := e.configureAlbum("a@example.com", AlbumSettings{Enabled: true, Mode: "create", Name: name}); err == nil {
		t.Fatal("new-album name limit changed")
	}
}
func (f *fakeAlbums) Add(_ context.Context, _, _ string, keys []string) error {
	f.adds++
	f.keys = append(f.keys, keys...)
	return f.addErr
}
func albumEngine(t *testing.T, mode string) (*Engine, *fakeAlbums, string) {
	t.Helper()
	e := newEngine(t, nil)
	f := &fakeAlbums{}
	e.albums = f
	e.online = true
	e.wifi = true
	if err := e.configureAlbum("a@example.com", AlbumSettings{Enabled: true, Mode: mode, AlbumKey: map[string]string{"existing": "AF1Qip-existing"}[mode], Name: map[string]string{"create": "My album"}[mode]}); err != nil {
		t.Fatal(err)
	}
	return e, f, e.state.AlbumConfigs["a@example.com"].TargetID
}
func albumComplete(t *testing.T, e *Engine, target string, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		j := &Job{ID: fmt.Sprintf("%032x", i+1), Account: "a@example.com", Quality: "original", State: "completed", Resources: []Resource{{Name: fmt.Sprintf("%d.jpg", i), Size: 3}}, Total: 3, Owner: "photos", MediaKey: fmt.Sprintf("media-%d", i), AlbumTargets: []string{target}}
		e.state.Jobs = append(e.state.Jobs, j)
		e.jobsByID[j.ID] = j
		e.enqueueAlbum(j)
	}
	if err := e.save(); err != nil {
		t.Fatal(err)
	}
}
func flushAlbums(t *testing.T, e *Engine) {
	t.Helper()
	for i := 0; i < 4; i++ {
		e.Tick()
		waitIdle(t, e)
	}
}
func TestAlbumFiveItemsExistingAndCreate(t *testing.T) {
	for _, mode := range []string{"existing", "create"} {
		t.Run(mode, func(t *testing.T) {
			e, f, target := albumEngine(t, mode)
			albumComplete(t, e, target, 5)
			flushAlbums(t, e)
			if f.adds != 1 || len(f.keys) != 5 || f.creates != map[string]int{"existing": 0, "create": 1}[mode] {
				t.Fatalf("wrong effects: %+v", f)
			}
			for _, task := range e.state.AlbumTasks {
				if task.State != "completed" {
					t.Fatal(task)
				}
			}
			flushAlbums(t, e)
			if f.adds != 1 {
				t.Fatal("repeated completion duplicated assignments")
			}
		})
	}
}
func TestAlbumFailureDoesNotReuploadAndRetriesAreBounded(t *testing.T) {
	e, f, target := albumEngine(t, "create")
	albumComplete(t, e, target, 5)
	f.addErr = &AlbumFailure{Code: "rate_limited", Retryable: true}
	flushAlbums(t, e)
	if f.creates != 1 || e.state.Jobs[0].State != "completed" {
		t.Fatal("album failure changed upload")
	}
	for _, task := range e.state.AlbumTasks {
		if task.State != "pending" || task.Next <= time.Now().Unix() {
			t.Fatal("missing retry backoff")
		}
		task.Next = 0
	}
	f.addErr = nil
	flushAlbums(t, e)
	if f.creates != 1 || len(e.state.AlbumTasks) != 5 {
		t.Fatal("recreated album")
	}
}
func TestAlbumRestartPreservesCreatedIDAndPendingTasks(t *testing.T) {
	e, f, target := albumEngine(t, "create")
	albumComplete(t, e, target, 5)
	f.addErr = &AlbumFailure{Code: "forbidden"}
	flushAlbums(t, e)
	e.Close()
	next, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	next.albums = f
	next.online = true
	next.wifi = true
	f.addErr = nil
	if err = next.retryAlbum("a@example.com", false); err != nil {
		t.Fatal(err)
	}
	flushAlbums(t, next)
	if f.creates != 1 || f.adds != 2 {
		t.Fatalf("restart effects: %+v", f)
	}
}
func TestAlbumUncertainCreateDoesNotCreateAgain(t *testing.T) {
	e, f, target := albumEngine(t, "create")
	albumComplete(t, e, target, 1)
	f.createErr = &AlbumFailure{Code: "create_outcome_unknown", Uncertain: true}
	flushAlbums(t, e)
	if err := e.retryAlbum("a@example.com", false); err == nil {
		t.Fatal("blind uncertain create retry")
	}
	flushAlbums(t, e)
	if f.creates != 1 {
		t.Fatal("duplicate album")
	}
	if err := e.resolveAlbum("a@example.com", target, "AF1Qip-recovered"); err != nil {
		t.Fatal(err)
	}
	flushAlbums(t, e)
	if f.adds != 1 || f.creates != 1 {
		t.Fatal("failed to recover known album")
	}
}
func TestAlbumInterruptedAddNeedsExplicitRetry(t *testing.T) {
	e, _, target := albumEngine(t, "existing")
	albumComplete(t, e, target, 1)
	for _, task := range e.state.AlbumTasks {
		task.State = "adding"
	}
	if err := e.save(); err != nil {
		t.Fatal(err)
	}
	next, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeAlbums{}
	next.albums = f
	next.online = true
	next.wifi = true
	flushAlbums(t, next)
	if f.adds != 0 {
		t.Fatal("repeated uncertain request")
	}
	if err = next.retryAlbum("a@example.com", false); err == nil {
		t.Fatal("uncertain assignment not reported")
	}
	if err = next.retryAlbum("a@example.com", true); err != nil {
		t.Fatal(err)
	}
	flushAlbums(t, next)
	if f.adds != 1 {
		t.Fatal("explicit retry did not resume")
	}
}
func TestAlbumDisabledAndPendingImportsWait(t *testing.T) {
	e, f, target := albumEngine(t, "existing")
	albumComplete(t, e, target, 1)
	pending := &Job{Account: "a@example.com", State: "importing"}
	e.state.Jobs = append(e.state.Jobs, pending)
	e.Tick()
	waitIdle(t, e)
	if f.adds != 0 {
		t.Fatal("flushed before import settled")
	}
	e.state.Jobs = e.state.Jobs[:1]
	cfg := e.state.AlbumConfigs["a@example.com"]
	cfg.Enabled = false
	flushAlbums(t, e)
	if f.adds != 0 {
		t.Fatal("ran while disabled")
	}
	cfg.Enabled = true
	flushAlbums(t, e)
	if f.adds != 1 {
		t.Fatal("did not resume")
	}
}
func TestAlbumTargetsDoNotMoveAfterConfigChange(t *testing.T) {
	e, f, target := albumEngine(t, "existing")
	albumComplete(t, e, target, 1)
	if err := e.configureAlbum("a@example.com", AlbumSettings{Enabled: true, Mode: "existing", AlbumKey: "AF1Qip-other"}); err != nil {
		t.Fatal(err)
	}
	if e.state.AlbumTasks[0].TargetID != target {
		t.Fatal("redirected existing task")
	}
	flushAlbums(t, e)
	if f.adds != 1 {
		t.Fatal("lost old target work")
	}
}
func TestAlbumPartialUploadAndUnknownMedia(t *testing.T) {
	e, f, target := albumEngine(t, "existing")
	albumComplete(t, e, target, 1)
	j := e.state.Jobs[0]
	j.State = "failed"
	j.MediaKey = ""
	e.state.AlbumTasks = nil
	e.enqueueAlbum(j)
	if len(e.state.AlbumTasks) != 0 {
		t.Fatal("queued failed upload")
	}
	j.State = "completed"
	e.enqueueAlbum(j)
	flushAlbums(t, e)
	if f.adds != 0 || e.state.AlbumTasks[0].State != "unresolved" {
		t.Fatal("invented media ID")
	}
}
func TestAlbumInvalidSettingsAndSanitizedFailures(t *testing.T) {
	e, _, _ := albumEngine(t, "existing")
	for _, s := range []AlbumSettings{{Enabled: true, Mode: "existing", AlbumKey: "bad"}, {Enabled: true, Mode: "create", Name: " "}, {Enabled: true, Mode: "other"}} {
		if e.configureAlbum("a@example.com", s) == nil {
			t.Fatal("accepted invalid target")
		}
	}
	err := errors.New("secret=DO_NOT_LOG")
	if strings.Contains(albumFailure(err).Code, "DO_NOT_LOG") {
		t.Fatal("leaked backend error")
	}
}
func TestAlbumQueueCapturesUploadSuccessAndDedup(t *testing.T) {
	e, _, target := albumEngine(t, "existing")
	e.runner = func(context.Context, []string, string, string, func(Progress)) (string, error) {
		return "confirmed", nil
	}
	j := importTest(t, e, "original")
	if len(j.AlbumTargets) != 1 || j.AlbumTargets[0] != target {
		t.Fatal("target not snapshotted")
	}
	e.Tick()
	waitIdle(t, e)
	if j.State != "completed" || len(e.state.AlbumTasks) != 1 {
		t.Fatal("completion not durably queued")
	}
	importTest(t, e, "original")
	if len(e.state.AlbumTasks) != 1 {
		t.Fatal("duplicate callback created duplicate tasks")
	}
}

func TestAlbumBatchImportBarrier(t *testing.T) {
	e, f, target := albumEngine(t, "existing")
	albumComplete(t, e, target, 1)
	if err := e.albumBatch("a@example.com", "batch", true); err != nil {
		t.Fatal(err)
	}
	flushAlbums(t, e)
	if f.adds != 0 {
		t.Fatal("assigned media while batch was still exporting")
	}
	if err := e.albumBatch("a@example.com", "batch", false); err != nil {
		t.Fatal(err)
	}
	flushAlbums(t, e)
	if f.adds != 1 {
		t.Fatal("batch completion did not release assignments")
	}
}

func TestAlbumMixedMediaBatchLimitAndAccountIsolation(t *testing.T) {
	e, f, target := albumEngine(t, "existing")
	albumComplete(t, e, target, 501)
	// Failed upload is terminal, so it must not block the 501 successful media.
	failed := &Job{Account: "a@example.com", State: "failed"}
	e.state.Jobs = append(e.state.Jobs, failed)
	for i, j := range e.state.Jobs[:501] {
		if i%2 == 1 {
			j.Resources[0].Name = "movie.mov"
		}
	}
	if err := e.configureAlbum("b@example.com", AlbumSettings{Enabled: true, Mode: "existing", AlbumKey: "AF1Qip-other-account"}); err != nil {
		t.Fatal(err)
	}
	flushAlbums(t, e)
	if f.adds != 2 || len(f.keys) != 501 {
		t.Fatal("batching or account isolation failed")
	}
}

func TestAlbumRetryBudgetAndDisabledUploads(t *testing.T) {
	e, f, target := albumEngine(t, "existing")
	albumComplete(t, e, target, 1)
	e.state.Options.Retries = 0
	f.addErr = &AlbumFailure{Code: "rate_limited", Retryable: true}
	flushAlbums(t, e)
	if f.adds != 1 || e.state.AlbumTasks[0].State != "failed" {
		t.Fatal("unbounded automatic retries")
	}
	other := newEngine(t, func(context.Context, []string, string, string, func(Progress)) (string, error) {
		return "uploaded", nil
	})
	other.online = true
	other.wifi = true
	j := importTest(t, other, "original")
	other.Tick()
	waitIdle(t, other)
	if j.State != "completed" || len(other.state.AlbumTasks) != 0 {
		t.Fatal("default-off changed upload behavior")
	}
}

func TestAlbumDisablingAnotherAccountDoesNotCancelActiveWrite(t *testing.T) {
	e, _, _ := albumEngine(t, "existing")
	cancelled := false
	e.albumActiveAccount = "a@example.com"
	e.albumCancel = func() { cancelled = true }
	if err := e.configureAlbum("b@example.com", AlbumSettings{Enabled: false}); err != nil {
		t.Fatal(err)
	}
	if cancelled {
		t.Fatal("account B interrupted account A's album write")
	}
	if err := e.configureAlbum("a@example.com", AlbumSettings{Enabled: false}); err != nil {
		t.Fatal(err)
	}
	if !cancelled {
		t.Fatal("disabling the active account did not pause it")
	}
}

func TestAlbumRejectedTargetCanBeCorrectedWithoutReupload(t *testing.T) {
	e, f, target := albumEngine(t, "existing")
	albumComplete(t, e, target, 5)
	f.addErr = &AlbumFailure{Code: "album_not_found_or_inaccessible"}
	flushAlbums(t, e)
	if err := e.repairAlbum("a@example.com", target, "AF1Qip-corrected"); err != nil {
		t.Fatal(err)
	}
	if e.state.AlbumConfigs["a@example.com"].TargetID == target {
		t.Fatal("future imports still use wrong target")
	}
	f.addErr = nil
	flushAlbums(t, e)
	completed, superseded := 0, 0
	for _, task := range e.state.AlbumTasks {
		switch task.State {
		case "completed":
			completed++
		case "superseded":
			superseded++
		}
	}
	if f.adds != 2 || completed != 5 || superseded != 5 || e.state.Jobs[0].State != "completed" {
		t.Fatal("target repair did not preserve uploads and resolve tasks")
	}
	next, err := Open(e.root, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(next.state.AlbumTasks) != 10 {
		t.Fatal("repair history lost on restart")
	}
}

func TestAlbumCorrectionAlsoUpdatesUnfinishedUploadSnapshots(t *testing.T) {
	e, f, target := albumEngine(t, "existing")
	albumComplete(t, e, target, 1)
	f.addErr = &AlbumFailure{Code: "album_not_found_or_inaccessible"}
	flushAlbums(t, e)
	j := importTest(t, e, "original")
	if err := e.repairAlbum("a@example.com", target, "AF1Qip-corrected"); err != nil {
		t.Fatal(err)
	}
	if j.AlbumTargets[0] != e.state.AlbumConfigs[j.Account].TargetID {
		t.Fatal("unfinished upload will recreate work against the rejected target")
	}
}
