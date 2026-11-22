package service

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

// Album work is persisted with upload completion, not in a second store which
// could lose a completion between two writes. It never changes upload status.
type AlbumSettings struct {
	Enabled  bool   `json:"enabled"`
	Mode     string `json:"mode"`
	AlbumKey string `json:"albumKey"`
	Name     string `json:"name"`
}
type AlbumConfig struct {
	Enabled  bool   `json:"enabled"`
	TargetID string `json:"targetID"`
}
type AlbumTarget struct {
	ID       string `json:"id"`
	Account  string `json:"account"`
	Mode     string `json:"mode"`
	Name     string `json:"name"`
	AlbumKey string `json:"albumKey"`
	State    string `json:"state,omitempty"`
	Error    string `json:"error,omitempty"`
	Attempts int    `json:"attempts,omitempty"`
	Next     int64  `json:"next,omitempty"`
}
type AlbumTask struct {
	ID       string `json:"id"`
	TargetID string `json:"targetID"`
	MediaKey string `json:"mediaKey,omitempty"`
	State    string `json:"state"`
	Error    string `json:"error,omitempty"`
	Attempts int    `json:"attempts,omitempty"`
	Next     int64  `json:"next,omitempty"`
}
type AlbumBackend interface {
	Create(context.Context, string, string) (string, error)
	Add(context.Context, string, string, []string) error
}
type albumImportLease struct {
	Account string
	Expires int64
}

func (e *Engine) albumBatch(account, id string, active bool) error {
	if account == "" || id == "" || len(id) > 64 || strings.ContainsAny(id, "\x00\r\n") {
		return errRequest
	}
	if e.albumImports == nil {
		e.albumImports = map[string]albumImportLease{}
	}
	key := account + "\x00" + id
	if active {
		e.albumImports[key] = albumImportLease{Account: account, Expires: time.Now().Add(time.Minute).Unix()}
	} else {
		delete(e.albumImports, key)
	}
	return nil
}

type AlbumFailure struct {
	Code                 string
	Retryable, Uncertain bool
}

func (f *AlbumFailure) Error() string { return f.Code }
func albumFailure(err error) *AlbumFailure {
	var f *AlbumFailure
	if errors.As(err, &f) {
		return f
	}
	return &AlbumFailure{Code: "album_outcome_unknown", Uncertain: true}
}
func appendUnique(keys []string, key string) []string {
	for _, old := range keys {
		if old == key {
			return keys
		}
	}
	return append(keys, key)
}
func validAlbumKey(s string) bool {
	if !strings.HasPrefix(s, "AF1Qip") || len(s) < 10 || len(s) > 512 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}
func validAlbumName(mode, name string) bool {
	if !utf8.ValidString(name) || strings.ContainsRune(name, 0) {
		return false
	}
	if mode == "existing" {
		return len(name) <= 4096
	}
	return len(name) <= 200 && strings.TrimSpace(name) != "" && !strings.ContainsAny(name, "\r\n")
}
func (e *Engine) restoreAlbums() error {
	if e.state.AlbumConfigs == nil {
		e.state.AlbumConfigs = map[string]*AlbumConfig{}
	}
	if e.state.AlbumTargets == nil {
		e.state.AlbumTargets = map[string]*AlbumTarget{}
	}
	for id, t := range e.state.AlbumTargets {
		if t == nil || t.ID != id || !validID(id) || t.Account == "" || (t.Mode != "existing" && t.Mode != "create") || t.Attempts < 0 || t.Attempts > 100 || t.Next < 0 || !validAlbumName(t.Mode, t.Name) || t.AlbumKey != "" && !validAlbumKey(t.AlbumKey) {
			return errors.New("invalid persisted album target")
		}
		if t.Mode == "existing" && t.AlbumKey == "" || t.Mode == "create" && strings.TrimSpace(t.Name) == "" {
			return errors.New("invalid persisted album target")
		}
		switch t.State {
		case "creating":
			t.State = "uncertain"
			t.Error = "create_outcome_unknown"
		case "", "ready", "pending", "failed", "uncertain":
		default:
			return errors.New("invalid album target state")
		}
	}
	for account, c := range e.state.AlbumConfigs {
		if c == nil || e.state.AlbumTargets[c.TargetID] == nil || e.state.AlbumTargets[c.TargetID].Account != account {
			return errors.New("invalid album configuration")
		}
	}
	seen := map[string]bool{}
	for _, task := range e.state.AlbumTasks {
		if task == nil || seen[task.ID] || e.state.AlbumTargets[task.TargetID] == nil || len(task.ID) != 64 || task.Attempts < 0 || task.Attempts > 100 || task.Next < 0 || len(task.MediaKey) > 1024 {
			return errors.New("invalid persisted album task")
		}
		seen[task.ID] = true
		switch task.State {
		case "adding":
			task.State = "uncertain"
			task.Error = "add_outcome_unknown"
		case "pending", "completed", "failed", "uncertain", "unresolved", "superseded":
		default:
			return errors.New("invalid album task state")
		}
		if task.State != "unresolved" && task.MediaKey == "" {
			return errors.New("missing album media key")
		}
	}
	return nil
}
func (e *Engine) configureAlbum(account string, s AlbumSettings) error {
	if account == "" {
		return errRequest
	}
	s.Name = strings.TrimSpace(s.Name)
	s.AlbumKey = strings.TrimSpace(s.AlbumKey)
	if !s.Enabled {
		if c := e.state.AlbumConfigs[account]; c != nil {
			c.Enabled = false
		}
		if e.albumCancel != nil && e.albumActiveAccount == account {
			e.albumCancel()
		}
		return e.save()
	}
	if s.Mode != "existing" && s.Mode != "create" || s.Mode == "existing" && !validAlbumKey(s.AlbumKey) || !validAlbumName(s.Mode, s.Name) {
		return errRequest
	}
	if c := e.state.AlbumConfigs[account]; c != nil {
		t := e.state.AlbumTargets[c.TargetID]
		if t.Mode == s.Mode && (s.Mode == "existing" && t.AlbumKey == s.AlbumKey || s.Mode == "create" && t.Name == s.Name) {
			c.Enabled = true
			if s.Mode == "existing" && s.Name != "" {
				t.Name = s.Name
			}
			return e.save()
		}
	}
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return err
	}
	id := hex.EncodeToString(bytes[:])
	t := &AlbumTarget{ID: id, Account: account, Mode: s.Mode, Name: s.Name}
	if s.Mode == "existing" {
		t.AlbumKey = s.AlbumKey
		t.State = "ready"
	}
	e.state.AlbumTargets[id] = t
	e.state.AlbumConfigs[account] = &AlbumConfig{Enabled: true, TargetID: id}
	return e.save()
}
func (e *Engine) enqueueAlbum(j *Job) {
	if j.State != "completed" {
		return
	}
	keys := append([]string(nil), j.MediaKeys...)
	if j.MediaKey != "" {
		keys = appendUnique(keys, j.MediaKey)
	}
	// Older RAW+JPEG jobs kept only the primary key; do not invent the other ID.
	raw := len(j.Resources) == 2 && rawJPEGPair([]string{j.Resources[0].Name, j.Resources[1].Name})
	unresolved := len(keys) == 0 || raw && len(keys) < 2
	for _, targetID := range j.AlbumTargets {
		target := e.state.AlbumTargets[targetID]
		if target == nil || target.Account != j.Account {
			continue
		}
		for _, key := range keys {
			e.addAlbumTask(targetID, key, "")
		}
		if unresolved {
			e.addAlbumTask(targetID, "", j.ID)
		}
	}
}
func (e *Engine) addAlbumTask(target, key, unresolved string) {
	sum := sha256.Sum256([]byte(target + "\x00" + key + "\x00" + unresolved))
	id := hex.EncodeToString(sum[:])
	for _, task := range e.state.AlbumTasks {
		if task.ID == id {
			return
		}
	}
	state := "pending"
	if key == "" {
		state = "unresolved"
	}
	e.state.AlbumTasks = append(e.state.AlbumTasks, &AlbumTask{ID: id, TargetID: target, MediaKey: key, State: state})
}
func (e *Engine) retryAlbum(account string, confirm bool) error {
	// Validate before mutating any tasks. Unknown creates always require recovery
	// with an actual album ID; a retry button must never make another album.
	for _, t := range e.state.AlbumTargets {
		if t.Account == account && t.State == "uncertain" {
			return errors.New("recover the created album ID first")
		}
	}
	for _, task := range e.state.AlbumTasks {
		if e.state.AlbumTargets[task.TargetID].Account == account && task.State == "uncertain" && !confirm {
			return errors.New("confirm retry of uncertain assignments")
		}
	}
	for _, t := range e.state.AlbumTargets {
		if t.Account == account && t.State == "failed" {
			t.State = "pending"
			t.Next = 0
			t.Attempts = 0
			t.Error = ""
		}
	}
	for _, task := range e.state.AlbumTasks {
		if e.state.AlbumTargets[task.TargetID].Account == account && (task.State == "failed" || task.State == "uncertain") {
			task.State = "pending"
			task.Attempts = 0
			task.Next = 0
			task.Error = ""
		}
	}
	return e.save()
}
func (e *Engine) resolveAlbum(account, target, key string) error {
	t := e.state.AlbumTargets[target]
	if t == nil || t.Account != account || t.State != "uncertain" || !validAlbumKey(key) {
		return errRequest
	}
	t.AlbumKey = key
	t.State = "ready"
	t.Error = ""
	return e.save()
}

// Retarget only work explicitly rejected or not yet sent. Preserve confirmed
// assignments and uncertain writes on the old target, and keep a repair trail.
func (e *Engine) repairAlbum(account, target, key string) error {
	old := e.state.AlbumTargets[target]
	if old == nil || old.Account != account || old.AlbumKey == "" || !validAlbumKey(key) || old.AlbumKey == key {
		return errRequest
	}
	found := false
	for _, task := range e.state.AlbumTasks {
		if task.TargetID == target {
			if task.State == "adding" {
				return errRequest
			}
			if task.State == "failed" {
				found = true
			}
		}
	}
	if !found {
		return errRequest
	}
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return err
	}
	id := hex.EncodeToString(bytes[:])
	e.state.AlbumTargets[id] = &AlbumTarget{ID: id, Account: account, Mode: "existing", AlbumKey: key, State: "ready"}
	// Iterate only the existing tasks; addAlbumTask appends new assignments.
	for _, task := range e.state.AlbumTasks {
		if task.TargetID == target && (task.State == "pending" || task.State == "failed") {
			e.addAlbumTask(id, task.MediaKey, "")
			task.State = "superseded"
			task.Error = "target_corrected"
			task.Next = 0
		}
	}
	if c := e.state.AlbumConfigs[account]; c != nil && c.TargetID == target {
		c.TargetID = id
	}
	for _, j := range e.state.Jobs {
		if j.Account == account && j.State != "completed" && j.State != "cancelled" {
			for i, oldTarget := range j.AlbumTargets {
				if oldTarget == target {
					j.AlbumTargets[i] = id
				}
			}
		}
	}
	return e.save()
}
func (e *Engine) tickAlbums() {
	if e.albums == nil || e.albumCancel != nil {
		return
	}
	now := time.Now().Unix()
	for _, target := range e.state.AlbumTargets {
		c := e.state.AlbumConfigs[target.Account]
		if c == nil || !c.Enabled || target.State == "uncertain" || target.State == "failed" || target.Next > now || e.nativeAuthorization(target.Account) == "waiting" {
			continue
		}
		busy := false
		for id, lease := range e.albumImports {
			if lease.Expires <= now {
				delete(e.albumImports, id)
			} else if lease.Account == target.Account {
				busy = true
			}
		}
		for _, j := range e.state.Jobs {
			if j.Account == target.Account && j.State != "completed" && j.State != "failed" && j.State != "cancelled" {
				busy = true
				break
			}
		}
		if busy {
			continue
		}
		batch := []*AlbumTask{}
		for _, task := range e.state.AlbumTasks {
			if task.TargetID == target.ID && task.State == "pending" && task.Next <= now {
				batch = append(batch, task)
				if len(batch) == 500 {
					break
				}
			}
		}
		if len(batch) == 0 {
			continue
		}
		creating := target.AlbumKey == ""
		if creating {
			target.State = "creating"
			target.Attempts++
		} else {
			for _, task := range batch {
				task.State = "adding"
				task.Attempts++
			}
		}
		if e.save() != nil {
			return
		}
		ctx, cancel := context.WithCancel(context.Background())
		e.albumCancel = cancel
		e.albumActiveAccount = target.Account
		e.wg.Add(1)
		snapshot := *target
		go e.executeAlbum(ctx, snapshot, batch, creating)
		return
	}
}
func (e *Engine) executeAlbum(ctx context.Context, target AlbumTarget, batch []*AlbumTask, creating bool) {
	defer e.wg.Done()
	var key string
	var err error
	if creating {
		key, err = e.albums.Create(ctx, target.Account, target.Name)
		if err == nil && !validAlbumKey(key) {
			err = &AlbumFailure{Code: "create_outcome_unknown", Uncertain: true}
		}
	} else {
		keys := make([]string, len(batch))
		for i, t := range batch {
			keys[i] = t.MediaKey
		}
		err = e.albums.Add(ctx, target.Account, target.AlbumKey, keys)
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	e.albumCancel = nil
	e.albumActiveAccount = ""
	t := e.state.AlbumTargets[target.ID]
	if err == nil {
		if creating {
			t.AlbumKey = key
			t.State = "ready"
			t.Error = ""
			t.Next = 0
		} else {
			for _, task := range batch {
				task.State = "completed"
				task.Error = ""
				task.Next = 0
			}
		}
	} else {
		f := albumFailure(err)
		nextState := func(attempts int) (string, int64) {
			if f.Uncertain {
				return "uncertain", 0
			}
			if f.Retryable && attempts <= e.state.Options.Retries {
				return "pending", time.Now().Add(time.Second * time.Duration(1<<min(attempts, 10))).Unix()
			}
			return "failed", 0
		}
		if creating {
			t.State, t.Next = nextState(t.Attempts)
			t.Error = f.Code
		} else {
			for _, task := range batch {
				task.State, task.Next = nextState(task.Attempts)
				task.Error = f.Code
			}
		}
	}
	_ = e.save()
}

// Return compact account-scoped metadata; never return credentials or all jobs.
func (e *Engine) albumView(account string) map[string]any {
	settings := AlbumSettings{Mode: "existing"}
	targetID, resolved, status, code := "", "", "Disabled", ""
	c := e.state.AlbumConfigs[account]
	if c != nil {
		targetID = c.TargetID
		t := e.state.AlbumTargets[targetID]
		settings = AlbumSettings{Enabled: c.Enabled, Mode: t.Mode, Name: t.Name, AlbumKey: t.AlbumKey}
		resolved = t.AlbumKey
		if c.Enabled {
			status = "Waiting"
		}
	}
	counts := map[string]int{"pending": 0, "adding": 0, "completed": 0, "failed": 0, "uncertain": 0, "unresolved": 0}
	uncertainCreates := []map[string]string{}
	repairableTargets := []map[string]string{}
	failedCreates := 0
	adding, failed := false, false
	for _, t := range e.state.AlbumTargets {
		if t.Account == account {
			for _, task := range e.state.AlbumTasks {
				if task.TargetID == t.ID && task.State == "failed" && t.AlbumKey != "" {
					repairableTargets = append(repairableTargets, map[string]string{"targetID": t.ID, "albumKey": t.AlbumKey, "name": t.Name})
					break
				}
			}
			if t.State == "failed" && t.AlbumKey == "" {
				failedCreates++
			}
			if t.State == "creating" {
				adding = true
			}
			if t.State == "uncertain" || t.State == "failed" {
				failed = true
				code = t.Error
			}
			if t.State == "uncertain" {
				uncertainCreates = append(uncertainCreates, map[string]string{"targetID": t.ID, "name": t.Name})
			}
		}
	}
	for _, task := range e.state.AlbumTasks {
		if e.state.AlbumTargets[task.TargetID].Account == account {
			counts[task.State]++
			if task.State == "adding" {
				adding = true
			}
			if task.State == "failed" || task.State == "uncertain" || task.State == "unresolved" {
				failed = true
				code = task.Error
			}
		}
	}
	if c != nil && c.Enabled {
		if counts["pending"] == 0 && counts["completed"] > 0 {
			status = "Completed"
		}
		for _, j := range e.state.Jobs {
			if j.Account == account && (j.State == "preparing" || j.State == "uploading" || j.State == "committing") {
				status = "Uploading"
				break
			}
		}
		if failed {
			status = "Failed"
		}
		if adding {
			status = "Adding to album"
		}
	}
	return map[string]any{"settings": settings, "targetID": targetID, "resolvedAlbumKey": resolved, "status": status, "counts": counts, "error": code, "failedCreates": failedCreates, "uncertainCreates": uncertainCreates, "repairableTargets": repairableTargets}
}
