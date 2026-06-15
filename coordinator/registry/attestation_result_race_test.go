package registry

import (
	"encoding/json"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Regression for the data race between persistProviderNow's async
// json.Marshal(p.AttestationResult) and the registration path mutating the
// same local `result` across validation checks. SetAttestationResult must
// snapshot the struct so the stored value never aliases caller-mutable memory.

// Deterministic guard: mutating the caller's struct after storing it must not
// change what the Provider holds. Fails (stored value reflects the mutation)
// without the copy in SetAttestationResult.
func TestSetAttestationResultSnapshotsCallerStruct(t *testing.T) {
	p := &Provider{}
	r := &attestation.VerificationResult{Valid: true, Error: "orig", SerialNumber: "ABC"}
	p.SetAttestationResult(r)

	// Mirror the registration handler mutating its single local `result` after
	// an earlier SetAttestationResult already handed the pointer to the registry.
	r.Valid = false
	r.Error = "mutated"
	r.SerialNumber = "XYZ"

	got := p.GetAttestationResult()
	if got == nil {
		t.Fatal("expected stored result, got nil")
	}
	if !got.Valid || got.Error != "orig" || got.SerialNumber != "ABC" {
		t.Fatalf("stored result was not snapshotted: Valid=%v Error=%q Serial=%q",
			got.Valid, got.Error, got.SerialNumber)
	}
}

func TestSetAttestationResultNilClears(t *testing.T) {
	p := &Provider{}
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true})
	p.SetAttestationResult(nil)
	if p.GetAttestationResult() != nil {
		t.Fatal("expected nil after SetAttestationResult(nil)")
	}
}

// Run under `-race`: a marshal loop (as persistProviderNow does) concurrent with
// a caller mutating its result and re-storing. Clean with the snapshot copy;
// races on the shared struct's fields without it.
func TestSetAttestationResultNoRaceWithConcurrentMarshal(t *testing.T) {
	p := &Provider{}
	r := &attestation.VerificationResult{Valid: true, Error: "orig"}
	p.SetAttestationResult(r)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { // reader: persistProviderNow-style marshal of the stored snapshot
		defer wg.Done()
		for i := 0; i < 5000; i++ {
			if got := p.GetAttestationResult(); got != nil {
				_, _ = json.Marshal(got)
			}
		}
	}()
	go func() { // writer: registration-style mutate-then-restore of the local result
		defer wg.Done()
		for i := 0; i < 5000; i++ {
			r.Valid = !r.Valid
			r.Error = "x"
			p.SetAttestationResult(r)
		}
	}()
	wg.Wait()
}
