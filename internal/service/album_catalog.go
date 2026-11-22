package service

import (
	"app/backend"
	"context"
	"encoding/json"
	"errors"
	"time"
)

type AlbumLister interface {
	List(context.Context, string, string) (backend.GunshotAlbumPage, error)
}
type albumCatalog struct {
	state  string
	albums []backend.GunshotAlbumEntry
	err    string
	cancel context.CancelFunc
}
type catalogResponse struct {
	State  string                      `json:"state"`
	Albums []backend.GunshotAlbumEntry `json:"albums"`
	Next   int                         `json:"next"`
	Error  string                      `json:"error"`
}

// Called with e.mu held; network and native authorization run in the worker.
func (e *Engine) catalogView(account string, cursor int, refresh bool) (catalogResponse, error) {
	if cursor < 0 {
		return catalogResponse{}, errRequest
	}
	if e.catalogs == nil {
		e.catalogs = make(map[string]*albumCatalog)
	}
	c := e.catalogs[account]
	if c == nil || (refresh && c.state != "loading") {
		if e.stopped {
			return catalogResponse{}, errRequest
		}
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		c = &albumCatalog{state: "loading", cancel: cancel}
		e.catalogs[account] = c
		l := e.catalogLister
		if l == nil {
			l, _ = e.albums.(AlbumLister)
		}
		e.wg.Add(1)
		go e.loadCatalog(ctx, account, c, l)
	}
	result := catalogResponse{State: c.state, Albums: []backend.GunshotAlbumEntry{}, Next: -1, Error: c.err}
	if c.state != "ready" {
		if cursor != 0 {
			return catalogResponse{}, errRequest
		}
		return result, nil
	}
	if cursor > len(c.albums) {
		return catalogResponse{}, errRequest
	}
	end := cursor
	for end < len(c.albums) && end-cursor < 50 {
		candidate := catalogResponse{State: c.state, Albums: c.albums[cursor : end+1], Next: end + 1}
		data, _ := json.Marshal(map[string]any{"ok": true, "data": candidate})
		if len(data) > MaxMessage {
			break
		}
		end++
	}
	if end == cursor && end < len(c.albums) {
		return catalogResponse{State: "failed", Albums: []backend.GunshotAlbumEntry{}, Next: -1, Error: "album_catalog_too_large"}, nil
	}
	result.Albums = c.albums[cursor:end]
	if end < len(c.albums) {
		result.Next = end
	}
	return result, nil
}
func (e *Engine) loadCatalog(ctx context.Context, account string, c *albumCatalog, l AlbumLister) {
	defer e.wg.Done()
	defer c.cancel()
	var albums []backend.GunshotAlbumEntry
	var err error
	seen := map[string]bool{"": true}
	albumKeys := map[string]bool{}
	token := ""
	if l == nil {
		err = errors.New("unavailable")
	} else {
		for page := 0; page < 100; page++ {
			var p backend.GunshotAlbumPage
			p, err = l.List(ctx, account, token)
			if err != nil {
				break
			}
			for _, album := range p.Albums {
				if !albumKeys[album.AlbumKey] {
					albumKeys[album.AlbumKey] = true
					albums = append(albums, album)
				}
			}
			if len(albums) > 5000 {
				err = errors.New("limit")
				break
			}
			if p.Next == "" {
				break
			}
			if seen[p.Next] || page == 99 {
				err = errors.New("limit")
				break
			}
			seen[p.Next] = true
			token = p.Next
		}
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if err != nil {
		c.state = "failed"
		c.err = "album_catalog_failed"
		return
	}
	c.albums = albums
	c.state = "ready"
}

// Called under e.mu after credentials are removed or a native binding changes.
// Detached workers can finish only into their old, unreachable catalog objects.
func (e *Engine) clearAlbumCatalog(account string) {
	for key, c := range e.catalogs {
		if account == "" || key == account {
			c.cancel()
			delete(e.catalogs, key)
		}
	}
}
