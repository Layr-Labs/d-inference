package inference_test

import (
	"bytes"
	"context"
	"encoding/json"
	"image"
	"image/png"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/billing"
	infermedia "github.com/eigeninference/d-inference/coordinator/internal/inference/media"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type mediaFixture struct {
	*infermedia.Bridge
	deadline   time.Duration
	onDeadline func()
}

func testMediaBillingServer(t *testing.T, cfg mediafetch.Config) (*serverFixture, *memory.MemoryStore) {
	t.Helper()
	srv, st := testServerWithConfig(t, TestServerConfig{MediaFetch: &cfg})
	srv.bindBilling(billing.NewService(st, srv.ledger, quietLogger(), billing.Config{MockMode: true}))
	return srv, st
}

func newMediaFixture(resolver *mediafetch.Resolver, logger *slog.Logger) *mediaFixture {
	f := &mediaFixture{}
	f.Bridge = infermedia.NewBridge(infermedia.Dependencies{
		Resolver: resolver, Logger: logger, Observation: (*observation.Owner)(nil),
		RecordRemote:    func(*http.Request, map[string]any, string, string, bool) {},
		RecordRejection: func(*http.Request, map[string]any, infermedia.ResolveMeta, int) {},
		Deadline: func(*http.Request, string, string, int) (time.Duration, error) {
			if f.onDeadline != nil {
				f.onDeadline()
			}
			return f.deadline, nil
		},
	})
	return f
}

func minimalMediaServer(cfg mediafetch.Config) *mediaFixture {
	return newMediaFixture(mediafetch.NewResolver(cfg, nil), quietLogger())
}

func (f *mediaFixture) resolveRemoteMedia(w http.ResponseWriter, r *http.Request, raw []byte, parsed map[string]any, timing *registry.RequestTiming, meta infermedia.ResolveMeta) ([]byte, bool, bool) {
	return f.Resolve(w, r, raw, parsed, timing, meta)
}

type mediaSealedKey struct{}

func (f *mediaFixture) gateRemoteMediaPreDispatch(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, vision, tools bool) bool {
	return f.Gate(w, r, parsed, model, publicModel, vision, tools, r.Context().Value(mediaSealedKey{}) != nil)
}

func (f *mediaFixture) mediaFetchRejected(w http.ResponseWriter, r *http.Request, parsed map[string]any, meta infermedia.ResolveMeta, status int, code, message string) {
	f.Rejected(w, r, parsed, meta, status, code, message)
}

func testMeta() infermedia.ResolveMeta {
	return infermedia.ResolveMeta{Model: "test", PublicModel: "test"}
}
func plainReq() *http.Request {
	return httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
}
func sealedReq() *http.Request {
	r := plainReq()
	return r.WithContext(context.WithValue(r.Context(), mediaSealedKey{}, struct{}{}))
}

func mediaSLAAccountRequest(account string) *http.Request {
	r := plainReq()
	return r.WithContext(access.WithConsumer(r.Context(), account))
}

func testPNG(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buf.Bytes()
}

func pngHandler(t *testing.T, hits *int32) http.HandlerFunc {
	img := testPNG(t)
	return func(w http.ResponseWriter, r *http.Request) {
		if hits != nil {
			atomic.AddInt32(hits, 1)
		}
		w.Write(img)
	}
}

func chatBodyBytes(t *testing.T, imageURL string) ([]byte, map[string]any) {
	t.Helper()
	parsed := map[string]any{"model": "test", "messages": []any{map[string]any{"role": "user", "content": []any{
		map[string]any{"type": "image_url", "image_url": map[string]any{"url": imageURL}},
	}}}}
	raw, err := json.Marshal(parsed)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var fresh map[string]any
	if err := json.Unmarshal(raw, &fresh); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	return raw, fresh
}

func errType(t *testing.T, body []byte) string {
	t.Helper()
	var resp struct {
		Error struct {
			Type string `json:"type"`
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("parse error body: %v", err)
	}
	if resp.Error.Code != "" {
		return resp.Error.Code
	}
	return resp.Error.Type
}
