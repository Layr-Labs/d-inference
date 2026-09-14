package mdmscheduler

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/verification"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
	"golang.org/x/crypto/nacl/box"
)

type schedulerHarness struct {
	registry *registry.Registry
	metrics  *metrics.Registry
}

func newSchedulerHarness(t *testing.T, cfg Config, deps Dependencies) (*schedulerHarness, *store.MemoryStore, *Scheduler) {
	t.Helper()
	st := store.NewMemory(store.Config{})
	h, sch := newSchedulerHarnessWithStore(t, st, cfg, deps)
	return h, st, sch
}

func newSchedulerHarnessWithStore(t *testing.T, st store.Store, cfg Config, deps Dependencies) (*schedulerHarness, *Scheduler) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	h := &schedulerHarness{registry: registry.New(logger), metrics: metrics.New()}
	h.registry.SetStore(st)
	deps.Store = st
	deps.Registry = func() Registry { return h.registry }
	deps.Logger = func() *slog.Logger { return logger }
	deps.Metrics = func() *metrics.Registry { return h.metrics }
	deps.Counter = func(string, []string) {}
	deps.Gauge = func(string, float64, []string) {}
	deps.Histogram = func(string, float64, []string) {}
	deps.Verifier = func() Verifier {
		return verification.New(verification.Dependencies{
			Registry: func() verification.Registry { return h.registry }, Logger: deps.Logger, Incr: deps.Counter,
		})
	}
	sch := New(cfg, withSchedulerTestExecutor(deps))
	t.Cleanup(sch.Close)
	return h, sch
}

// No inference frames use the private key in these scheduler-owned fixtures.
func testPublicKeyB64() string {
	pub, _, err := box.GenerateKey(rand.Reader)
	if err != nil {
		panic(err)
	}
	return base64.StdEncoding.EncodeToString(pub[:])
}

func withSchedulerTestExecutor(deps Dependencies) Dependencies {
	if deps.Execute == nil {
		deps.Execute = func(context.Context, Target, store.VerificationTaskKind, string) AttemptResult {
			return AttemptResult{
				Outcome:  store.VerificationOutcomeInvalid,
				Terminal: true,
			}
		}
	}
	return deps
}

func schedulerProvider(t *testing.T, srv *schedulerHarness, id, seKey string) *registry.Provider {
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

// withoutLiveDispatcher consumes the scheduler's start Once so Submit's Start
// becomes a no-op and no dispatcher or worker goroutine ever runs. Tests that
// drive loadDueRows by hand are then the only actor over sch.jobs and
// dueScanOffset: nothing concurrently pages the same due rows, claims the
// reseeded job (rewriting job.record) or completes and drops it. Close stays
// safe because the WaitGroup is never armed.
func withoutLiveDispatcher(sch *Scheduler) {
	sch.start.Do(func() {})
}

// schedulerJobDue reports whether the scheduler currently holds the job and
// its recorded due time, both read under sch.mu so a test never races the
// dispatcher's claimAndDispatch, which rewrites job.record.
func schedulerJobDue(sch *Scheduler, sePubKey string, kind store.VerificationTaskKind) (bool, time.Time) {
	sch.mu.Lock()
	defer sch.mu.Unlock()
	job := sch.jobs[jobKey(sePubKey, kind)]
	if job == nil {
		return false, time.Time{}
	}
	return true, job.record.NextAttemptAt
}
