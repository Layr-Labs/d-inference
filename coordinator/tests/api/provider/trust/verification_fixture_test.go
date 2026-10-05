package trust_test

import (
	"context"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

const mdmFirstVerifySpreadMax = 5 * time.Second

// These fixtures are still used by the cross-domain trust integration tests.
type schedulerFixture struct {
	*verification.Service

	cfg  production.MDMSchedulerConfig
	deps verification.Dependencies
}

func newSchedulerTestServer(t *testing.T, cfg production.MDMSchedulerConfig, deps verification.Dependencies,

) (*trustFixture, *memory.MemoryStore, *schedulerFixture) {
	t.Helper()
	logger := quietLogger()
	st := memory.NewMemory(store.Config{})
	srv := newTrustFixture(t, production.Dependencies{Registry: registry.New(logger), Store: st, Logger: logger}, production.Config{})
	if deps.Execute == nil {
		deps.Execute = func(context.Context, verification.Binding,

			store.VerificationTaskKind, string) verification.AttemptResult {
			return verification.AttemptResult{Outcome: store.VerificationOutcomeInvalid, Terminal: true}
		}
	}
	sch := srv.NewVerificationScheduler(cfg, deps)
	srv.verificationBackend.
		Scheduler = sch
	t.Cleanup(srv.Close)
	return srv, st, &schedulerFixture{sch, sch.Configuration(), deps}
}

func schedulerTestProvider(t *testing.T, srv *trustFixture, id, seKey string) *registry.Provider {
	t.Helper()
	p := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", Version: "1.0.0",
		Hardware:  protocol.Hardware{ChipName: "Apple M4 Max", MemoryGB: 64},
		PublicKey: testPublicKeyB64(),
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustSelfSigned
	p.AttestationResult = &attestation.VerificationResult{
		Valid: true, SerialNumber: "serial-" + id,
		SIPEnabled: true, SecureBootEnabled: true, PublicKey: seKey,
	}
	p.Mu().Unlock()
	return p
}

func waitSchedulerCondition(t *testing.T, condition func() bool, message string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal(message)
		}
		time.Sleep(time.Millisecond)
	}
}
