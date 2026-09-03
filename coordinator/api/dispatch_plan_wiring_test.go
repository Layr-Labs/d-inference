package api

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// planWiringProvider registers a fully-routable provider through the exported
// registry surface (the api-side mirror of the registry package's
// makeTokenBudgetProvider fixture): trusted, manifest-checked, E2E-capable,
// with a running model-resident slot whose token-budget backlog dominates
// routing cost, so winner and plan order are deterministic. The connection is
// nil, so no provider writer exists: a reservation succeeds, the funnel
// prepares and encrypts, and the deferred write then fails deterministically
// ("failed to send request to provider") — which lets tests observe that an
// entry went through the single prepare/encrypt/write funnel without a live
// provider socket.
func planWiringProvider(t *testing.T, reg *registry.Registry, id, model string, backlogTokens int64) *registry.Provider {
	t.Helper()
	p := reg.Register(id, nil, &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			ChipFamily:         "M3",
			ChipTier:           "Max",
			MemoryGB:           64,
			MemoryAvailableGB:  60,
			CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
			MemoryBandwidthGBs: 400,
		},
		Models:                  []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
		Backend:                 registry.BackendMLXSwift,
		DecodeTPS:               100,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess:    true,
			TextProxyDisabled:       true,
			PythonRuntimeLocked:     true,
			DangerousModulesBlocked: true,
			SIPEnabled:              true,
			AntiDebugEnabled:        true,
			CoreDumpsDisabled:       true,
			EnvScrubbed:             true,
		},
	})
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model:                 model,
			State:                 "running",
			ActiveTokenBudgetUsed: backlogTokens,
			ActiveTokenBudgetMax:  1_000_000,
			ObservedDecodeTPS:     80,
		}},
	}
	p.Mu().Unlock()
	return p
}

// planWiringPlan reserves through the production scan to obtain a real
// DispatchPlan, then releases the primary reservation (the routability-probe
// idiom, helpers_ws_test.go findRoutableProvider).
func planWiringPlan(t *testing.T, reg *registry.Registry, model string) *registry.DispatchPlan {
	t.Helper()
	probe := &registry.PendingRequest{
		RequestID:             "plan-wiring-probe",
		Model:                 model,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    256,
	}
	primary, decision, plan := reg.ReserveProviderWithPlan(model, probe)
	if primary == nil || plan == nil {
		t.Fatalf("plan reservation failed: decision=%+v", decision)
	}
	primary.RemovePending(probe.RequestID)
	reg.SetProviderIdle(primary.ID)
	return plan
}

// TestPlanFirstRetryConsumesPlanBeforeRescanAndRefreshesOnce pins Phase-3
// retry selection: while plan entries remain, every dispatch reserves the
// next retained entry through the single funnel (no full rescan), the
// exhausted plan spends exactly ONE RefreshDispatchPlan for the whole logical
// request, and afterwards the machinery reports tried=false so the caller
// falls back to the unchanged legacy scan.
func TestPlanFirstRetryConsumesPlanBeforeRescanAndRefreshesOnce(t *testing.T) {
	s := newTestServerForDispatch(t)
	const model = "plan-wiring-retry-model"
	for i := range 6 {
		planWiringProvider(t, s.registry, fmt.Sprintf("pw%d", i), model, int64(i)*400)
	}
	plan := planWiringPlan(t, s.registry, model)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader("{}"))
	d := &dispatchState{
		s:                 s,
		r:                 req,
		model:             model,
		publicModel:       model,
		rawBody:           []byte(`{"model":"` + model + `"}`),
		deadline:          5 * time.Second,
		speculativeAt:     2500 * time.Millisecond,
		timing:            &registry.RequestTiming{ReceivedAt: time.Now()},
		excludeProviders:  map[string]struct{}{},
		refundReservation: func() {},
		plan:              plan,
	}

	entries := plan.Len()
	if entries == 0 {
		t.Fatal("fixture retained no alternates")
	}
	for i := range entries {
		provider, pr, _, lastErr, _, tried := d.dispatchFromPlanMachinery(d.timing, d.excludeProviders, "", nil)
		if !tried {
			t.Fatalf("entry %d: machinery yielded nothing with %d entries remaining", i, d.plan.Remaining())
		}
		if provider != nil || pr != nil {
			t.Fatalf("entry %d: socketless provider must fail the funnel write, got provider=%v", i, provider)
		}
		if lastErr != "failed to send request to provider" {
			t.Fatalf("entry %d: lastErr=%q — the plan entry did not go through the single dispatch funnel", i, lastErr)
		}
		if d.planRefreshUsed {
			t.Fatalf("entry %d: consuming a retained entry must not spend the refresh", i)
		}
	}
	if got := d.plan.Remaining(); got != 0 {
		t.Fatalf("remaining=%d after consuming every entry", got)
	}

	// Exhausted plan → the single refresh runs. Winner + every alternate is
	// attempted across a 6-provider fleet, so the refresh scan (which carries
	// those exclusions) finds nothing: tried=false, refresh latched.
	if _, _, _, _, _, tried := d.dispatchFromPlanMachinery(d.timing, d.excludeProviders, "", nil); tried {
		t.Fatal("refresh over a fully-attempted fleet must yield nothing")
	}
	if !d.planRefreshUsed {
		t.Fatal("exhausted plan must spend the request's one refresh")
	}
	// Once per logical request: the machinery never refreshes again.
	if _, _, _, _, _, tried := d.dispatchFromPlanMachinery(d.timing, d.excludeProviders, "", nil); tried {
		t.Fatal("second refresh must not run")
	}
}

// TestHedgeAdvanceRearmsSpeculativeTimerEarlier pins the waitFirstChunk
// re-arm guards: a strictly-earlier probe-refined instant moves the backup
// launch off the 50% point, while a not-earlier value leaves the legacy
// timing untouched (invariant 1 of hedge_schedule.go — the 50% point is a
// ceiling, never exceeded).
func TestHedgeAdvanceRearmsSpeculativeTimerEarlier(t *testing.T) {
	t.Run("earlier instant launches the backup sooner", func(t *testing.T) {
		d, _ := firstTokenWaitState(t, 0, 1200*time.Millisecond)
		d.speculativeAt = 900 * time.Millisecond
		receivedAt := timingReceivedAt(d.timing)
		d.hedgeAdvanceCh = make(chan time.Time, 1)
		d.hedgeAdvanceCh <- receivedAt.Add(150 * time.Millisecond)

		speculativeStarted := make(chan time.Time, 1)
		d.onSpeculativeDispatch = func() { speculativeStarted <- time.Now() }

		go d.waitFirstChunk()
		select {
		case at := <-speculativeStarted:
			if since := at.Sub(receivedAt); since > 600*time.Millisecond {
				t.Fatalf("backup launched %s after receipt, want ~150ms (re-armed), not the 900ms default", since)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("speculative launch never fired")
		}
		if d.speculativeAt != 150*time.Millisecond {
			t.Fatalf("speculativeAt=%s after re-arm, want 150ms so downstream windows agree", d.speculativeAt)
		}
	})

	t.Run("not-earlier instant is ignored", func(t *testing.T) {
		d, _ := firstTokenWaitState(t, 0, 1200*time.Millisecond)
		d.speculativeAt = 500 * time.Millisecond
		receivedAt := timingReceivedAt(d.timing)
		d.hedgeAdvanceCh = make(chan time.Time, 1)
		// Equal to the armed point: NOT strictly earlier, must not re-arm.
		d.hedgeAdvanceCh <- receivedAt.Add(500 * time.Millisecond)

		speculativeStarted := make(chan time.Time, 1)
		d.onSpeculativeDispatch = func() { speculativeStarted <- time.Now() }

		go d.waitFirstChunk()
		select {
		case at := <-speculativeStarted:
			if since := at.Sub(receivedAt); since < 400*time.Millisecond {
				t.Fatalf("backup launched %s after receipt — a not-earlier advance re-armed the timer", since)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("speculative launch never fired")
		}
		if d.speculativeAt != 500*time.Millisecond {
			t.Fatalf("speculativeAt=%s, want the untouched 500ms default", d.speculativeAt)
		}
	})
}

// TestGovernorSuppressionFallsThroughToNoBackup pins the Phase-4 gate: in a
// capacity-REPORTING fleet with no idle capacity anywhere (the only
// alternative is occupied), the governor suppresses the backup, records its
// verdict, and the request falls through the exact legacy no-backup wait —
// same outcome, same 504-shaped last error, and a zero in-flight hedge count
// afterwards.
func TestGovernorSuppressionFallsThroughToNoBackup(t *testing.T) {
	d, _ := firstTokenWaitState(t, 0, 500*time.Millisecond)
	d.speculativeAt = 30 * time.Millisecond
	// A capacity-reporting alternative that is fully occupied: the fleet
	// emits real signals (no silent-fleet bypass) but offers no idle slot.
	busy := planWiringProvider(t, d.s.registry, "busy-alt", d.model, 0)
	busy.Mu().Lock()
	busy.BackendCapacity.Slots[0].NumRunning = 2
	busy.BackendCapacity.Slots[0].ActiveTokens = 5000
	busy.Mu().Unlock()

	if got := d.waitFirstChunk(); got != outcomeRetry {
		t.Fatalf("waitFirstChunk=%v, want timeout-driven outcomeRetry", got)
	}
	if d.hedgeGovernorVerdict != hedgeSuppressNoIdleCapacity.String() {
		t.Fatalf("verdict=%q, want %q", d.hedgeGovernorVerdict, hedgeSuppressNoIdleCapacity.String())
	}
	if d.lastErrCode != http.StatusGatewayTimeout {
		t.Fatalf("lastErrCode=%d, want the legacy no-backup 504", d.lastErrCode)
	}
	if got := d.s.hedgeGov.activeHedgeCount(); got != 0 {
		t.Fatalf("activeHedges=%d after suppression, want 0", got)
	}
}

// TestGovernorBypassesCapacitySilentFleet pins the dual-path escape (plan
// decision #3): a fleet that reports NO capacity signals for the model gives
// the governor meaningless inputs, so legacy providers keep today's
// unconditional hedge — verdict allow, never a suppression they cannot
// influence.
func TestGovernorBypassesCapacitySilentFleet(t *testing.T) {
	d, _ := firstTokenWaitState(t, 0, 500*time.Millisecond)
	d.speculativeAt = 30 * time.Millisecond

	if got := d.waitFirstChunk(); got != outcomeRetry {
		t.Fatalf("waitFirstChunk=%v, want timeout-driven outcomeRetry", got)
	}
	if d.hedgeGovernorVerdict != hedgeAllow.String() {
		t.Fatalf("verdict=%q, want %q — a capacity-silent fleet must keep the legacy hedge path", d.hedgeGovernorVerdict, hedgeAllow.String())
	}
	if got := d.s.hedgeGov.activeHedgeCount(); got != 0 {
		t.Fatalf("activeHedges=%d after resolution, want 0", got)
	}
}

// TestGovernorAllowKeepsLegacyBackupPath pins default-path equivalence: with
// an idle-loaded eligible alternative and no queued demand the governor
// allows, the backup selection runs exactly the legacy full scan (no plan
// retained), and the admitted-but-never-dispatched hedge slot is released —
// exactly-once accounting even when the funnel refuses the backup.
func TestGovernorAllowKeepsLegacyBackupPath(t *testing.T) {
	d, _ := firstTokenWaitState(t, 0, 500*time.Millisecond)
	d.speculativeAt = 30 * time.Millisecond
	d.rawBody = []byte(`{"model":"first-token-deadline-model"}`)
	// An idle, trusted, model-resident alternative: the governor's spare
	// capacity condition holds. It has no socket, so the legacy backup
	// dispatch reserves it and then fails the deferred write — the allow path
	// is observable without a live provider.
	planWiringProvider(t, d.s.registry, "idle-backup", d.model, 0)

	if got := d.waitFirstChunk(); got != outcomeRetry {
		t.Fatalf("waitFirstChunk=%v, want timeout-driven outcomeRetry", got)
	}
	if d.hedgeGovernorVerdict != hedgeAllow.String() {
		t.Fatalf("verdict=%q, want %q (idle capacity exists, no queue)", d.hedgeGovernorVerdict, hedgeAllow.String())
	}
	// The backup dispatch is observable through its persisted routing
	// decision: runSpeculative's recordBackupRoute records a route row for
	// the reserved backup before the funnel's deferred write fails. (The
	// backup exclusion set is a request-local copy, so d.excludeProviders is
	// deliberately NOT the observable here.)
	st, ok := d.s.store.(*store.MemoryStore)
	if !ok {
		t.Fatalf("store = %T", d.s.store)
	}
	backupRouted := false
	for _, route := range st.InferenceRouteRecordsSince(time.Time{}) {
		if route.ProviderID == "idle-backup" {
			backupRouted = true
			break
		}
	}
	if !backupRouted {
		t.Fatal("allow path must have run the legacy backup dispatch (no route row for the reserved backup)")
	}
	if got := d.s.hedgeGov.activeHedgeCount(); got != 0 {
		t.Fatalf("activeHedges=%d, want 0 — an admitted hedge that never dispatched must be released", got)
	}
}

// TestExhaustionAttemptCountPrefersProviderDispatches pins the Phase-3
// counting rule: client-visible exhaustion messages report frames actually
// handed to providers, falling back to the legacy loop count only when
// nothing ever dispatched.
func TestExhaustionAttemptCountPrefersProviderDispatches(t *testing.T) {
	d := &dispatchState{attempt: 7}
	if got := d.exhaustionAttemptCount(); got != 8 {
		t.Fatalf("no dispatches: count=%d, want legacy attempt+1=8", got)
	}
	d.providerDispatches = 3
	if got := d.exhaustionAttemptCount(); got != 3 {
		t.Fatalf("count=%d, want 3 actual dispatches (not loop attempts)", got)
	}
}

// TestCapacityRejectionReasonThreadsIntoClassification pins the enriched-
// rejection funnel: the typed wire reason crosses the sanitizer as BOTH the
// preserved RejectionReason and a mapped structured error_reason, and the
// existing reason-first classifier (never a parallel one) produces the
// intended failover kind.
func TestCapacityRejectionReasonThreadsIntoClassification(t *testing.T) {
	tests := []struct {
		name       string
		rejection  protocol.CapacityRejectionReason
		wantReason string
		wantKind   rejectionKind
	}{
		{"token_budget is node-transient", protocol.RejectionReasonTokenBudget, errorReasonRequestExceedsNodeBudget, rejectionTransientCapacity},
		{"kv_headroom is node-transient", protocol.RejectionReasonKVHeadroom, errorReasonRequestExceedsNode, rejectionTransientCapacity},
		{"memory_cap is node-transient", protocol.RejectionReasonMemoryCap, errorReasonRequestExceedsNode, rejectionTransientCapacity},
		{"slot_state is busy-now", protocol.RejectionReasonSlotState, errorReasonCapacityBusy, rejectionTransientCapacity},
		{"deadline is the neutral refusal", protocol.RejectionReasonDeadline, errorReasonDeadlineUnreachable, rejectionDeadlineUnreachable},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			safe, _, _ := sanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
				Type:            protocol.TypeInferenceError,
				RequestID:       "r",
				StatusCode:      http.StatusServiceUnavailable,
				FailureCode:     protocol.FailureCodeCapacity,
				RejectionReason: tt.rejection,
			})
			if safe.RejectionReason != tt.rejection {
				t.Fatalf("RejectionReason=%q, want preserved %q", safe.RejectionReason, tt.rejection)
			}
			if safe.ErrorReason != tt.wantReason {
				t.Fatalf("ErrorReason=%q, want mapped %q", safe.ErrorReason, tt.wantReason)
			}
			if got := classifyRejection(safe.ErrorReason, safe.Error, 0, 0, safe.RejectionReason); got != tt.wantKind {
				t.Fatalf("classifyRejection=%v, want %v", got, tt.wantKind)
			}
		})
	}

	// A provider-supplied structured reason always wins over the mapping.
	safe, _, _ := sanitizeProviderInferenceError(&protocol.InferenceErrorMessage{
		Type:            protocol.TypeInferenceError,
		StatusCode:      http.StatusServiceUnavailable,
		FailureCode:     protocol.FailureCodeCapacity,
		ErrorReason:     errorReasonRequestExceedsContext,
		RejectionReason: protocol.RejectionReasonTokenBudget,
	})
	if safe.ErrorReason != errorReasonRequestExceedsContext {
		t.Fatalf("ErrorReason=%q, want the provider's own %q untouched", safe.ErrorReason, errorReasonRequestExceedsContext)
	}
}

// TestSetLastInferenceErrorPrefersLiveBudgetAndKeepsFeasibleAfter pins the
// enriched-field capture: the rejection-time live budget replaces the stale
// heartbeat snapshot for the deterministic-vs-transient call, FeasibleAfterMS
// survives for the Retry-After surface, and a later coordinator-synthetic
// error clears both (no bleed-through).
func TestSetLastInferenceErrorPrefersLiveBudgetAndKeepsFeasibleAfter(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m", modelMaxContext: 8192}
	d.setLastInferenceError(nil, protocol.InferenceErrorMessage{
		Type:                 protocol.TypeInferenceError,
		StatusCode:           http.StatusServiceUnavailable,
		FailureCode:          protocol.FailureCodeCapacity,
		ErrorReason:          errorReasonRequestExceedsBatchBudget,
		AvailableTokenBudget: i64ptr(4096),
		FeasibleAfterMS:      1500,
	})
	if d.lastErrProviderBudget != 4096 {
		t.Fatalf("lastErrProviderBudget=%d, want the live 4096 (provider is nil: no heartbeat snapshot)", d.lastErrProviderBudget)
	}
	if d.lastErrFeasibleAfterMS != 1500 {
		t.Fatalf("lastErrFeasibleAfterMS=%d, want 1500", d.lastErrFeasibleAfterMS)
	}
	// Live budget (4096) below the model context (8192): a batch-budget
	// reject from THIS pressured node is transient, not fleet-deterministic.
	if got := classifyRejection(d.lastErrReason, d.lastErr, d.lastErrProviderBudget, d.modelMaxContext, d.lastErrRejectionReason); got != rejectionTransientCapacity {
		t.Fatalf("classifyRejection=%v, want rejectionTransientCapacity via the live budget", got)
	}
	d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
	if d.lastErrFeasibleAfterMS != 0 {
		t.Fatalf("lastErrFeasibleAfterMS=%d after synthetic error, want cleared", d.lastErrFeasibleAfterMS)
	}
}

func i64ptr(v int64) *int64 { return &v }

// TestSetLastInferenceErrorExplicitZeroBudgetStaysTransient pins the P1-4
// authority chain end to end: an enriched busy-slot rejection carrying an
// EXPLICIT zero live budget plus the typed token_budget reason crosses the
// sanitizer with both intact, and classification stays TRANSIENT — the typed
// reason is authoritative, so the stale heartbeat fallback (an unknown or
// at/above-context budget snapshot would otherwise read fleet-deterministic)
// can never stop failover for a shortage the live gate called momentary.
func TestSetLastInferenceErrorExplicitZeroBudgetStaysTransient(t *testing.T) {
	d := &dispatchState{s: newTestServerForDispatch(t), model: "m", modelMaxContext: 8192}
	d.setLastInferenceError(nil, protocol.InferenceErrorMessage{
		Type:                 protocol.TypeInferenceError,
		StatusCode:           http.StatusServiceUnavailable,
		FailureCode:          protocol.FailureCodeCapacity,
		ErrorReason:          errorReasonRequestExceedsBatchBudget,
		RejectionReason:      protocol.RejectionReasonTokenBudget,
		AvailableTokenBudget: i64ptr(0),
	})
	if d.lastErrProviderBudget != 0 {
		t.Fatalf("lastErrProviderBudget=%d, want the explicit live zero", d.lastErrProviderBudget)
	}
	if d.lastErrRejectionReason != protocol.RejectionReasonTokenBudget {
		t.Fatalf("lastErrRejectionReason=%q, want token_budget preserved through the sanitizer", d.lastErrRejectionReason)
	}
	if got := classifyRejection(d.lastErrReason, d.lastErr, d.lastErrProviderBudget, d.modelMaxContext, d.lastErrRejectionReason); got != rejectionTransientCapacity {
		t.Fatalf("classifyRejection=%v, want transient — typed token_budget is authoritative over the stale heartbeat fallback", got)
	}
	// Failover continues: the transient verdict consumes a capacity retry
	// instead of latching unservable on the first occurrence.
	if d.shouldStopFailover() {
		t.Fatal("first typed token_budget rejection must keep failing over")
	}
	if d.unservable {
		t.Fatal("typed token_budget rejection must not latch deterministic-unservable")
	}
	// Legacy frame (nil budget, no typed reason): today's classification is
	// byte-identical — unknown budget ⇒ deterministic stop.
	d2 := &dispatchState{s: newTestServerForDispatch(t), model: "m", modelMaxContext: 8192}
	d2.setLastInferenceError(nil, protocol.InferenceErrorMessage{
		Type:        protocol.TypeInferenceError,
		StatusCode:  http.StatusServiceUnavailable,
		FailureCode: protocol.FailureCodeCapacity,
		ErrorReason: errorReasonRequestExceedsBatchBudget,
	})
	if got := classifyRejection(d2.lastErrReason, d2.lastErr, d2.lastErrProviderBudget, d2.modelMaxContext, d2.lastErrRejectionReason); got != rejectionDeterministicUnservable {
		t.Fatalf("legacy classifyRejection=%v, want unchanged deterministic", got)
	}
}

// TestCollectCapacityQuotesRefinesOnlyOnHighConfidence pins the collector's
// hedge-timing extraction: a HIGH-confidence confirmed backup whose quoted
// q90 proves the 50% point too late delivers the exact earlier hedgeLaunchAt
// instant; a LOW-confidence quote collapses to the 50% ceiling and delivers
// nothing (legacy timing stands).
func TestCollectCapacityQuotesRefinesOnlyOnHighConfidence(t *testing.T) {
	s := newTestServerForDispatch(t)
	const model = "collect-quotes-model"
	for i := range 4 {
		planWiringProvider(t, s.registry, fmt.Sprintf("cq%d", i), model, int64(i)*400)
	}
	receivedAt := time.Now()
	deadline := 9 * time.Second
	speculativeAt := 4500 * time.Millisecond

	run := func(confidence string) (time.Time, bool) {
		plan := planWiringPlan(t, s.registry, model)
		next, ok := plan.PeekNext()
		if !ok {
			t.Fatal("plan retained no alternates")
		}
		quote := &protocol.CapacityQuoteMessage{
			Type:          protocol.TypeCapacityQuote,
			QuoteID:       "q-" + confidence,
			AdmissibleNow: true,
			TTFTP90MS:     7000,
			Confidence:    confidence,
		}
		plan.ConfirmEntry(next.ProviderID, quote)
		outcomes := make(chan registry.QuoteOutcome, 1)
		outcomes <- registry.QuoteOutcome{ProviderID: next.ProviderID, Quote: quote}
		close(outcomes)
		advance := make(chan time.Time, 1)
		collectCapacityQuotes(outcomes, plan, receivedAt, deadline, speculativeAt, advance)
		select {
		case at := <-advance:
			return at, true
		default:
			return time.Time{}, false
		}
	}

	at, delivered := run(protocol.CapacityConfidenceHigh)
	if !delivered {
		t.Fatal("high-confidence slow backup must refine the launch point")
	}
	// latest_useful = 9s − max(7s, floor) − 500ms commit guard = 1.5s.
	if want := receivedAt.Add(1500 * time.Millisecond); !at.Equal(want) {
		t.Fatalf("refined instant=%s, want receivedAt+1.5s (%s)", at, want)
	}

	if _, delivered := run(protocol.CapacityConfidenceLow); delivered {
		t.Fatal("low-confidence quote must never move the launch off the 50% ceiling")
	}
}
