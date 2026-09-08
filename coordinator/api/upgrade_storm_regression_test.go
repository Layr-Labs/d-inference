package api

// Fleet tests separate process-preserving coordinator restarts from provider
// updates/reboots. Only the former may resume without fresh Apple posture.

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const upgradeStormFleetSize = 25

// upgradeStormProvider is one fleet member of the reconnect surge.
type upgradeStormProvider struct {
	id     string
	seKey  string
	serial string
	p      *registry.Provider
}

// TestUpgradeStormDueVerificationStaysBoundedAndDurable is Scenario B — the
// bounded storm when re-verification is genuinely due. The same fleet size
// arrives with EXPIRED device evidence (so the reuse fast path must decline)
// against a MicroMDM that never answers: every SecurityInfo attempt blocks
// until released and then reports a timeout. Asserts:
//
//  1. in-flight MDM work never exceeds the scheduler's configured worker
//     bound (4 here, not 25 simultaneous attempts);
//  2. providers stay self_signed — a timeout is APN latency/device sleep,
//     never evidence of compromise, so nobody is untrusted;
//  3. every provider holds durable retry state (backoff, retry stage 1,
//     timeout outcome, future next-attempt time) that survives restarts.
func TestUpgradeStormDueVerificationStaysBoundedAndDurable(t *testing.T) {
	const workerBound = 4

	var active, maximum atomic.Int32
	released := make(chan struct{})
	execute := func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
		current := active.Add(1)
		for {
			old := maximum.Load()
			if current <= old || maximum.CompareAndSwap(old, current) {
				break
			}
		}
		// The fake MicroMDM never answers: hold the attempt in flight until
		// the test releases it, then report the SecurityInfo wait timing out.
		select {
		case <-released:
		case <-ctx.Done():
		}
		active.Add(-1)
		// A timeout proves nothing about posture: transient, never terminal.
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeTimeout}
	}
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: workerBound, QueueCapacity: 128,
		InitialSpreadMin: 0, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		// Floor jitter: due rows dispatch immediately; a stage-1 retry lands
		// a full 2 minutes out, so drained attempts cannot re-dispatch and
		// spin within the test window.
		jitter:  func(minimum, _ time.Duration) time.Duration { return minimum },
		execute: execute,
	})
	srv.mdmClient = dummyMDMClient() // satisfy the fast-skip "MDM configured" gate

	providers := make([]upgradeStormProvider, 0, upgradeStormFleetSize)
	for i := range upgradeStormFleetSize {
		id := fmt.Sprintf("storm-%d", i)
		seKey := fmt.Sprintf("se-storm-%d", i)
		p := schedulerTestProvider(t, srv, id, seKey)
		serial := "serial-" + id

		// Expired device evidence: the record exists but is beyond the reuse
		// window, so the fast path must decline and fall through to a real,
		// scheduler-bounded live verification.
		srv.trustReuseCache.recordTrust(
			hardwareReuseRecord(seKey, serial, trHashA, time.Now().Add(-2*time.Hour)))
		if srv.tryTrustReuseFastSkip(id, p, goodFastSkipResp(), true) {
			t.Fatalf("%s: expired device evidence must not grant via fast path", id)
		}
		if lvl := p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
			t.Fatalf("%s: trust = %q after declined fast path, want self_signed", id, lvl)
		}

		if gen := sch.Submit(
			context.Background(), id, p, store.VerificationPriorityFirstOrExpired,
		); gen == 0 {
			t.Fatalf("%s: scheduler submission rejected", id)
		}
		sch.ChallengeSettled(p, false)
		providers = append(providers, upgradeStormProvider{
			id: id, seKey: seKey, serial: serial, p: p,
		})
	}

	// The worker pool must saturate at exactly the bound while 21 more due
	// rows wait, and must hold there across a full dispatcher tick.
	waitSchedulerCondition(t, func() bool { return maximum.Load() == workerBound },
		"workers did not fill the configured bound")
	hold := time.Now().Add(1100 * time.Millisecond)
	for time.Now().Before(hold) {
		if got := maximum.Load(); got > workerBound {
			t.Fatalf("in-flight MDM attempts reached %d, bound is %d", got, workerBound)
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Let every held attempt time out; the remaining fleet drains through the
	// same bounded pool (signal-driven, no tick waits).
	close(released)
	waitSchedulerCondition(t, func() bool {
		for _, fp := range providers {
			job, err := st.GetVerificationJob(
				context.Background(), fp.seKey, store.VerificationTaskSecurityInfo)
			if err != nil || job == nil || job.State != store.VerificationStateBackoff {
				return false
			}
		}
		return true
	}, "fleet did not reach durable backoff retry state")
	waitSchedulerCondition(t, func() bool { return active.Load() == 0 },
		"attempts did not drain")
	if got := maximum.Load(); got != workerBound {
		t.Fatalf("max in-flight attempts = %d, want exactly the worker bound %d", got, workerBound)
	}

	for _, fp := range providers {
		if lvl := fp.p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
			t.Fatalf("%s: trust = %q after SecurityInfo timeout, want self_signed", fp.id, lvl)
		}
		if status := fp.p.GetStatus(); status == registry.StatusUntrusted {
			t.Fatalf("%s: SecurityInfo timeout hard-untrusted the provider", fp.id)
		}
		if epoch := fp.p.HardUntrustEpoch(); epoch != 0 {
			t.Fatalf("%s: hard-untrust epoch advanced to %d on timeout", fp.id, epoch)
		}
		job, err := st.GetVerificationJob(
			context.Background(), fp.seKey, store.VerificationTaskSecurityInfo)
		if err != nil || job == nil {
			t.Fatalf("%s: durable retry row missing: %v", fp.id, err)
		}
		if job.State != store.VerificationStateBackoff || job.RetryStage != 1 ||
			job.LastOutcome != store.VerificationOutcomeTimeout {
			t.Fatalf("%s: retry row state=%q stage=%d outcome=%q, want backoff/1/timeout",
				fp.id, job.State, job.RetryStage, job.LastOutcome)
		}
		if !job.NextAttemptAt.After(time.Now()) {
			t.Fatalf("%s: retry due time %s not in the future", fp.id, job.NextAttemptAt)
		}
	}
}

// seedContinuityFleetAndShutdown stands up "coordinator instance 1": a fleet
// of upgradeStormFleetSize providers connected and hardware-trusted whose last
// FULL live verification is proofAge old (STALE against the 5m window), each
// with a durable trust-reuse row and live continuity coverage. It then closes
// the server gracefully, so the shutdown sweep persists the exact shutdown
// instant (base) as every row's continuous_coverage_until.
func seedContinuityFleetAndShutdown(t *testing.T, st store.Store, base time.Time, proofAge time.Duration) {
	t.Helper()
	logger := quietLogger()
	srv1 := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	srv1.trustReuseCache.now = func() time.Time { return base }
	if err := srv1.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("instance 1 seed: %v", err)
	}
	for i := range upgradeStormFleetSize {
		id := fmt.Sprintf("restart-%d", i)
		seKey := fmt.Sprintf("se-restart-%d", i)
		serial := fmt.Sprintf("SER-RESTART-%d", i)
		p := srv1.registry.Register(id, nil, &protocol.RegisterMessage{
			Type: protocol.TypeRegister, Backend: registry.BackendMLXSwift,
			Version: "0.8.15", PublicKey: testPublicKeyB64(),
			Models: []protocol.ModelInfo{
				{ID: "restart-model", ModelType: "chat", Quantization: "4bit"},
			},
		})
		p.Mu().Lock()
		p.TrustLevel = registry.TrustHardware
		p.AttestationResult = &attestation.VerificationResult{
			Valid: true, SerialNumber: serial,
			SIPEnabled: true, SecureBootEnabled: true,
			PublicKey: seKey, BinaryHash: trHashA,
		}
		p.Mu().Unlock()
		rec := hardwareReuseRecord(seKey, serial, trHashA, base.Add(-proofAge))
		if res, err := st.UpsertProviderTrustReuse(context.Background(), rec, 0); err != nil || !res.Applied {
			t.Fatalf("%s: persist reuse row: applied=%v err=%v", id, res.Applied, err)
		}
		srv1.trustReuseCache.recordTrust(rec)
		srv1.markTrustCoverage(seKey, id)
	}
	srv1.Close() // graceful shutdown → final coverage sweep at base

	rows, err := st.ListProviderTrustReuse(context.Background())
	if err != nil || len(rows) != upgradeStormFleetSize {
		t.Fatalf("rows after shutdown = %d (%v), want %d", len(rows), err, upgradeStormFleetSize)
	}
	for _, row := range rows {
		if row.ContinuousCoverageUntil == nil || !row.ContinuousCoverageUntil.Equal(base) {
			t.Fatalf("%s: shutdown sweep coverage = %v, want %s",
				row.SEPubKey, row.ContinuousCoverageUntil, base)
		}
	}
}

// registerRestartFleet registers the reconnecting fleet (same SE identities,
// same binary A, self_signed until re-admitted) on a fresh coordinator.
func registerRestartFleet(t *testing.T, srv *Server) []upgradeStormProvider {
	t.Helper()
	providers := make([]upgradeStormProvider, 0, upgradeStormFleetSize)
	for i := range upgradeStormFleetSize {
		id := fmt.Sprintf("restart-%d", i)
		seKey := fmt.Sprintf("se-restart-%d", i)
		serial := fmt.Sprintf("SER-RESTART-%d", i)
		p := srv.registry.Register(id, nil, &protocol.RegisterMessage{
			Type: protocol.TypeRegister, Backend: registry.BackendMLXSwift,
			Version: "0.8.15", PublicKey: testPublicKeyB64(),
			Models: []protocol.ModelInfo{
				{ID: "restart-model", ModelType: "chat", Quantization: "4bit"},
			},
		})
		p.Mu().Lock()
		p.TrustLevel = registry.TrustSelfSigned
		p.AttestationResult = &attestation.VerificationResult{
			Valid: true, SerialNumber: serial,
			SIPEnabled: true, SecureBootEnabled: true,
			PublicKey: seKey, BinaryHash: trHashA,
		}
		p.Mu().Unlock()
		providers = append(providers, upgradeStormProvider{
			id: id, seKey: seKey, serial: serial, p: p,
		})
	}
	return providers
}

// TestCoordinatorRestartBeyondAllowanceFallsBackToSchedulerWave: the same
// shutdown-swept fleet reconnecting after a 5-MINUTE gap (beyond the 90s
// allowance AND the 5m window) must decline the fast path for every provider
// and fall back to the durable scheduler — the bounded wave whose worker-bound
// and retry-state properties Scenario B
// (TestUpgradeStormDueVerificationStaysBoundedAndDurable) pins. With the
// fast-skip declined, the promoted (first/expired) live verification is due
// immediately rather than parked on the refresh spread.
func TestCoordinatorRestartBeyondAllowanceFallsBackToSchedulerWave(t *testing.T) {
	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	base := time.Unix(1_700_000_000, 0)
	seedContinuityFleetAndShutdown(t, st, base, 30*time.Minute)

	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	reconnectAt := base.Add(5 * time.Minute)
	srv.trustReuseCache.now = func() time.Time { return reconnectAt }
	// Wide spread + worst-case jitter: only the failed-fast-skip PROMOTION can
	// make the declined fleet due quickly; execution stays parked so the wave
	// itself (bounded workers, retry rows) remains Scenario B's property.
	sch := newMDMVerificationScheduler(srv, MDMSchedulerConfig{
		Workers: 4, QueueCapacity: 128,
		InitialSpreadMin: time.Hour, InitialSpreadMax: 2 * time.Hour,
	}, mdmSchedulerDeps{
		now:    func() time.Time { return reconnectAt },
		jitter: func(_, maximum time.Duration) time.Duration { return maximum },
	})
	srv.mdmScheduler = sch
	srv.mdmClient = dummyMDMClient() // satisfy the fast-skip "MDM configured" gate
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("seed: %v", err)
	}

	providers := registerRestartFleet(t, srv)
	for _, fp := range providers {
		// The gap outgrew the allowance while the coordinator was down, but
		// the seeded record is retained generation state — the submit-time
		// classification sees no admissible record and the settle path must
		// leave the fleet on immediate first/expired work either way.
		if gen := sch.Submit(
			context.Background(), fp.id, fp.p,
			srv.verificationSubmitPriority(fp.seKey, fp.serial),
		); gen == 0 {
			t.Fatalf("%s: scheduler submission rejected", fp.id)
		}
		resp := &protocol.AttestationResponseMessage{
			BinaryHash: trHashA,
			SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
		}
		if srv.tryTrustReuseFastSkip(fp.id, fp.p, resp, true) {
			t.Fatalf("%s: a 5m gap must not continuity fast-skip", fp.id)
		}
		sch.PromoteFailedFastSkip(fp.p)
		sch.ChallengeSettled(fp.p, false)
		if lvl := fp.p.GetTrustLevel(); lvl != registry.TrustSelfSigned {
			t.Fatalf("%s: trust = %q after declined fast path, want self_signed", fp.id, lvl)
		}
		if status := fp.p.GetStatus(); status == registry.StatusUntrusted {
			t.Fatalf("%s: staleness must never hard-untrust", fp.id)
		}
		job, err := st.GetVerificationJob(
			context.Background(), fp.seKey, store.VerificationTaskSecurityInfo)
		if err != nil || job == nil {
			t.Fatalf("%s: durable scheduler row missing: %v", fp.id, err)
		}
		if job.State == store.VerificationStateCompleted ||
			job.LastOutcome == store.VerificationOutcomeReused {
			t.Fatalf("%s: scheduler row state=%q outcome=%q — must be waiting on a REAL verification",
				fp.id, job.State, job.LastOutcome)
		}
		if job.Priority != store.VerificationPriorityFirstOrExpired {
			t.Fatalf("%s: scheduler priority = %q, want first/expired", fp.id, job.Priority)
		}
		if due := job.NextAttemptAt.Sub(reconnectAt); due > mdmFirstVerifySpreadMax {
			t.Fatalf("%s: live verification due %s out, must be within %s of the declined fast-skip",
				fp.id, due, mdmFirstVerifySpreadMax)
		}
	}
	if result := srv.trustReuseCache.decideTrustReuse(trustReuseInput{
		SEPubKey: providers[0].seKey, Serial: providers[0].serial,
		FreshBinaryHash: trHashA,
	}); result.Decision != "" || result.Reason != trustReuseReasonProofExpired {
		t.Fatalf("decision = %q reason = %q, want expired rejection", result.Decision, result.Reason)
	}
}
