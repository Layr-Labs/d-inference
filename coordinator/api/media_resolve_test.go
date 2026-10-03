package api

import (
	"bytes"
	"image"
	"image/png"
	"net/http"
	"sync/atomic"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// --- helpers ----------------------------------------------------------------

// testPNG returns a real, decodable 2x2 PNG (passes both the sniff allowlist
// and the header pixel gate).
func testPNG(t *testing.T) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewRGBA(image.Rect(0, 0, 2, 2))); err != nil {
		t.Fatalf("encode png: %v", err)
	}
	return buf.Bytes()
}

// pngHandler serves a valid PNG and counts hits (for fetched/not-fetched asserts).
func pngHandler(t *testing.T, hits *int32) http.HandlerFunc {
	img := testPNG(t)
	return func(w http.ResponseWriter, r *http.Request) {
		if hits != nil {
			atomic.AddInt32(hits, 1)
		}
		w.Write(img)
	}
}

// makeVisionRoutableProvider registers an online, routable, vision-capable
// provider for model so a media request clears visionToolsFailFast and reaches
// the remote-media gate/resolution steps the HTTP-path tests below exercise.
// Nil test catalog => IsModelInCatalog/HasVisionProviderForModel allow it.
func makeVisionRoutableProvider(t *testing.T, reg *registry.Registry, id, model string) {
	t.Helper()
	p := makeRoutableProvider(t, reg, id, model)
	p.Mu().Lock()
	for i := range p.Models {
		if p.Models[i].ID == model {
			p.Models[i].IsVision = true
		}
	}
	p.Mu().Unlock()
}

// --- resolveRemoteMedia (phase 2, post-reservation) --------------------------

// --- gateRemoteMediaPreDispatch (phase 1, pre-billing) -----------------------

// --- full HTTP path through srv.Handler() ------------------------------------
