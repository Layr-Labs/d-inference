package registry

import (
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestUpdateModelWeightHashesConcurrentReaders is a race regression for the
// stale-model-hash heal path. UpdateModelWeightHashes replaces p.Models
// copy-on-write under p.mu only (it takes r.mu as a read lock to look up the
// provider, then releases it before the write), so p.mu is the sole lock
// guarding p.Models. Any reader that ranges p.Models without holding p.mu races
// on the slice header against the challenge goroutine that calls
// UpdateModelWeightHashes on every verified attestation response carrying
// refreshed hashes.
//
// This test drives UpdateModelWeightHashes concurrently with every reader that
// reaches p.Models — ForEachProvider (the stats and attestation handlers),
// ListModels, FindProviderWithTrust (via providerServesCatalogModelLocked), and
// ModelCapacitySnapshot. Run under -race it fails (DATA RACE on the p.Models
// slice header) before the reader-side locking fix and passes after.
func TestUpdateModelWeightHashesConcurrentReaders(t *testing.T) {
	const modelID = "mlx-community/Qwen3.5-9B-Instruct-4bit"

	reg := New(testLogger())
	reg.MinTrustLevel = TrustNone
	// Enforce a catalog hash so providerServesCatalogModelLocked actually
	// inspects each model's WeightHash while UpdateModelWeightHashes is rewriting
	// it — exercising the read on the same field being mutated.
	reg.SetModelCatalog([]CatalogEntry{{ID: modelID}})

	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{
		ID:           modelID,
		SizeBytes:    5700000000,
		ModelType:    "qwen3",
		Quantization: "4bit",
		WeightHash:   "hash-a",
	}}
	p := reg.Register("p1", nil, msg)
	testMakeTextRoutable(p)
	// FindProviderWithTrust additionally gates on RuntimeVerified before reaching
	// providerServesCatalogModelLocked; PrivacyCapabilities is already populated
	// by Register from the registration message.
	p.RuntimeVerified = true
	p.LastChallengeVerified = time.Now()

	var wg sync.WaitGroup
	stop := make(chan struct{})

	// Writer: flip the stored weight hash back and forth so every call actually
	// detects a change and replaces the p.Models slice header (the racy write).
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

	// Readers: each must hold p.mu internally; if any ranges p.Models without it,
	// -race trips against the writer above.
	readers := []func(){
		// Mirrors api/stats.go and api/provider.go handleProviderAttestation,
		// which range p.Models inside a ForEachProvider callback.
		func() {
			reg.ForEachProvider(func(p *Provider) {
				p.Mu().Lock()
				for _, m := range p.Models {
					_ = m.ID
					_ = m.WeightHash
				}
				p.Mu().Unlock()
			})
		},
		func() { _ = reg.ListModels() },
		func() { _ = reg.FindProviderWithTrust(modelID, "") },
		func() { _ = reg.ModelCapacitySnapshot() },
		func() { _ = reg.ModelCountryCodes(modelID) },
		func() { _ = reg.ModelType(modelID) },
	}
	for _, fn := range readers {
		fn := fn
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
				fn()
			}
		}()
	}

	// Let the goroutines hammer for a bit, then stop.
	for i := 0; i < 50000; i++ {
		reg.UpdateModelWeightHashes("p1", map[string]string{modelID: "hash-c"})
		reg.UpdateModelWeightHashes("p1", map[string]string{modelID: "hash-a"})
	}
	close(stop)
	wg.Wait()
}
