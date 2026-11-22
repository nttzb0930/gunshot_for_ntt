package backend

import (
	"app/generated"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"google.golang.org/protobuf/proto"
)

func TestGunshotAlbumWireAndErrors(t *testing.T) {
	defer GunshotSetNativeBearerProvider(nil)
	GunshotSetNativeBearerProvider(func(string) (string, error) { return "fixture", nil })
	api, err := newAPIFromCredential("Email=a%40example.com&gunshot_native_id=fixture", "")
	if err != nil {
		t.Fatal(err)
	}
	for _, status := range []int{200, 400, 403, 429, 503} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body generated.AddMediaToAlbum
				b, _ := io.ReadAll(r.Body)
				if proto.Unmarshal(b, &body) != nil || body.GetAlbumMediaKey() != "AF1Qip-target" || len(body.GetMediaKeys()) != 2 || r.Header.Get("Authorization") != "Bearer fixture" {
					t.Error("invalid album wire request")
				}
				w.WriteHeader(status)
			}))
			defer server.Close()
			client := &GunshotAlbumClient{api: api, addEndpoint: server.URL}
			err := client.Add(context.Background(), "AF1Qip-target", []string{"one", "two"})
			if status == 200 {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			var failure *GunshotAlbumError
			if !errors.As(err, &failure) {
				t.Fatal("unclassified album failure")
			}
			if failure.Retryable != (status == 429) || failure.Uncertain != (status >= 500) {
				t.Fatalf("unsafe classification: %+v", failure)
			}
		})
	}
}
func TestGunshotAlbumMalformedCreateIsUncertain(t *testing.T) {
	defer GunshotSetNativeBearerProvider(nil)
	GunshotSetNativeBearerProvider(func(string) (string, error) { return "fixture", nil })
	api, _ := newAPIFromCredential("Email=a%40example.com&gunshot_native_id=fixture", "")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body generated.CreateAlbum
		b, _ := io.ReadAll(r.Body)
		if proto.Unmarshal(b, &body) != nil || body.GetAlbumName() != "My album" {
			t.Error("invalid create body")
		}
		w.Write([]byte{255})
	}))
	defer server.Close()
	client := &GunshotAlbumClient{api: api, createEndpoint: server.URL}
	_, err := client.Create(context.Background(), "My album")
	var failure *GunshotAlbumError
	if !errors.As(err, &failure) || !failure.Uncertain {
		t.Fatal("blind create retry possible")
	}
}

func TestGunshotAlbumLostResponseAndCancelledRequest(t *testing.T) {
	defer GunshotSetNativeBearerProvider(nil)
	GunshotSetNativeBearerProvider(func(string) (string, error) { return "fixture", nil })
	api, _ := newAPIFromCredential("Email=a%40example.com&gunshot_native_id=fixture", "")
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		connection, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		connection.Close()
	}))
	defer server.Close()
	client := &GunshotAlbumClient{api: api, addEndpoint: server.URL}
	err := client.Add(context.Background(), "AF1Qip-target", []string{"media"})
	var f *GunshotAlbumError
	if !errors.As(err, &f) || !f.Uncertain || calls.Load() != 1 {
		t.Fatal("network loss retried a remote write")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err = client.Add(ctx, "AF1Qip-target", []string{"media"})
	if !errors.As(err, &f) || !f.Retryable || f.Uncertain || calls.Load() != 1 {
		t.Fatal("unsent cancellation did not remain retryable")
	}
}

func TestGunshotAlbumCreateReturnsVerifiedKey(t *testing.T) {
	defer GunshotSetNativeBearerProvider(nil)
	GunshotSetNativeBearerProvider(func(string) (string, error) { return "fixture", nil })
	api, _ := newAPIFromCredential("Email=a%40example.com&gunshot_native_id=fixture", "")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := proto.Marshal(&generated.CreateAlbumResponse{Field1: &generated.CreateAlbumResponseField1Type{AlbumMediaKey: "AF1Qip-created"}})
		w.Write(data)
	}))
	defer server.Close()
	client := &GunshotAlbumClient{api: api, createEndpoint: server.URL}
	key, err := client.Create(context.Background(), "My album")
	if err != nil || key != "AF1Qip-created" {
		t.Fatalf("missing returned key: %q %v", key, err)
	}
}
