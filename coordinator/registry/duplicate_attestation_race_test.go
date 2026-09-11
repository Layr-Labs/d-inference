package registry

import (
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestDisconnectDuplicatesWithConcurrentAttestation(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("other", nil, testRegisterMessage())
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "OTHER"})
	start := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		<-start
		for i := 0; i < 1000; i++ {
			p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "OTHER"})
		}
	}()
	go func() {
		defer wg.Done()
		<-start
		for i := 0; i < 1000; i++ {
			reg.DisconnectDuplicatesBySerial("keep", "KEPT-SERIAL")
		}
	}()
	close(start)
	wg.Wait()
	if reg.GetProvider("other") != p {
		t.Fatal("a different device must remain connected during duplicate scans")
	}
}
