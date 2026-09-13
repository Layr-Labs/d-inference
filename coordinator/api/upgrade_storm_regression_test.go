package api

// Incident-shaped regression proof for the 2026 upgrade collapse: a routine
// fleet-wide provider binary upgrade (a legitimate release registration
// followed by every provider reconnecting with a new binary hash) must never
// trigger an MDM SecurityInfo/APNs storm or a fleet-wide routability collapse.
//
// Scenario A (TestUpgradeStormReconnectReusesEvidenceWithoutMDMStorm): the
// incident itself. N providers hold fresh durable device evidence earned under
// binary hash A, disconnect, and reconnect near-simultaneously reporting the
// newly registered binary hash B (SE key/serial unchanged, valid SE
// attestation). Every provider must return to hardware trust through the
// evidence-reuse fast path with ZERO MicroMDM traffic.
//
// Scenario B (TestUpgradeStormDueVerificationStaysBoundedAndDurable): the
// bounded fallback. The same fleet arrives with expired/absent device
// evidence against a MicroMDM that never answers (every SecurityInfo attempt
// times out). In-flight MDM work must stay within the scheduler's worker
// bound, no provider may be untrusted by the timeouts, and each provider must
// hold durable retry state.
//
// Builds only on the shared harnesses in provider_mdm_reliability_test.go
// (fakeMDMServer), trust_reuse_test.go (hash constants, record/response
// builders), and mdm_scheduler_test.go (scheduler server + provider helpers).

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/mdm"
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

// TestUpgradeStormReconnectReusesEvidenceWithoutMDMStorm is Scenario A — the
// incident. 25 providers with fresh durable device evidence and trust-reuse
// records earned under binary hash A reconnect near-simultaneously reporting
// binary hash B, the newly registered active release (SE key and serial
// unchanged, valid SE attestation). Asserts:
//
//  1. ZERO MicroMDM requests — in particular zero POST /v1/commands
//     (SecurityInfo enqueue, which MicroMDM turns into an APNs push) — even
//     after a full scheduler dispatch interval elapses;
//  2. every provider returns to hardware trust via the evidence-reuse fast
//     path without waiting on any MDM round-trip (durable scheduler row
//     completed as "reused", no queued scheduler jobs remain);
//  3. no provider is hard-untrusted.
//
// If the reuse path is disabled, the fast-skip declines for every provider,
// the surge falls back to live MDM verification, and this test fails on the
// declined fast path / missing hardware trust — and the near-immediate
// initial spread configured below would surface the SecurityInfo storm inside
// the zero-traffic watch window.
func TestUpgradeStormReconnectReusesEvidenceWithoutMDMStorm(t *testing.T) {
	// Real fake MicroMDM behind a request counter. The incident assertion is
	// that the healthy reconnect surge produces no MDM traffic at all.
	fake := &fakeMDMServer{
		device: &mdm.DeviceInfo{
			SerialNumber: "SERIAL-UPGRADE", UDID: "UDID-UPGRADE",
			EnrollmentStatus: true,
		},
		commandUUID: "cmd-upgrade-storm",
	}
	var securityInfoPosts, totalMDMRequests atomic.Int64
	inner := fake.handler()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		totalMDMRequests.Add(1)
		if r.Method == http.MethodPost && r.URL.Path == "/v1/commands" {
			securityInfoPosts.Add(1)
		}
		inner.ServeHTTP(w, r)
	}))
	t.Cleanup(ts.Close)

	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)

	// Near-zero initial spread + floor jitter: if any provider missed the
	// fast path, its scheduler fallback would issue SecurityInfo essentially
	// immediately, making the zero-traffic window below a real negative
	// assertion instead of a vacuous one. The executor is the REAL
	// executeScheduledVerification wired at the fake MicroMDM.
	sch := newMDMVerificationScheduler(srv, MDMSchedulerConfig{
		Workers: 12, QueueCapacity: 128,
		InitialSpreadMin: 0, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		jitter: func(minimum, _ time.Duration) time.Duration { return minimum },
	})
	srv.mdmScheduler = sch
	srv.SetMDMClient(mdm.NewClient(ts.URL, "test-key", logger))
	srv.SeedTrustReuseCache(context.Background())

	// The routine operational event: release B (0.8.15) is registered as
	// active alongside release A (0.8.14) and synced into the trust policy.
	for _, release := range []store.Release{
		{Version: "0.8.14", Platform: "macos-arm64", Backend: registry.BackendMLXSwift,
			BinaryHash: trHashA, MetallibHash: trHashC, Active: true},
		{Version: "0.8.15", Platform: "macos-arm64", Backend: registry.BackendMLXSwift,
			BinaryHash: trHashB, MetallibHash: trHashC, Active: true},
	} {
		release := release
		if err := st.SetRelease(&release); err != nil {
			t.Fatalf("set release %s: %v", release.Version, err)
		}
	}
	if err := srv.SyncBinaryHashes(); err != nil {
		t.Fatalf("sync binary hashes: %v", err)
	}

	// Fleet setup: each provider upgraded to 0.8.15 (attested binary hash B,
	// SE key/serial unchanged, valid SE attestation) and holds fresh durable
	// device evidence + a trust-reuse record earned under binary hash A.
	now := time.Now()
	providers := make([]upgradeStormProvider, 0, upgradeStormFleetSize)
	for i := range upgradeStormFleetSize {
		id := fmt.Sprintf("upgrade-%d", i)
		seKey := fmt.Sprintf("se-upgrade-%d", i)
		serial := fmt.Sprintf("SER-UPGRADE-%d", i)
		apnsToken := fmt.Sprintf("apns-upgrade-%d", i)
		p := srv.registry.Register(id, nil, &protocol.RegisterMessage{
			Type: protocol.TypeRegister, Backend: registry.BackendMLXSwift,
			Version: "0.8.15", PublicKey: testPublicKeyB64(),
			APNsDeviceToken: apnsToken,
			Models: []protocol.ModelInfo{
				{ID: "upgrade-model", ModelType: "chat", Quantization: "4bit"},
			},
		})
		p.Mu().Lock()
		p.TrustLevel = registry.TrustSelfSigned
		p.Version = "0.8.15"
		p.APNsDeviceToken = apnsToken
		p.RuntimeVerified = true
		p.RuntimeManifestChecked = true
		p.MetallibVerified = true
		p.AttestationResult = &attestation.VerificationResult{
			Valid: true, SerialNumber: serial,
			SIPEnabled: true, SecureBootEnabled: true,
			PublicKey: seKey, BinaryHash: trHashB,
		}
		p.Mu().Unlock()
		srv.trustReuseCache.recordTrust(store.ProviderTrustReuse{
			SEPubKey: seKey, Serial: serial,
			TrustLevel:             string(registry.TrustHardware),
			LastVerifiedBinaryHash: trHashA,
			SIPEnabled:             true, SecureBootFull: true,
			MDAUDID:                 fmt.Sprintf("UDID-UPGRADE-%d", i),
			HardwareProofVerifiedAt: now, EvidenceGeneration: 1,
		})
		providers = append(providers, upgradeStormProvider{
			id: id, seKey: seKey, serial: serial, p: p,
		})
	}

	// The near-simultaneous reconnect surge, mirroring the live path:
	// registration submits the durable scheduler job, the signed challenge
	// derives the approved release transition + application evidence, the
	// trust-reuse fast-skip runs, and the scheduler's challenge gate settles
	// with the fast-skip outcome.
	errCh := make(chan error, upgradeStormFleetSize)
	var wg sync.WaitGroup
	for _, fp := range providers {
		wg.Add(1)
		go func(fp upgradeStormProvider) {
			defer wg.Done()
			resp := &protocol.AttestationResponseMessage{
				BinaryHash: trHashB,
				SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
				TemplateHashes: map[string]string{"mlx_metallib": trHashC},
			}
			if gen := sch.Submit(
				context.Background(), fp.id, fp.p,
				store.VerificationPriorityFirstOrExpired,
			); gen == 0 {
				errCh <- fmt.Errorf("%s: scheduler submission rejected", fp.id)
				return
			}
			fact, evidence, ok := srv.deriveApprovedReleaseTransition(fp.p, resp, true)
			if !ok {
				errCh <- fmt.Errorf("%s: active release B did not derive an approved transition", fp.id)
				return
			}
			if !fp.p.GrantApplicationEvidenceIfNotUntrusted(evidence) {
				errCh <- fmt.Errorf("%s: application evidence rejected", fp.id)
				return
			}
			granted := srv.tryTrustReuseFastSkip(fp.id, fp.p, resp, true, fact)
			sch.ChallengeSettled(fp.p, granted)
			if !granted {
				errCh <- fmt.Errorf(
					"%s: evidence-reuse fast path declined — provider left waiting on a live MDM round-trip",
					fp.id,
				)
			}
		}(fp)
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		t.Error(err)
	}
	if t.Failed() {
		t.FailNow()
	}

	for _, fp := range providers {
		if lvl := fp.p.GetTrustLevel(); lvl != registry.TrustHardware {
			t.Fatalf("%s: trust = %q, want hardware via evidence reuse", fp.id, lvl)
		}
		if status := fp.p.GetStatus(); status == registry.StatusUntrusted {
			t.Fatalf("%s: provider hard-untrusted by a routine upgrade", fp.id)
		}
		if epoch := fp.p.HardUntrustEpoch(); epoch != 0 {
			t.Fatalf("%s: hard-untrust epoch advanced to %d during upgrade", fp.id, epoch)
		}
		if reason := fp.p.GetMDMFailureReason(); reason != "" {
			t.Fatalf("%s: MDM failure reason %q after healthy upgrade", fp.id, reason)
		}
		job, err := st.GetVerificationJob(
			context.Background(), fp.seKey, store.VerificationTaskSecurityInfo)
		if err != nil || job == nil {
			t.Fatalf("%s: durable scheduler row missing: %v", fp.id, err)
		}
		if job.State != store.VerificationStateCompleted ||
			job.LastOutcome != store.VerificationOutcomeReused {
			t.Fatalf("%s: scheduler row state=%q outcome=%q, want completed/reused",
				fp.id, job.State, job.LastOutcome)
		}
	}
	sch.mu.Lock()
	queued := len(sch.jobs)
	sch.mu.Unlock()
	if queued != 0 {
		t.Fatalf("%d scheduler jobs still queued after fleet-wide fast-skip", queued)
	}

	// Zero-traffic watch window covering a full dispatcher tick (1s): any
	// provider that silently fell through to live verification would issue
	// its SecurityInfo command here thanks to the near-zero initial spread.
	deadline := time.Now().Add(1200 * time.Millisecond)
	for time.Now().Before(deadline) {
		if n := totalMDMRequests.Load(); n != 0 {
			t.Fatalf(
				"upgrade reconnect surge produced %d MicroMDM requests (%d SecurityInfo commands); want 0",
				n, securityInfoPosts.Load(),
			)
		}
		time.Sleep(25 * time.Millisecond)
	}
	if n := securityInfoPosts.Load(); n != 0 {
		t.Fatalf("SecurityInfo storm: %d POST /v1/commands, want 0", n)
	}
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

// TestCoordinatorRestartContinuityReconnectAvoidsMDMStorm is the coordinator
// deploy/restart scenario the continuity premise exists for. A fleet of 25
// providers with STALE wall-clock windows (last full live verification 30m
// ago) but coverage persisted by the graceful-shutdown sweep reconnects to a
// FRESH Server over the SAME store within 60s. Asserts:
//
//  1. ZERO MicroMDM requests across a full dispatcher tick — the entire fleet
//     re-admits through the continuity fast-skip;
//  2. every provider returns to hardware trust, durable scheduler row
//     completed as "reused", nobody hard-untrusted;
//  3. the admitting decision is the distinct "continuity" label.
//
// The 5m-gap counterpart below proves the same fleet BEYOND the reconnect
// allowance declines the fast path for every provider and falls back to the
// bounded durable scheduler wave (Scenario B behavior).
func TestCoordinatorRestartContinuityReconnectAvoidsMDMStorm(t *testing.T) {
	fake := &fakeMDMServer{
		device: &mdm.DeviceInfo{
			SerialNumber: "SERIAL-RESTART", UDID: "UDID-RESTART",
			EnrollmentStatus: true,
		},
		commandUUID: "cmd-restart-storm",
	}
	var securityInfoPosts, totalMDMRequests atomic.Int64
	inner := fake.handler()
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		totalMDMRequests.Add(1)
		if r.Method == http.MethodPost && r.URL.Path == "/v1/commands" {
			securityInfoPosts.Add(1)
		}
		inner.ServeHTTP(w, r)
	}))
	t.Cleanup(ts.Close)

	logger := quietLogger()
	st := store.NewMemory(store.Config{})
	base := time.Unix(1_700_000_000, 0)
	seedContinuityFleetAndShutdown(t, st, base, 30*time.Minute)

	// Coordinator instance 2 over the SAME store, 60 seconds after shutdown —
	// well inside the 90s reconnect allowance, far outside the 5m window.
	srv := NewServer(registry.New(logger), st, ServerConfig{}, logger)
	t.Cleanup(srv.Close)
	srv.trustReuseCache.now = func() time.Time { return base.Add(60 * time.Second) }
	sch := newMDMVerificationScheduler(srv, MDMSchedulerConfig{
		Workers: 12, QueueCapacity: 128,
		InitialSpreadMin: 0, InitialSpreadMax: time.Nanosecond,
	}, mdmSchedulerDeps{
		jitter: func(minimum, _ time.Duration) time.Duration { return minimum },
	})
	srv.mdmScheduler = sch
	srv.SetMDMClient(mdm.NewClient(ts.URL, "test-key", logger))
	if err := srv.SeedTrustReuseCache(context.Background()); err != nil {
		t.Fatalf("instance 2 seed: %v", err)
	}

	providers := registerRestartFleet(t, srv)

	// The near-simultaneous reconnect surge, mirroring the live path: the
	// submit priority classification, the fast-skip, and the challenge settle.
	errCh := make(chan error, upgradeStormFleetSize)
	var wg sync.WaitGroup
	for _, fp := range providers {
		wg.Add(1)
		go func(fp upgradeStormProvider) {
			defer wg.Done()
			resp := &protocol.AttestationResponseMessage{
				BinaryHash: trHashA,
				SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
			}
			priority := srv.verificationSubmitPriority(fp.seKey, fp.serial)
			if priority != store.VerificationPriorityRefresh {
				errCh <- fmt.Errorf("%s: submit priority = %q, want refresh (continuity candidate)", fp.id, priority)
				return
			}
			if gen := sch.Submit(
				context.Background(), fp.id, fp.p, priority,
			); gen == 0 {
				errCh <- fmt.Errorf("%s: scheduler submission rejected", fp.id)
				return
			}
			granted := srv.tryTrustReuseFastSkip(fp.id, fp.p, resp, true)
			sch.ChallengeSettled(fp.p, granted)
			if !granted {
				errCh <- fmt.Errorf(
					"%s: continuity fast path declined — provider left waiting on a live MDM round-trip",
					fp.id,
				)
			}
		}(fp)
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		t.Error(err)
	}
	if t.Failed() {
		t.FailNow()
	}

	// Both premises observable: with the window stale, the admitting decision
	// for this fleet is the distinct continuity label.
	if result := srv.trustReuseCache.decideTrustReuse(trustReuseInput{
		SEPubKey: providers[0].seKey, Serial: providers[0].serial,
		FreshBinaryHash: trHashA,
	}); result.Decision != trustReuseDecisionContinuity {
		t.Fatalf("decision = %q, want %q", result.Decision, trustReuseDecisionContinuity)
	}

	for _, fp := range providers {
		if lvl := fp.p.GetTrustLevel(); lvl != registry.TrustHardware {
			t.Fatalf("%s: trust = %q, want hardware via continuity", fp.id, lvl)
		}
		if status := fp.p.GetStatus(); status == registry.StatusUntrusted {
			t.Fatalf("%s: provider hard-untrusted by a coordinator restart", fp.id)
		}
		if epoch := fp.p.HardUntrustEpoch(); epoch != 0 {
			t.Fatalf("%s: hard-untrust epoch advanced to %d during restart", fp.id, epoch)
		}
		job, err := st.GetVerificationJob(
			context.Background(), fp.seKey, store.VerificationTaskSecurityInfo)
		if err != nil || job == nil {
			t.Fatalf("%s: durable scheduler row missing: %v", fp.id, err)
		}
		if job.State != store.VerificationStateCompleted ||
			job.LastOutcome != store.VerificationOutcomeReused {
			t.Fatalf("%s: scheduler row state=%q outcome=%q, want completed/reused",
				fp.id, job.State, job.LastOutcome)
		}
	}

	// Zero-traffic watch window covering a full dispatcher tick: any provider
	// that silently fell through to live verification would issue its
	// SecurityInfo command here thanks to the near-zero initial spread.
	deadline := time.Now().Add(1200 * time.Millisecond)
	for time.Now().Before(deadline) {
		if n := totalMDMRequests.Load(); n != 0 {
			t.Fatalf(
				"coordinator-restart reconnect produced %d MicroMDM requests (%d SecurityInfo commands); want 0",
				n, securityInfoPosts.Load(),
			)
		}
		time.Sleep(25 * time.Millisecond)
	}
	if n := securityInfoPosts.Load(); n != 0 {
		t.Fatalf("SecurityInfo storm: %d POST /v1/commands, want 0", n)
	}
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
