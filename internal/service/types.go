package service

import (
	"context"
	"errors"
)

const MaxMessage = 60000
const MaxChunk = 32768
const MaxJobs = 10000 // Unfinished jobs only; completed/cancelled history preserves deduplication.

type Resource struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
}
type Options struct {
	Quality      string `json:"quality"`
	Concurrent   int    `json:"concurrent"`
	Retries      int    `json:"retries"`
	WiFiOnly     bool   `json:"wifiOnly"`
	ChargingOnly bool   `json:"chargingOnly"`
	Paused       bool   `json:"paused"`
}

func defaults() Options {
	return Options{Quality: "original", Concurrent: 1, Retries: 3, WiFiOnly: true}
}
func (o Options) valid() bool {
	return validQuality(o.Quality) && o.Concurrent >= 1 && o.Concurrent <= 4 && o.Retries >= 0 && o.Retries <= 10
}
func validQuality(q string) bool { return q == "original" || q == "saver" || q == "quota" }

type Job struct {
	RebackupAssetID string     `json:"rebackupAssetID,omitempty"` // Explicit local-photo rebackup; never included in diagnostics.
	MediaKeys       []string   `json:"mediaKeys,omitempty"`
	AlbumTargets    []string   `json:"albumTargets,omitempty"`
	OriginalPolicy  int        `json:"originalPolicy,omitempty"` // 1: original bytes sent without legacy remote-hash shortcut.
	ID              string     `json:"id"`
	Account         string     `json:"account"`
	Quality         string     `json:"quality"`
	State           string     `json:"state"`
	Resources       []Resource `json:"resources"`
	Created         int64      `json:"created"`
	Timestamp       int64      `json:"timestamp"`
	Fingerprint     string     `json:"fingerprint,omitempty"`
	Attempts        int        `json:"attempts"`
	Next            int64      `json:"next,omitempty"`
	Uploaded        int64      `json:"uploaded"`
	Total           int64      `json:"total"`
	Error           string     `json:"error,omitempty"`
	MediaKey        string     `json:"mediaKey,omitempty"`
	CancelRequested bool       `json:"cancelRequested,omitempty"`
	Owner           string     `json:"owner"`
}
type State struct {
	AlbumConfigs       map[string]*AlbumConfig `json:"albumConfigs,omitempty"`
	AlbumTargets       map[string]*AlbumTarget `json:"albumTargets,omitempty"`
	AlbumTasks         []*AlbumTask            `json:"albumTasks,omitempty"`
	CompletionRevision uint64                  `json:"completionRevision,omitempty"`
	Version            int                     `json:"version"`
	Options            Options                 `json:"options"`
	Jobs               []*Job                  `json:"jobs"`
}
type Request struct {
	RebackupAssetID string         `json:"rebackupAssetID,omitempty"`
	Album           *AlbumSettings `json:"album,omitempty"`
	Confirm         bool           `json:"confirm,omitempty"`
	NativeID        string         `json:"nativeID,omitempty"`
	Op              string         `json:"op"`
	ID              string         `json:"id,omitempty"`
	Account         string         `json:"account,omitempty"`
	Secret          string         `json:"secret,omitempty"`
	Quality         string         `json:"quality,omitempty"`
	Resources       []Resource     `json:"resources,omitempty"`
	Index           int            `json:"index,omitempty"`
	Offset          int64          `json:"offset,omitempty"`
	Data            []byte         `json:"data,omitempty"`
	Timestamp       int64          `json:"timestamp,omitempty"`
	Options         *Options       `json:"options,omitempty"`
	Cursor          int            `json:"cursor,omitempty"`
	Online          bool           `json:"online,omitempty"`
	WiFi            bool           `json:"wifi,omitempty"`
	Charging        bool           `json:"charging,omitempty"`
}
type Progress struct {
	MediaKey        string
	State           string
	Uploaded, Total int64
}
type Runner func(context.Context, []string, string, string, func(Progress)) (string, error)

var errRequest = errors.New("invalid request")
