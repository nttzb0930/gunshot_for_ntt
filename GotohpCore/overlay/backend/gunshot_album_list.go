package backend

import (
	"bytes"
	"context"
	"encoding/base64"
	"google.golang.org/protobuf/encoding/protowire"
	"io"
	"math"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

type GunshotAlbumEntry struct {
	AlbumKey string `json:"albumKey"`
	Name     string `json:"name"`
	Count    int64  `json:"count"`
}
type GunshotAlbumPage struct {
	Albums []GunshotAlbumEntry
	Next   string
}

// Reduced collections-only mask derived from gpmc commit
// 94b1b267ca6819da542d4330a7dd216747eb0437 and verified against the service.
// Envelope field 2 selects collections; fields 7 and 11 set options.
// Root field 2 carries additional library-state request settings.
const albumListMask = "Co4BEoUBCisSABoAIgAqADIMCgASABoAIgAqADoAOgBCAFIAYgBqBBIAGgB6AgoAkgEAIgIKAEoAWgwKCgoAIgAqADIASgByJAoiCh4KABIIEgYKAgoAGgAaECIGCgIKABoAKgYKAgoAGgASAIoBAJIBBgoAEgIKAKIBBhIECgASALIBALoBAMIBADIAOAJYAhIMCggKBgoCCgASABIA"

func listFailure(code string) error { return &GunshotAlbumError{Code: code, Retryable: true} }
func appendListBytes(dst []byte, n protowire.Number, b []byte) []byte {
	dst = protowire.AppendTag(dst, n, protowire.BytesType)
	return protowire.AppendBytes(dst, b)
}
func (c *GunshotAlbumClient) List(ctx context.Context, token string) (GunshotAlbumPage, error) {
	empty := GunshotAlbumPage{}
	if ctx.Err() != nil {
		return empty, listFailure("album_paused")
	}
	if len(token) > 8192 || !utf8.ValidString(token) {
		return empty, listFailure("album_list_invalid")
	}
	mask, _ := base64.StdEncoding.DecodeString(albumListMask)
	// The first field is the request envelope; append the continuation within it.
	_, _, n := protowire.ConsumeTag(mask)
	envelope, m := protowire.ConsumeBytes(mask[n:])
	tail := mask[n+m:]
	body := mask
	if token != "" {
		// Field 6 selects an initial page and must be omitted when resuming.
		var resumed []byte
		for len(envelope) > 0 {
			field, kind, tagLen := protowire.ConsumeTag(envelope)
			valueLen := protowire.ConsumeFieldValue(field, kind, envelope[tagLen:])
			size := tagLen + valueLen
			if field != 6 {
				resumed = append(resumed, envelope[:size]...)
			}
			envelope = envelope[size:]
		}
		envelope = appendListBytes(resumed, 4, []byte(token))
		body = appendListBytes(nil, 1, envelope)
		body = append(body, tail...)
	}
	bearer, err := c.api.BearerToken()
	if err != nil {
		return empty, listFailure("album_authorization_unavailable")
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	endpoint := c.listEndpoint
	if endpoint == "" {
		endpoint = "https://photosdata-pa.googleapis.com/6439526531001121323/18047484249733410717"
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return empty, listFailure("album_request_invalid")
	}
	for k, v := range map[string]string{"Content-Type": "application/x-protobuf", "User-Agent": c.api.userAgent, "Accept-Language": c.api.language, "Authorization": "Bearer " + bearer, "x-goog-ext-173412678-bin": "CgcIAhClARgC", "x-goog-ext-174067345-bin": "CgIIAg=="} {
		req.Header.Set(k, v)
	}
	client := &http.Client{Transport: c.api.client.Transport, Timeout: 65 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	resp, err := client.Do(req)
	if err != nil {
		return empty, listFailure("album_list_unavailable")
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		code := "album_list_unavailable"
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
		return empty, listFailure(code)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (2<<20)+1))
	if err != nil || len(data) > 2<<20 {
		return empty, listFailure("album_list_unavailable")
	}
	page, err := parseAlbumList(data)
	if err != nil {
		return empty, listFailure("album_list_invalid")
	}
	return page, nil
}

// walkList validates all wire fields, including unknown fields, before visiting them.
func walkList(data []byte, visit func(protowire.Number, protowire.Type, []byte, uint64) bool) bool {
	for len(data) > 0 {
		num, typ, n := protowire.ConsumeTag(data)
		if n < 0 || num < 1 {
			return false
		}
		data = data[n:]
		var b []byte
		var v uint64
		switch typ {
		case protowire.BytesType:
			b, n = protowire.ConsumeBytes(data)
		case protowire.VarintType:
			v, n = protowire.ConsumeVarint(data)
		case protowire.Fixed32Type, protowire.Fixed64Type:
			n = protowire.ConsumeFieldValue(num, typ, data)
		default:
			return false
		}
		if n < 0 {
			return false
		}
		data = data[n:]
		if !visit(num, typ, b, v) {
			return false
		}
	}
	return true
}
func parseAlbumList(data []byte) (GunshotAlbumPage, error) {
	page := GunshotAlbumPage{Albums: []GunshotAlbumEntry{}}
	seen := map[string]bool{}
	root := false
	ok := walkList(data, func(n protowire.Number, t protowire.Type, b []byte, _ uint64) bool {
		if n != 1 {
			return true
		}
		if t != protowire.BytesType || root {
			return false
		}
		root = true
		nextSeen := false
		return walkList(b, func(n protowire.Number, t protowire.Type, b []byte, _ uint64) bool {
			switch n {
			case 1:
				if t != protowire.BytesType || nextSeen || len(b) > 8192 || !utf8.Valid(b) {
					return false
				}
				nextSeen = true
				page.Next = string(b)
			case 3:
				if t != protowire.BytesType {
					return false
				}
				entry := GunshotAlbumEntry{}
				keySeen, metaSeen := false, false
				if !walkList(b, func(n protowire.Number, t protowire.Type, b []byte, _ uint64) bool {
					switch n {
					case 1:
						if t != protowire.BytesType || keySeen || len(b) > 512 || !utf8.Valid(b) {
							return false
						}
						keySeen = true
						entry.AlbumKey = string(b)
					case 2:
						if t != protowire.BytesType || metaSeen {
							return false
						}
						metaSeen = true
						titleSeen, countSeen := false, false
						return walkList(b, func(n protowire.Number, t protowire.Type, b []byte, v uint64) bool {
							switch n {
							case 5:
								if t != protowire.BytesType || titleSeen || len(b) > 4096 || bytes.IndexByte(b, 0) >= 0 || !utf8.Valid(b) {
									return false
								}
								titleSeen = true
								entry.Name = string(b)
							case 7:
								if t != protowire.VarintType || countSeen || v > math.MaxInt64 {
									return false
								}
								countSeen = true
								entry.Count = int64(v)
							}
							return true
						})
					}
					return true
				}) || !keySeen || !metaSeen || !validAlbumListKey(entry.AlbumKey) {
					return false
				}
				if !seen[entry.AlbumKey] {
					seen[entry.AlbumKey] = true
					page.Albums = append(page.Albums, entry)
				}
			}
			return true
		})
	})
	if !ok || !root {
		return GunshotAlbumPage{}, listFailure("album_list_invalid")
	}
	return page, nil
}
func validAlbumListKey(s string) bool {
	if !strings.HasPrefix(s, "AF1Qip") || len(s) < 10 || len(s) > 512 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}
