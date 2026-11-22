package backend

import (
	"context"
	"errors"
	"google.golang.org/protobuf/encoding/protowire"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func listBytes(n protowire.Number, b []byte) []byte {
	return protowire.AppendBytes(protowire.AppendTag(nil, n, protowire.BytesType), b)
}
func TestGunshotAlbumList(t *testing.T) {
	defer GunshotSetNativeBearerProvider(nil)
	GunshotSetNativeBearerProvider(func(string) (string, error) { return "fixture", nil })
	api, _ := newAPIFromCredential("Email=a%40example.com&gunshot_native_id=fixture", "")
	meta := listBytes(5, []byte("Holiday"))
	meta = protowire.AppendTag(meta, 7, protowire.VarintType)
	meta = protowire.AppendVarint(meta, 12)
	rec := append(listBytes(1, []byte("AF1Qip-test")), listBytes(2, meta)...)
	envelope := append(listBytes(1, []byte("next")), listBytes(3, rec)...)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(listBytes(1, envelope)) }))
	defer server.Close()
	c := &GunshotAlbumClient{api: api, listEndpoint: server.URL}
	page, err := c.List(context.Background(), "")
	if err != nil || page.Next != "next" || len(page.Albums) != 1 || page.Albums[0].AlbumKey != "AF1Qip-test" || page.Albums[0].Name != "Holiday" || page.Albums[0].Count != 12 {
		t.Fatalf("bad page: %+v %v", page, err)
	}
}

func TestGunshotAlbumListMalformedAndDuplicates(t *testing.T) {
	record := func(key string, meta []byte) []byte { return append(listBytes(1, []byte(key)), listBytes(2, meta)...) }
	valid := record("AF1Qip-one", nil)
	cases := []struct {
		name string
		data []byte
		want int
		bad  bool
	}{
		{"empty", listBytes(1, nil), 0, false},
		{"duplicate", listBytes(1, append(listBytes(3, valid), listBytes(3, valid)...)), 1, false},
		{"truncated", []byte{10, 5, 1}, 0, true},
		{"wrong collection type", listBytes(1, []byte{24, 1}), 0, true},
		{"short key", listBytes(1, listBytes(3, record("AF1Qip-x", nil))), 0, true},
		{"long key", listBytes(1, listBytes(3, record("AF1Qip-"+strings.Repeat("x", 506), nil))), 0, true},
		{"long title", listBytes(1, listBytes(3, record("AF1Qip-one", listBytes(5, []byte(strings.Repeat("x", 4097)))))), 0, true},
		{"nul title", listBytes(1, listBytes(3, record("AF1Qip-one", listBytes(5, []byte{0})))), 0, true},
		{"invalid key", listBytes(1, listBytes(3, record("bad", nil))), 0, true},
		{"invalid title", listBytes(1, listBytes(3, record("AF1Qip-one", listBytes(5, []byte{255})))), 0, true},
		{"wrong count type", listBytes(1, listBytes(3, record("AF1Qip-one", listBytes(7, nil)))), 0, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p, err := parseAlbumList(tc.data)
			if (err != nil) != tc.bad || (!tc.bad && len(p.Albums) != tc.want) {
				t.Fatalf("page %+v, error %v", p, err)
			}
		})
	}
}

func TestGunshotAlbumListRequestAndFailures(t *testing.T) {
	defer GunshotSetNativeBearerProvider(nil)
	GunshotSetNativeBearerProvider(func(string) (string, error) { return "fixture", nil })
	api, _ := newAPIFromCredential("Email=a%40example.com&gunshot_native_id=fixture", "")
	status := 200
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var envelope []byte
		if !walkList(body, func(n protowire.Number, k protowire.Type, b []byte, _ uint64) bool {
			if n == 1 {
				envelope = b
			}
			return true
		}) {
			t.Error("invalid request")
		}
		var gotToken bool
		if !walkList(envelope, func(n protowire.Number, k protowire.Type, b []byte, _ uint64) bool {
			if n == 1 {
				t.Error("media requested")
			}
			if n == 6 {
				t.Error("initial cursor included in continuation")
			}
			if n == 4 && string(b) == "resume" {
				gotToken = true
			}
			return true
		}) || !gotToken {
			t.Error("missing continuation")
		}
		w.WriteHeader(status)
		if status == 200 {
			w.Write(listBytes(1, nil))
		} else {
			w.Write([]byte("sensitive body"))
		}
	}))
	defer server.Close()
	c := &GunshotAlbumClient{api: api, listEndpoint: server.URL}
	if _, err := c.List(context.Background(), "resume"); err != nil {
		t.Fatal(err)
	}
	var e *GunshotAlbumError
	for _, status = range []int{400, 401, 403, 429, 503} {
		_, err := c.List(context.Background(), "resume")
		if !errors.As(err, &e) || !e.Retryable || e.Uncertain || strings.Contains(err.Error(), "sensitive") || strings.Contains(err.Error(), "fixture") {
			t.Fatalf("unsafe error: %v", err)
		}
	}
	status = 200
	_, err := c.List(context.Background(), strings.Repeat("x", 8193))
	if !errors.As(err, &e) || !e.Retryable || e.Uncertain {
		t.Fatal("oversize token accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = c.List(ctx, "resume")
	if !errors.As(err, &e) || !e.Retryable || e.Uncertain {
		t.Fatalf("bad cancellation: %v", err)
	}
}

func TestGunshotAlbumListOversizeResponse(t *testing.T) {
	defer GunshotSetNativeBearerProvider(nil)
	GunshotSetNativeBearerProvider(func(string) (string, error) { return "fixture", nil })
	api, _ := newAPIFromCredential("Email=a%40example.com&gunshot_native_id=fixture", "")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.Copy(w, io.LimitReader(strings.NewReader(strings.Repeat("x", (2<<20)+1)), (2<<20)+1))
	}))
	defer server.Close()
	_, err := (&GunshotAlbumClient{api: api, listEndpoint: server.URL}).List(context.Background(), "")
	var failure *GunshotAlbumError
	if !errors.As(err, &failure) || !failure.Retryable || failure.Uncertain || strings.Contains(err.Error(), "fixture") {
		t.Fatalf("unsafe oversized response error: %v", err)
	}
}
