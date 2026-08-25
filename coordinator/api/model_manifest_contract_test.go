package api

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestFetchModelManifestResponseByteContract(t *testing.T) {
	encoded, err := json.Marshal(validTestManifest())
	if err != nil {
		t.Fatal(err)
	}
	if int64(len(encoded)) >= maxModelManifestBytes {
		t.Fatalf("fixture unexpectedly uses %d bytes", len(encoded))
	}

	for _, tc := range []struct {
		name      string
		bodyBytes int64
		wantError bool
	}{
		{name: "exact boundary", bodyBytes: maxModelManifestBytes},
		{name: "one byte over", bodyBytes: maxModelManifestBytes + 1, wantError: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := append([]byte(nil), encoded...)
			body = append(body, bytes.Repeat([]byte(" "), int(tc.bodyBytes)-len(body))...)
			cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				// Flush headers before the body so the client cannot rely on a
				// Content-Length preflight; the streaming bound must hold.
				w.WriteHeader(http.StatusOK)
				if flusher, ok := w.(http.Flusher); ok {
					flusher.Flush()
				}
				_, _ = w.Write(body)
			}))
			defer cdn.Close()

			_, err := fetchModelManifest(t.Context(), cdn.URL, validTestManifest().R2Prefix)
			if tc.wantError && err == nil {
				t.Fatal("expected oversized manifest response to fail")
			}
			if !tc.wantError && err != nil {
				t.Fatalf("exact-boundary manifest failed: %v", err)
			}
		})
	}
}

func TestValidateModelManifestRejectsSizeAndCountLies(t *testing.T) {
	prefix := modelR2Prefix("mlx-community/test", "v1")
	tests := []struct {
		name        string
		mutate      func(*store.ModelManifest)
		wantInError string
	}{
		{
			name: "negative per-file size",
			mutate: func(manifest *store.ModelManifest) {
				manifest.Files[0].SizeBytes = -1
				manifest.TotalSizeBytes = 0
			},
			wantInError: "must be nonnegative",
		},
		{
			name: "negative aggregate size",
			mutate: func(manifest *store.ModelManifest) {
				manifest.TotalSizeBytes = -1
			},
			wantInError: "total_size_bytes must be nonnegative",
		},
		{
			name: "aggregate size overflow",
			mutate: func(manifest *store.ModelManifest) {
				manifest.Files = []store.ManifestFile{
					{Path: "a.bin", SizeBytes: math.MaxInt64, SHA256: testHash, Role: "weight"},
					{Path: "b.bin", SizeBytes: 1, SHA256: testHash, Role: "weight"},
				}
				manifest.FileCount = len(manifest.Files)
				manifest.TotalSizeBytes = math.MaxInt64
				manifest.AggregateSHA256 = aggregateManifestFileHashes(manifest.Files)
			},
			wantInError: "overflow",
		},
		{
			name: "declared file count over limit",
			mutate: func(manifest *store.ModelManifest) {
				manifest.FileCount = maxModelManifestFileCount + 1
			},
			wantInError: "file_count exceeds limit",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			manifest := validTestManifest()
			tc.mutate(manifest)
			err := validateModelManifest(manifest, manifest.ModelID, manifest.Version, prefix)
			if err == nil || !strings.Contains(err.Error(), tc.wantInError) {
				t.Fatalf("error = %v, want substring %q", err, tc.wantInError)
			}
		})
	}
}

func TestRegisterModelRejectsInvalidManifestFromHTTP(t *testing.T) {
	tests := []struct {
		name       string
		mutate     func(*store.ModelManifest)
		wantInBody string
	}{
		{
			name: "file count",
			mutate: func(manifest *store.ModelManifest) {
				manifest.FileCount = maxModelManifestFileCount + 1
			},
			wantInBody: "file_count exceeds limit",
		},
		{
			name: "negative size",
			mutate: func(manifest *store.ModelManifest) {
				manifest.Files[0].SizeBytes = -1
				manifest.TotalSizeBytes = 0
			},
			wantInBody: "size_bytes must be nonnegative",
		},
		{
			name: "aggregate overflow",
			mutate: func(manifest *store.ModelManifest) {
				manifest.Files = []store.ManifestFile{
					{Path: "a.bin", SizeBytes: math.MaxInt64, SHA256: testHash, Role: "weight"},
					{Path: "b.bin", SizeBytes: 1, SHA256: testHash, Role: "weight"},
				}
				manifest.FileCount = 2
				manifest.TotalSizeBytes = math.MaxInt64
				manifest.AggregateSHA256 = aggregateManifestFileHashes(manifest.Files)
			},
			wantInBody: "overflow",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			manifest := validTestManifest()
			tc.mutate(manifest)
			cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				writeJSON(w, http.StatusOK, manifest)
			}))
			defer cdn.Close()

			coordinator := newManifestRegistrationTestServer(t, cdn.URL)
			defer coordinator.Close()
			status, body := postTestModelRegistration(t, coordinator.URL)
			if status != http.StatusBadRequest || !strings.Contains(body, tc.wantInBody) {
				t.Fatalf("status=%d body=%s, want 400 containing %q", status, body, tc.wantInBody)
			}
		})
	}
}

func TestRegisterModelUnknownHEADLengthUsesBoundedGET(t *testing.T) {
	for _, tc := range []struct {
		name       string
		actualBody []byte
		wantStatus int
		wantInBody string
	}{
		{name: "matching bytes", actualBody: []byte("abc"), wantStatus: http.StatusOK},
		{
			name:       "one byte too many",
			actualBody: []byte("abcd"),
			wantStatus: http.StatusBadRequest,
			wantInBody: "body size 4 != manifest size 3",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			manifest := validTestManifest()
			manifest.Files[0].SizeBytes = 3
			manifest.TotalSizeBytes = 3
			var getCount atomic.Int32

			cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/" + manifest.R2Prefix + "/manifest.json":
					writeJSON(w, http.StatusOK, manifest)
				case "/" + manifest.R2Prefix + "/" + manifest.Files[0].Path:
					if r.Method == http.MethodGet {
						getCount.Add(1)
					}
					writeUnknownLengthResponse(w, r.Method, tc.actualBody)
				default:
					http.NotFound(w, r)
				}
			}))
			defer cdn.Close()

			coordinator := newManifestRegistrationTestServer(t, cdn.URL)
			defer coordinator.Close()
			status, body := postTestModelRegistration(t, coordinator.URL)
			if status != tc.wantStatus || !strings.Contains(body, tc.wantInBody) {
				t.Fatalf("status=%d body=%s, want status=%d containing %q", status, body, tc.wantStatus, tc.wantInBody)
			}
			if getCount.Load() != 1 {
				t.Fatalf("bounded fallback GET count = %d, want 1", getCount.Load())
			}
		})
	}
}

func TestRegisterModelRejectsUnknownLengthAboveGETBound(t *testing.T) {
	manifest := validTestManifest()
	manifest.Files[0].SizeBytes = maxUnknownLengthFileVerificationBytes + 1
	manifest.TotalSizeBytes = manifest.Files[0].SizeBytes
	var getCount atomic.Int32

	cdn := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/" + manifest.R2Prefix + "/manifest.json":
			writeJSON(w, http.StatusOK, manifest)
		case "/" + manifest.R2Prefix + "/" + manifest.Files[0].Path:
			if r.Method == http.MethodGet {
				getCount.Add(1)
			}
			writeUnknownLengthResponse(w, r.Method, nil)
		default:
			http.NotFound(w, r)
		}
	}))
	defer cdn.Close()

	coordinator := newManifestRegistrationTestServer(t, cdn.URL)
	defer coordinator.Close()
	status, body := postTestModelRegistration(t, coordinator.URL)
	if status != http.StatusBadRequest || !strings.Contains(body, "exceeds bounded GET verification limit") {
		t.Fatalf("status=%d body=%s", status, body)
	}
	if getCount.Load() != 0 {
		t.Fatalf("fallback GET count = %d, want 0", getCount.Load())
	}
}

func newManifestRegistrationTestServer(t *testing.T, cdnURL string) *httptest.Server {
	t.Helper()
	t.Setenv("MODEL_REGISTRY_CDN_BASE_URL", cdnURL)
	t.Setenv("MODEL_REGISTRY_PUBLISHING_KEY", "publish-secret")
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	return httptest.NewServer(srv.Handler())
}

func postTestModelRegistration(t *testing.T, coordinatorURL string) (int, string) {
	t.Helper()
	payload := map[string]any{
		"model_id":           "mlx-community/test",
		"version":            "v1",
		"display_name":       "Test Model",
		"family":             "qwen",
		"architecture":       "dense",
		"quantization":       "4bit",
		"max_context_length": 32768,
		"max_output_length":  8192,
		"min_ram_gb":         16,
		"capabilities":       []string{"chat"},
		"input_price":        50000,
		"output_price":       200000,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodPost, coordinatorURL+"/v1/admin/models/register", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer publish-secret")
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return resp.StatusCode, string(responseBody)
}

func writeUnknownLengthResponse(w http.ResponseWriter, method string, body []byte) {
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijacking unavailable", http.StatusInternalServerError)
		return
	}
	conn, rw, err := hijacker.Hijack()
	if err != nil {
		return
	}
	defer conn.Close()
	_, _ = rw.WriteString("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
	if method != http.MethodHead {
		_, _ = rw.Write(body)
	}
	_ = rw.Flush()
}
