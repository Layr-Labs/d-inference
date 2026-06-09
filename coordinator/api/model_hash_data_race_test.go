package api

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestHandlersDoNotRaceModelHashRefresh is a data-race regression for the
// stale-model-hash heal path at the HTTP layer. UpdateModelWeightHashes replaces
// Provider.Models copy-on-write under p.mu only (it holds r.mu just as a read
// lock to look the provider up), so any handler that ranges p.Models without
// holding p.mu races on the slice header against the challenge goroutine.
//
// The /v1/stats and /v1/providers/attestation handlers both range p.Models
// inside a ForEachProvider callback. This test drives both handlers concurrently
// with UpdateModelWeightHashes; run under -race it fails (DATA RACE) before the
// handler-side locking fix and passes after.
func TestHandlersDoNotRaceModelHashRefresh(t *testing.T) {
	const modelID = "data-race-model"

	srv, _ := testServer(t)
	reg := srv.registry

	regMsg := &protocol.RegisterMessage{
		Type:                    protocol.TypeRegister,
		Hardware:                protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64, GPUCores: 40},
		Models:                  []protocol.ModelInfo{{ID: modelID, ModelType: "chat", Quantization: "4bit", WeightHash: "hash-a"}},
		Backend:                 "mlx-swift",
		PublicKey:               testPublicKeyB64(),
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	reg.Register("p1", nil, regMsg)

	handler := srv.Handler()

	var wg sync.WaitGroup
	stop := make(chan struct{})

	// Writer: flip the stored weight hash so each call actually replaces the
	// Provider.Models slice header (the racy write).
	wg.Add(1)
	go func() {
		defer wg.Done()
		toggle := false
		for {
			select {
			case <-stop:
				return
			default:
			}
			h := "hash-a"
			if toggle {
				h = "hash-b"
			}
			toggle = !toggle
			reg.UpdateModelWeightHashes("p1", map[string]string{modelID: h})
		}
	}()

	hit := func(path string) {
		// /v1/stats caches its serialized body for 60s, so without this the
		// handler would range p.Models only on the first (cache-miss) call and
		// the stats-side race would be exercised exactly once. Invalidate the
		// key each iteration so every call misses the cache and actually reads
		// p.Models — otherwise reverting ONLY the stats fix would not reliably
		// trip -race.
		if path == "/v1/stats" {
			srv.readCache.Invalidate("stats:v1")
		}
		req := httptest.NewRequest(http.MethodGet, path, nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
	}

	for _, path := range []string{"/v1/stats", "/v1/providers/attestation"} {
		path := path
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				hit(path)
			}
		}()
	}

	// Hammer the writer from this goroutine too, then stop.
	for i := 0; i < 20000; i++ {
		reg.UpdateModelWeightHashes("p1", map[string]string{modelID: "hash-c"})
		reg.UpdateModelWeightHashes("p1", map[string]string{modelID: "hash-a"})
	}
	close(stop)
	wg.Wait()
}
