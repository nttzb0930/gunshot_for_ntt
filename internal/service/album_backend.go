package service

import (
	"app/backend"
	"context"
	"errors"
)

type remoteAlbums struct{}

func albumBackendError(err error) error {
	if err == nil {
		return nil
	}
	var f *backend.GunshotAlbumError
	if errors.As(err, &f) {
		return &AlbumFailure{Code: f.Code, Retryable: f.Retryable, Uncertain: f.Uncertain}
	}
	return &AlbumFailure{Code: "album_outcome_unknown", Uncertain: true}
}
func (remoteAlbums) Create(ctx context.Context, account, name string) (string, error) {
	c, err := backend.NewGunshotAlbumClient(account)
	if err != nil {
		return "", albumBackendError(err)
	}
	key, err := c.Create(ctx, name)
	return key, albumBackendError(err)
}
func (remoteAlbums) Add(ctx context.Context, account, key string, keys []string) error {
	c, err := backend.NewGunshotAlbumClient(account)
	if err != nil {
		return albumBackendError(err)
	}
	return albumBackendError(c.Add(ctx, key, keys))
}

func (remoteAlbums) List(ctx context.Context, account, token string) (backend.GunshotAlbumPage, error) {
	c, err := backend.NewGunshotAlbumClient(account)
	if err != nil {
		return backend.GunshotAlbumPage{}, albumBackendError(err)
	}
	p, err := c.List(ctx, token)
	return p, albumBackendError(err)
}
