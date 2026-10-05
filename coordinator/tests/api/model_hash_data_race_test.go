package api_test

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
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
// This stays at the composition root to invalidate the shared private cache
// while exercising both the reporting and trust owners through their routes.
func TestHandlersDoNotRaceModelHashRefresh(t *testing.T) {
	const modelID = "data-race-model"

	logger := quietLogger()
	reg := registry.New(logger)
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	cache := readcache.New()
	runtime := production.NewRuntime(production.RuntimeDependencies{
		Registry: reg, Store: st, Ledger: payments.NewLedger(st), ReadCache: cache, Logger: logger,
	}, production.ServerConfig{})
	srv := runtime.Server
	t.Cleanup(srv.Close)

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
		switch path {
		case "/v1/stats":
			cache.Invalidate("stats:v1")
		case "/v1/providers/attestation":
			// Same reasoning: the attestation body is cached for 2s.
			cache.Invalidate(providerAttestationCacheKey)
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
