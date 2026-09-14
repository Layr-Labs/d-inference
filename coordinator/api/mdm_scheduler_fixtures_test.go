package api

import (
	"context"
	"io"
	"log/slog"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/mdmscheduler"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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
) (*Server, *store.MemoryStore, *mdmVerificationScheduler) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	sch := newMDMVerificationScheduler(srv, cfg, withSchedulerTestExecutor(deps))
	srv.mdmScheduler = sch
	t.Cleanup(srv.Close)
	return srv, st, sch
}

func schedulerTestProvider(t *testing.T, srv *Server, id, seKey string) *registry.Provider {
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

// These aliases carry values only; scheduler maps, locks and command state remain private.
type mdmSchedulerDeps = mdmscheduler.Dependencies
type mdmLiveBinding = mdmscheduler.Target
type mdmSchedulerAttemptResult = mdmscheduler.AttemptResult
type mdmVerificationScheduler = mdmscheduler.Scheduler

// The fixed first-verification deadline is asserted independently of the owner.
const mdmFirstVerifySpreadMax = 5 * time.Second

func newMDMVerificationScheduler(s *Server, cfg MDMSchedulerConfig, overrides mdmSchedulerDeps) *mdmVerificationScheduler {
	deps := s.mdmSchedulerDependencies()
	deps.Now = overrides.Now
	deps.NewTimer = overrides.NewTimer
	deps.Jitter = overrides.Jitter
	deps.Execute = overrides.Execute
	deps.ReuseMDA = overrides.ReuseMDA
	return mdmscheduler.New(cfg, deps)
}

func (s *Server) executeScheduledVerification(ctx context.Context, target mdmLiveBinding, kind store.VerificationTaskKind, udid string) mdmSchedulerAttemptResult {
	return mdmscheduler.NewExecutor(s.mdmSchedulerDependencies()).Execute(ctx, target, kind, udid)
}

// Read the owner's existing immutable telemetry snapshot instead of its maps.
func schedulerQueueCounts(srv *Server) (queued, active int) {
	for _, line := range strings.Split(srv.metrics.Snapshot().RenderProm(), "\n") {
		if !strings.HasPrefix(line, "mdm_scheduler_queue_depth{") && !strings.HasPrefix(line, "mdm_scheduler_active_attempts{") {
			continue
		}
		pieces := strings.Fields(line)
		if len(pieces) != 2 {
			continue
		}
		value, err := strconv.Atoi(pieces[1])
		if err != nil {
			continue
		}
		if strings.HasPrefix(line, "mdm_scheduler_queue_depth{") {
			queued += value
		} else {
			active += value
		}
	}
	queued += active
	return
}
