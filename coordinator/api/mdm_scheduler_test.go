package api

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/codeidentity"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/trustreuse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestContinuityMissPromotesRefreshSubmitToImmediateDue: the continuity path
// widens what counts as a reuse candidate, so the submit-time classification
// can be refresh purely on a continuity-covered record. If the gap outgrows
// the reconnect allowance between submit and challenge, the fast-skip declines
// and the promotion must still land the live verification on immediate
// first/expired scheduling — mirroring the production sequence
// (verificationSubmitPriority → Submit → failed fast-skip →
// PromoteFailedFastSkip → ChallengeSettled).
func TestContinuityMissPromotesRefreshSubmitToImmediateDue(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	srv, st, sch := newSchedulerTestServer(t, MDMSchedulerConfig{
		Workers: 1, QueueCapacity: 8,
		InitialSpreadMin: time.Minute, InitialSpreadMax: 20 * time.Minute,
	}, mdmSchedulerDeps{
		Now:    func() time.Time { return now },
		Jitter: func(_, maximum time.Duration) time.Duration { return maximum },
	})
	srv.mdmClient = dummyMDMClient()
	cur := now
	setTrustReuseClock(t, srv, func() time.Time { return cur })

	p := schedulerTestProvider(t, srv, "cont-miss", "se-cont-miss")
	// Stale window, continuity-covered 60s ago → a reuse candidate at submit.
	seedTrustReuseRecord(t, srv, coveredReuseRecord(
		"se-cont-miss", "serial-cont-miss", trHashA,
		cur.Add(-20*time.Minute), cur.Add(-60*time.Second)))
	priority := srv.verificationSubmitPriority("se-cont-miss", "serial-cont-miss")
	if priority != store.VerificationPriorityRefresh {
		t.Fatalf("submit priority = %q, want refresh for a continuity candidate", priority)
	}
	sch.Submit(context.Background(), p.ID, p, priority)

	// The measured gap outgrows the allowance before the challenge settles.
	cur = cur.Add(2 * time.Minute)
	resp := &protocol.AttestationResponseMessage{
		BinaryHash: trHashA,
		SIPEnabled: trBoolPtr(true), SecureBootEnabled: trBoolPtr(true),
	}
	if srv.tryTrustReuseFastSkip(p.ID, p, resp, true) {
		t.Fatal("outgrown continuity gap must decline the fast-skip")
	}
	sch.PromoteFailedFastSkip(p)
	sch.ChallengeSettled(p, false)

	rec, err := st.GetVerificationJob(context.Background(), "se-cont-miss", store.VerificationTaskSecurityInfo)
	if err != nil || rec == nil {
		t.Fatalf("promoted job not persisted: %+v, %v", rec, err)
	}
	if rec.Priority != store.VerificationPriorityFirstOrExpired {
		t.Fatalf("priority = %q after continuity miss, want promoted first/expired", rec.Priority)
	}
	if due := rec.NextAttemptAt.Sub(now); due > mdmFirstVerifySpreadMax {
		t.Fatalf("continuity-miss settle due %s out, must be within %s", due, mdmFirstVerifySpreadMax)
	}
}

func TestMDMSchedulerFleet1500LifecycleSimulation(t *testing.T) {
	now := time.Date(2026, 8, 29, 12, 0, 0, 0, time.UTC)
	var clock atomic.Int64
	clock.Store(now.UnixNano())
	nowFn := func() time.Time {
		return time.Unix(0, clock.Load()).UTC()
	}
	var jitterIndex atomic.Int64
	var mdmAttempts atomic.Int32
	var activeAttempts atomic.Int32
	var maximumActive atomic.Int32
	var blockDueWork atomic.Bool
	releaseDueWork := make(chan struct{})
	jitter := func(minimum, maximum time.Duration) time.Duration {
		span := maximum - minimum
		if span <= 0 {
			return minimum
		}
		return minimum + time.Duration(jitterIndex.Add(7919)%int64(span))
	}
	cfg := MDMSchedulerConfig{Workers: 12, QueueCapacity: 4096, InitialSpreadMin: time.Hour, InitialSpreadMax: 2 * time.Hour}
	deps := mdmSchedulerDeps{
		Now: nowFn, Jitter: jitter,
		Execute: func(ctx context.Context, _ mdmLiveBinding, _ store.VerificationTaskKind, _ string) mdmSchedulerAttemptResult {
			current := activeAttempts.Add(1)
			for {
				observed := maximumActive.Load()
				if current <= observed || maximumActive.CompareAndSwap(observed, current) {
					break
				}
			}
			mdmAttempts.Add(1)
			if blockDueWork.Load() {
				select {
				case <-releaseDueWork:
				case <-ctx.Done():
					activeAttempts.Add(-1)
					return mdmSchedulerAttemptResult{
						Outcome: store.VerificationOutcomeCancelled,
					}
				}
			}
			activeAttempts.Add(-1)
			return mdmSchedulerAttemptResult{
				Outcome: store.VerificationOutcomeTransient,
			}
		},
	}
	srv, st, sch := newSchedulerTestServer(t, cfg, deps)
	providers := make([]*registry.Provider, 1500)
	originalDue := make(map[string]time.Time, 1500)
	for i := range providers {
		se := fmt.Sprintf("fleet-se-%04d", i)
		p := schedulerTestProvider(t, srv, fmt.Sprintf("fleet-%04d", i), se)
		providers[i] = p
		sch.Submit(context.Background(), p.ID, p, store.VerificationPriorityFirstOrExpired)
		sch.ChallengeSettled(p, false)
		rec, err := st.GetVerificationJob(context.Background(), se, store.VerificationTaskSecurityInfo)
		if err != nil || rec == nil {
			t.Fatalf("device %d scheduler state: %+v %v", i, rec, err)
		}
		originalDue[se] = rec.NextAttemptAt
	}
	queueSize, active := schedulerQueueCounts(srv)
	if queueSize != 1500 || queueSize > 4096 {
		t.Fatalf("fleet queue size = %d", queueSize)
	}
	if active > 12 || mdmAttempts.Load() != 0 {
		t.Fatalf("premature/cap attempts active=%d total=%d", active, mdmAttempts.Load())
	}
	dueSet := map[time.Time]struct{}{}
	for _, due := range originalDue {
		dueSet[due] = struct{}{}
	}
	if len(dueSet) < 1000 {
		t.Fatalf("fleet due times synchronized into only %d instants", len(dueSet))
	}

	// Coordinator restart and unchanged second reconnect preserve every durable
	// due time; a live reuse decision completes without executing MDM.
	sch.Close()
	restarted := newMDMVerificationScheduler(srv, cfg, deps)
	srv.mdmScheduler = restarted
	for i, p := range providers {
		generation := restarted.Submit(context.Background(), p.ID, p, store.VerificationPriorityRefresh)
		if generation == 0 {
			t.Fatalf("restart bind %d failed", i)
		}
		restarted.ChallengeSettled(p, false)
		se := fmt.Sprintf("fleet-se-%04d", i)
		rec, _ := st.GetVerificationJob(context.Background(), se, store.VerificationTaskSecurityInfo)
		if !rec.NextAttemptAt.Equal(originalDue[se]) {
			t.Fatalf("restart reset due time for %s", se)
		}
	}
	var transitionRows []store.ProviderTrustReuse
	for i := range providers {
		transitionRows = append(transitionRows, hardwareReuseRecord(
			fmt.Sprintf("fleet-se-%04d", i), fmt.Sprintf("serial-fleet-%04d", i), trHashA, now))
	}
	transitionCache := trustReuseAssessmentForRecords(t, now, transitionRows)
	for i := range providers {
		se := fmt.Sprintf("fleet-se-%04d", i)
		serial := fmt.Sprintf("serial-fleet-%04d", i)
		decision := transitionCache.Assess(trustreuse.Input{
			SEPubKey: se, Serial: serial, FreshBinaryHash: trHashB,
			ReleaseTransition: approvedReleaseTransitionFact{
				Approved: true, BinaryHash: trHashB,
				ApprovedFromBinaryHashes: map[string]struct{}{trHashA: {}},
			},
		})
		if decision.Decision != trustreuse.DecisionApprovedReleaseTransition {
			t.Fatalf("approved release transition %d required live MDM: %q", i, decision.Decision)
		}
	}
	for i := range 500 {
		restarted.ChallengeSettled(providers[i], true)
	}
	if mdmAttempts.Load() != 0 {
		t.Fatalf("valid reuse sent %d MDM attempts", mdmAttempts.Load())
	}

	// Advance through one real due-work wave after fast-skipping the approved
	// cohort. This exercises durable claims, the fixed worker pool, result
	// settlement, and retry persistence for the remaining 1,000 providers.
	blockDueWork.Store(true)
	clock.Store(now.Add(3 * time.Hour).UnixNano())
	// The real dispatcher observes the advanced clock on its bounded timer.
	waitSchedulerCondition(t, func() bool {
		return maximumActive.Load() == 12
	}, "due wave did not fill the fixed worker pool")
	queueSize, active = schedulerQueueCounts(srv)
	if queueSize > 4096 || active > 12 || maximumActive.Load() > 12 {
		t.Fatalf(
			"due-wave bounds queue=%d active=%d maximum=%d",
			queueSize, active, maximumActive.Load(),
		)
	}
	close(releaseDueWork)
	waitSchedulerCondition(t, func() bool {
		return mdmAttempts.Load() == 1000 && activeAttempts.Load() == 0
	}, "due wave did not execute and settle every non-reused provider")
	attemptsAfterDueWave := mdmAttempts.Load()
	waitSchedulerCondition(t, func() bool {
		for i := 500; i < len(providers); i++ {
			se := fmt.Sprintf("fleet-se-%04d", i)
			rec, err := st.GetVerificationJob(
				context.Background(), se,
				store.VerificationTaskSecurityInfo,
			)
			if err != nil || rec == nil ||
				rec.State != store.VerificationStateBackoff ||
				rec.RetryStage != 1 ||
				rec.LastOutcome != store.VerificationOutcomeTransient ||
				rec.ClaimOwner != "" {
				return false
			}
		}
		return true
	}, "due wave executors returned before durable retry settlement completed")

	// Exact application proof binding: approved same-process reuse spends no APNs;
	// a changed process key cannot reuse the proof and an absent release policy
	// cannot grant an unapproved binary.
	proofStore := store.NewMemory(store.Config{})
	if err := proofStore.UpsertCodeAttestation(context.Background(), store.CodeAttestation{
		SEPubKey: "fleet-se-app", Version: "1.0", APNsToken: "token", NodePublicKey: "process-a", BinaryHash: trHashA, AttestedAt: now,
	}); err != nil {
		t.Fatal(err)
	}
	proofConfig := codeidentity.DefaultConfig()
	proofConfig.Now = func() time.Time { return now }
	th := codeidentity.New(proofConfig, srv.codeIdentityDependencies())
	th.Seed(context.Background(), proofStore)
	if th.ReuseBasis("fleet-se-app", "1.0", "token", "process-a") == "" {
		t.Fatal("valid exact process proof was not reusable")
	}
	if th.ReuseBasis("fleet-se-app", "1.0", "token", "process-b") != "" {
		t.Fatal("changed process key reused APNs proof")
	}
	unapproved := schedulerTestProvider(t, srv, "unapproved", "fleet-se-unapproved")
	unapproved.Mu().Lock()
	unapproved.APNsDeviceToken = "token"
	unapproved.PublicKey = "process-b"
	unapproved.Mu().Unlock()
	if srv.tryCrossVersionReuse(context.Background(), unapproved.ID, unapproved) || unapproved.GetCodeAttested() {
		t.Fatal("unapproved binary gained application trust")
	}

	// Hardware recovery moves through durable recovery/backoff rather than an
	// immediate reconnect reset. A hard-untrust tombstone remains after the same
	// store is reused by another coordinator generation.
	recoverySE := "fleet-se-0500"
	rec, _ := st.GetVerificationJob(context.Background(), recoverySE, store.VerificationTaskSecurityInfo)
	if rec.State == store.VerificationStateCompleted {
		t.Fatal("recovery device unexpectedly completed")
	}
	_, err := st.RevokeProviderTrustReuse(context.Background(), "fleet-se-1499", "fleet-hard-untrust")
	if err != nil {
		t.Fatal(err)
	}
	rows, err := st.ListProviderTrustReuse(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	foundRevoked := false
	for _, row := range rows {
		if row.SEPubKey == "fleet-se-1499" && row.RevokedAt != nil {
			foundRevoked = true
		}
	}
	if !foundRevoked {
		t.Fatal("hard untrust did not survive coordinator restart store")
	}

	// Second reconnect wave remains singleflight and bounded.
	for i := 500; i < len(providers); i++ {
		restarted.Submit(context.Background(), providers[i].ID, providers[i], store.VerificationPriorityRecovery)
		restarted.ChallengeSettled(providers[i], false)
	}
	queueSize, active = schedulerQueueCounts(srv)
	if queueSize > 4096 || active > 12 ||
		mdmAttempts.Load() != attemptsAfterDueWave {
		t.Fatalf(
			"second reconnect bounds queue=%d active=%d attempts=%d want=%d",
			queueSize, active, mdmAttempts.Load(), attemptsAfterDueWave,
		)
	}
	restarted.Close()
}
