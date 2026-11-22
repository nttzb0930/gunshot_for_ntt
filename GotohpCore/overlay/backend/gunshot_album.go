package backend

import (
	"app/generated"
	"bytes"
	"context"
	"io"
	"net/http"
	"time"

	"google.golang.org/protobuf/encoding/protowire"
	"google.golang.org/protobuf/proto"
)

// Errors deliberately contain no response body, URL, account or credential.
type GunshotAlbumError struct {
	Code                 string
	Retryable, Uncertain bool
}

func (e *GunshotAlbumError) Error() string { return e.Code }

type GunshotAlbumClient struct {
	api                                       *Api
	createEndpoint, addEndpoint, listEndpoint string
}

func NewGunshotAlbumClient(account string) (*GunshotAlbumClient, error) {
	api, err := NewApi(ApiOptions{Account: account})
	if err != nil {
		return nil, &GunshotAlbumError{Code: "album_authorization_unavailable", Retryable: true}
	}
	return &GunshotAlbumClient{api: api}, nil
}
func (c *GunshotAlbumClient) request(ctx context.Context, url string, message proto.Message) ([]byte, error) {
	if ctx.Err() != nil {
		return nil, &GunshotAlbumError{Code: "album_paused", Retryable: true}
	}
	body, err := proto.Marshal(message)
	if err != nil {
		return nil, &GunshotAlbumError{Code: "album_request_invalid"}
	}
	bearer, err := c.api.BearerToken()
	if err != nil {
		return nil, &GunshotAlbumError{Code: "album_authorization_unavailable", Retryable: true}
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, &GunshotAlbumError{Code: "album_request_invalid"}
	}
	for k, v := range map[string]string{"Content-Type": "application/x-protobuf", "User-Agent": c.api.userAgent, "Accept-Language": c.api.language, "Authorization": "Bearer " + bearer, "x-goog-ext-173412678-bin": "CgcIAhClARgC", "x-goog-ext-174067345-bin": "CgIIAg=="} {
		req.Header.Set(k, v)
	}
	// Issue one bounded request. Never automatically repeat an ambiguous write.
	client := &http.Client{Transport: c.api.client.Transport, Timeout: 65 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	resp, err := client.Do(req)
	if err != nil {
		return nil, &GunshotAlbumError{Code: "album_outcome_unknown", Uncertain: true}
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		code := "album_rejected"
		switch resp.StatusCode {
		case 400:
			code = "album_invalid_request_or_id"
		case 401:
			code = "album_authorization_expired"
		case 403:
			code = "album_access_denied"
		case 404:
			code = "album_not_found_or_inaccessible"
		case 429:
			code = "album_rate_limited"
		}
		return nil, &GunshotAlbumError{Code: code, Retryable: resp.StatusCode == 429, Uncertain: resp.StatusCode >= 500}
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (2<<20)+1))
	if err != nil || len(data) > 2<<20 {
		return nil, &GunshotAlbumError{Code: "album_outcome_unknown", Uncertain: true}
	}
	return data, nil
}
func (c *GunshotAlbumClient) Create(ctx context.Context, name string) (string, error) {
	endpoint := c.createEndpoint
	if endpoint == "" {
		endpoint = "https://photosdata-pa.googleapis.com/6439526531001121323/8386163679468898444"
	}
	data, err := c.request(ctx, endpoint, &generated.CreateAlbum{AlbumName: name, Timestamp: time.Now().Unix(), Field3: 1, Field6: &generated.CreateAlbumField6Type{}, Field7: &generated.CreateAlbumField7Type{Field1: 3}, DeviceInfo: &generated.CreateAlbumField8Type{Model: c.api.model, Make: c.api.make, AndroidApiVersion: c.api.androidAPIVersion}})
	if err != nil {
		return "", err
	}
	var reply generated.CreateAlbumResponse
	if proto.Unmarshal(data, &reply) != nil || reply.GetField1().GetAlbumMediaKey() == "" {
		return "", &GunshotAlbumError{Code: "create_outcome_unknown", Uncertain: true}
	}
	return reply.GetField1().GetAlbumMediaKey(), nil
}
func (c *GunshotAlbumClient) Add(ctx context.Context, album string, keys []string) error {
	if len(keys) == 0 || len(keys) > 500 {
		return &GunshotAlbumError{Code: "album_batch_invalid"}
	}
	endpoint := c.addEndpoint
	if endpoint == "" {
		endpoint = "https://photosdata-pa.googleapis.com/6439526531001121323/484917746253879292"
	}
	data, err := c.request(ctx, endpoint, &generated.AddMediaToAlbum{MediaKeys: keys, AlbumMediaKey: album, Field5: &generated.AddMediaToAlbumField5Type{Field1: 2}, DeviceInfo: &generated.AddMediaToAlbumField6Type{Model: c.api.model, Make: c.api.make, AndroidApiVersion: c.api.androidAPIVersion}, Timestamp: time.Now().Unix()})
	if err != nil {
		return err
	}
	// Match the pinned upstream's HTTP acknowledgement contract. Validate wire
	// encoding but do not invent private per-item response fields or counts.
	for len(data) > 0 {
		number, kind, n := protowire.ConsumeTag(data)
		if n < 0 {
			return &GunshotAlbumError{Code: "add_outcome_unknown", Uncertain: true}
		}
		data = data[n:]
		n = protowire.ConsumeFieldValue(number, kind, data)
		if n < 0 {
			return &GunshotAlbumError{Code: "add_outcome_unknown", Uncertain: true}
		}
		data = data[n:]
	}
	return nil
}
