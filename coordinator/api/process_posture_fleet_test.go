package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestProcessPostureFleetResumeSkipsMDM(t *testing.T) {
	logger := quietLogger()
	s := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	t.Cleanup(s.Close)
	var requests atomic.Int64
	mdmHTTP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.WriteHeader(http.StatusServiceUnavailable)
	}))
	defer mdmHTTP.Close()
	s.SetMDMClient(mdm.NewClient(mdmHTTP.URL, "test", logger))
	s.mdmScheduler.Start()
	issuer := newMDATestIssuer(t)
	defer attestation.OverrideRootCAForTest(issuer.root)()
	var fleet []*registry.Provider
	for i := 0; i < 25; i++ {
		node, _, _, se := providerKeyMaterial(t)
		p := processPostureProvider(t, s, fmt.Sprintf("resumed-%d", i), node, se)
		ar := *p.GetAttestationResult()
		ar.SerialNumber = fmt.Sprintf("SERIAL-%d", i)
		p.SetAttestationResult(&ar)
		nonce, _ := attestation.ProcessPostureNonce(se, node)
		chain := issuer.mint(t, ar.SerialNumber, nonce, time.Now().Add(time.Hour))
		data, _ := json.Marshal(chain)
		p.StageMDAChainFromJSON(data)
		if s.mdmScheduler.Submit(context.Background(), p.ID, p, store.VerificationPriorityFirstOrExpired) == 0 {
			t.Fatal("scheduler rejected provider")
		}
		fleet = append(fleet, p)
	}
	// Submit alone cannot issue MDM commands. Each process then finishes its
	// exact-key proof concurrently; the cryptographic round trip is covered by
	// TestProcessPostureCoordinatorRestartResumesButRebootDoesNot.
	var wg sync.WaitGroup
	for _, p := range fleet {
		wg.Add(1)
		go func(p *registry.Provider) {
			defer wg.Done()
			p.SetFreshCodeAttested()
			s.processCodeProofSettled(p.ID, p)
		}(p)
	}
	wg.Wait()
	for _, p := range fleet {
		if p.GetTrustLevel() != registry.TrustHardware {
			t.Fatalf("%s failed to resume", p.ID)
		}
	}
	s.mdmScheduler.mu.Lock()
	remaining := len(s.mdmScheduler.jobs)
	s.mdmScheduler.mu.Unlock()
	if remaining != 0 || requests.Load() != 0 {
		t.Fatalf("resume left jobs=%d MDM requests=%d", remaining, requests.Load())
	}
}
