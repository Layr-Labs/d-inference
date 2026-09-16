package registry

import (
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestDisconnectDuplicatesBySerial: providers sharing the kept connection's
// serial must be removed (the path now relies on Disconnect for teardown).
func TestDisconnectDuplicatesBySerial(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	const serial = "SERIAL-DUP-1"
	keep := reg.Register("keep", nil, msg)
	keep.AttestationResult = &attestation.VerificationResult{SerialNumber: serial}
	dupA := reg.Register("dupA", nil, msg)
	dupA.AttestationResult = &attestation.VerificationResult{SerialNumber: serial}
	dupB := reg.Register("dupB", nil, msg)
	dupB.AttestationResult = &attestation.VerificationResult{SerialNumber: serial}
	// A provider from a different device must be left untouched.
	other := reg.Register("other", nil, msg)
	other.AttestationResult = &attestation.VerificationResult{SerialNumber: "SERIAL-OTHER"}

	reg.DisconnectDuplicatesBySerial("keep", serial)

	if reg.GetProvider("keep") == nil {
		t.Error("kept provider should remain registered")
	}
	if reg.GetProvider("other") == nil {
		t.Error("provider with a different serial should not be evicted")
	}
	if reg.GetProvider("dupA") != nil {
		t.Error("duplicate dupA should have been disconnected")
	}
	if reg.GetProvider("dupB") != nil {
		t.Error("duplicate dupB should have been disconnected")
	}
	if reg.ProviderCount() != 2 {
		t.Errorf("provider count = %d, want 2 (keep + other)", reg.ProviderCount())
	}
}

// TestRemoveProviderBySerialRaceWithAttestation guards the DAR-291 delete path:
// RemoveProviderBySerial matches a live machine by its attested serial, reading
// AttestationResult while holding only the registry lock. Since attestation
// completion writes that pointer under the provider mutex (SetAttestationResult),
// the read must go through the thread-safe accessor or it data-races. Run under
// -race; it fails (DATA RACE) without the GetAttestationResult() fix.
func TestRemoveProviderBySerialRaceWithAttestation(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p-race", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "m", ModelType: "chat"}},
	})
	const serial = "SER-RACE"

	var wg sync.WaitGroup
	for i := 0; i < 200; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			p.SetAttestationResult(&attestation.VerificationResult{SerialNumber: serial})
		}()
		go func() {
			defer wg.Done()
			reg.RemoveProviderBySerial(serial, false)
		}()
	}
	wg.Wait()
}
