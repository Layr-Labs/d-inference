package verification_test

import (
	"context"
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/provider/verification"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"io"
	"log/slog"
	"testing"
	"time"
)

func withSchedulerTestExecutor(deps mdmSchedulerDeps) mdmSchedulerDeps {
	if deps.Execute == nil {
		deps.Execute = func(context.Context, mdmLiveBinding, store.VerificationTaskKind, string) mdmSchedulerAttemptResult {
			return mdmSchedulerAttemptResult{
				Outcome:  store.VerificationOutcomeInvalid,
				Terminal: true,
			}
		}
	}
	return deps
}

func newSchedulerTestServer(
	t *testing.T,
	cfg MDMSchedulerConfig,
	deps mdmSchedulerDeps,
) (*schedulerFixture, *memory.MemoryStore, *mdmVerificationScheduler) {
	t.Helper()
	st := memory.NewMemory(store.Config{})
	srv, sch := newSchedulerTestServerWithStore(t, st, cfg, deps)
	return srv, st, sch
}

func newSchedulerTestServerWithStore(
	t *testing.T,
	st store.Store,
	cfg MDMSchedulerConfig,
	deps mdmSchedulerDeps,
) (*schedulerFixture, *mdmVerificationScheduler) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	obs := observation.New(observation.Dependencies{Logger: logger})
	t.Cleanup(obs.Close)
	deps = withSchedulerTestExecutor(deps)
	if deps.Now == nil {
		deps.Now = time.Now
	}
	if deps.ReuseMDA == nil {
		deps.ReuseMDA = func(mdmLiveBinding) bool { return false }
	}
	if deps.PersistProvider == nil {
		deps.PersistProvider = reg.PersistProvider
	}
	queue := verification.NewQueue(cfg)
	sch := &mdmVerificationScheduler{
		Scheduler: verification.New(st, logger, obs, queue, deps),
		store:     st, cfg: queue.Configuration(), deps: deps,
	}
	srv := &schedulerFixture{registry: reg, observation: obs}
	t.Cleanup(sch.Close)
	return srv, sch
}

type cancelAwareVerificationStore struct {
	*memory.MemoryStore
}

func (s *cancelAwareVerificationStore) ReleaseVerificationJob(
	ctx context.Context,
	seKey string,
	kind store.VerificationTaskKind,
	owner string,
	now time.Time,
) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return s.MemoryStore.ReleaseVerificationJob(ctx, seKey, kind, owner, now)
}

type releaseFailingVerificationStore struct {
	*memory.MemoryStore
}

func (s *releaseFailingVerificationStore) ReleaseVerificationJob(
	context.Context,
	string,
	store.VerificationTaskKind,
	string,
	time.Time,
) error {
	return fmt.Errorf("release unavailable")
}

func schedulerTestProvider(t *testing.T, srv *schedulerFixture, id, seKey string) *registry.Provider {
	t.Helper()
	p := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister, Backend: "mlx-swift", Version: "1.0.0",
		Hardware:  protocol.Hardware{ChipName: "Apple M4 Max", MemoryGB: 64},
		PublicKey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
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

// Select the explicit driver before submitting any work. No production once,
// channel or wait-group internals are exposed or replaced.
func withoutLiveDispatcher(sch *mdmVerificationScheduler) {
	sch.manual = true
}

// schedulerJobDue reports whether the scheduler currently holds the job and
// its recorded due time, both read in one detached candidate so a test never races the
// dispatcher's claimAndDispatch, which rewrites job.Record.
func schedulerJobDue(sch *mdmVerificationScheduler, sePubKey string, kind store.VerificationTaskKind) (bool, time.Time) {
	job := sch.Candidate(verificationSchedulerKey(sePubKey, kind))
	if job == nil {
		return false, time.Time{}
	}
	return true, job.Record.NextAttemptAt
}
