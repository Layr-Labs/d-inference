package registry

import (
	"fmt"
	"math"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const firstContentTestModel = "first-content-test-model"

func TestFirstContentRoutingConfigurationRejectsUnknownMode(t *testing.T) {
	r := New(testLogger())
	c, pr, now := firstContentEstimateFixture()
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.Status != "" {
		t.Fatal("unconfigured registries must retain off behavior")
	}
	if err := r.ConfigureFirstContentRouting(" SHADOW "); err != nil {
		t.Fatal(err)
	}
	if err := r.ConfigureFirstContentRouting("perfer"); err == nil {
		t.Fatal("unknown mode silently accepted")
	}
	if r.firstContentRoutingMode != FirstContentRoutingShadow {
		t.Fatal("invalid configuration changed the active mode")
	}
}

func firstContentTestProvider(tb testing.TB, reg *Registry, id string, observedPrefill, isolatedPrefill float64) *Provider {
	tb.Helper()
	msg := testRegisterMessage()
	msg.Models = []protocol.ModelInfo{{ID: firstContentTestModel, ModelType: "chat", Quantization: "4bit"}}
	msg.DecodeTPS = 100
	p := reg.Register(id, nil, msg)
	queued, partial, eval := int64(0), int64(0), int64(0)
	initialized := true
	p.mu.Lock()
	p.TrustLevel = TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.LastHeartbeat = time.Now()
	p.capacitySamplesAt = p.LastHeartbeat
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: 64,
		Slots: []protocol.BackendSlotCapacity{{
			Model: firstContentTestModel, State: "idle", MaxConcurrency: 4,
			ObservedDecodeTPS: 100, ObservedPrefillTPS: observedPrefill,
			ActiveTokenBudgetMax: 1_000_000,
			Telemetry: &protocol.SlotTelemetry{
				QueuedPrefillTokens: &queued, PartialPrefillRows: &partial,
				IsolatedPrefillTPS: &isolatedPrefill, EWMAInitialized: &initialized,
				EvalInFlightMS: &eval,
			},
		}},
	}
	p.mu.Unlock()
	return p
}

func firstContentTestRequest() *PendingRequest {
	return &PendingRequest{
		RequestID: "first-content-request", Model: firstContentTestModel,
		EstimatedPromptTokens: 8_000, FirstContentPromptTokens: 10_000,
		RequestedMaxTokens: 128, FirstContentDeadline: time.Now().Add(30 * time.Second),
	}
}

// The ordinary score and the isolated service estimate intentionally disagree.
// This is the failure that a new preference must fix without changing the
// meaning of the existing routing cost or introducing a rejection gate.
func TestFirstContentRoutingPreferenceSelectsFeasibleProvider(t *testing.T) {
	for _, mode := range []string{FirstContentRoutingOff, FirstContentRoutingShadow, FirstContentRoutingPrefer} {
		t.Run(mode, func(t *testing.T) {
			reg := New(testLogger())
			if err := reg.ConfigureFirstContentRouting(mode); err != nil {
				t.Fatal(err)
			}
			cheap := firstContentTestProvider(t, reg, "cheap-but-too-slow", 4_000, 100)
			feasible := firstContentTestProvider(t, reg, "costlier-but-feasible", 500, 1_800)
			pr := firstContentTestRequest()
			got, decision := reg.ReserveProviderEx(firstContentTestModel, pr)
			want := cheap
			if mode == FirstContentRoutingPrefer {
				want = feasible
			}
			if got != want {
				t.Fatalf("selected=%v, want %s; decision=%+v", got, want.ID, decision)
			}
			if mode != FirstContentRoutingOff {
				status := "infeasible"
				if mode == FirstContentRoutingPrefer {
					status = "feasible"
				}
				if decision.FirstContentMode != mode || decision.FirstContent.Status != status {
					t.Fatalf("winner diagnostics do not describe the active policy: %+v", decision)
				}
			}
			if n := pendingCountOf(got); n != 1 {
				t.Fatalf("selected provider has %d pending requests, want 1", n)
			}
			got.RemovePending(pr.RequestID)
			if pendingCountOf(cheap)+pendingCountOf(feasible) != 0 {
				t.Fatal("reservation leaked to an unselected provider")
			}
		})
	}
}

func firstContentCacheFixture(t *testing.T) (*Registry, *routingCandidate, *PendingRequest, cacheRoutingHint, time.Time) {
	t.Helper()
	r, c, hint := serviceCostFixture(1_000, 0, 0)
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingShadow); err != nil {
		t.Fatal(err)
	}
	insertTestProvider(r, c.provider)
	c.snapshot.modelLoaded = true
	c.snapshot.hasBackendCapacity = true
	c.snapshot.firstContentIdle = true
	c.snapshot.slotState = "idle"
	c.snapshot.isolatedPrefillTPS = 1_000
	c.snapshot.isolatedPrefillInitialized = true
	c.snapshot.observedDecodeTPS = 100
	now := time.Now()
	hint.ExpiresAt = now.Add(time.Minute)
	pr := firstContentTestRequest()
	pr.Model = "model"
	pr.FirstContentDeadline = now.Add(30 * time.Second)
	return r, c, pr, hint, now
}

func TestFirstContentCacheCreditUsesWorkAndPaysRestoreOnce(t *testing.T) {
	for _, capMs := range []float64{0, 100} {
		t.Run(fmt.Sprintf("score-cap-%g", capMs), func(t *testing.T) {
			r, c, pr, hint, now := firstContentCacheFixture(t)
			r.cacheRoutingMaxDiscountMs = &capMs
			hint.EvidenceWeight, hint.StageMs = .5, 1_200
			before := c.costMs
			applyServiceHint(r, c, hint)
			r.estimateFirstContent(c, pr, now)
			// 2,048 policy-weighted cached tokens leave 7,952 fresh tokens
			// at 500 tok/s, then one 1,200ms restore, 660ms early decode,
			// and the 1,000ms handoff allowance: 18,764ms in total.
			if c.firstContent.PredictedMs != 18_764 || c.firstContent.CachedTokens != 2_048 || c.firstContent.RestoreMs != 1_200 {
				t.Fatalf("deadline estimate used score milliseconds or discounted restore: %+v", c.firstContent)
			}
			if before-c.costMs != capMs {
				t.Fatalf("ordinary score cap changed: discount=%g want=%g", before-c.costMs, capMs)
			}
			if pr.EstimatedPromptTokens != 8_000 || pr.FirstContentPromptTokens != 10_000 {
				t.Fatal("cache credit changed admission/token accounting")
			}
		})
	}
}

func TestFirstContentCacheRestoreCanExceedDeadline(t *testing.T) {
	r, c, pr, hint, now := firstContentCacheFixture(t)
	hint.PrefillTokensSaved, hint.StageMs = 10_000, 35_000
	applyServiceHint(r, c, hint)
	r.estimateFirstContent(c, pr, now)
	if c.firstContent.Status != "infeasible" || c.firstContent.PredictedMs != 36_660 || c.firstContent.RestoreMs != 35_000 {
		t.Fatalf("large restore disappeared from complete-prefix prediction: %+v", c.firstContent)
	}
}

func TestFirstContentCacheClampsMatchedWorkBeforeEvidenceWeight(t *testing.T) {
	r, c, pr, hint, now := firstContentCacheFixture(t)
	hint.PrefillTokensSaved, hint.EvidenceWeight = 20_000, .5
	applyServiceHint(r, c, hint)
	r.estimateFirstContent(c, pr, now)
	// The incoming work count limits the possible match before applying the
	// evidence policy. An overlarge hint must not turn half-weight evidence
	// into a claim that the whole prompt is cached.
	if c.firstContent.CachedTokens != 5_000 || c.firstContent.PredictedMs != 11_780 {
		t.Fatalf("overlarge hint bypassed evidence weighting: %+v", c.firstContent)
	}
}

func TestFirstContentCacheRejectsUnusableHolderEvidence(t *testing.T) {
	for _, change := range []string{"missing expiry", "expired", "quarantined", "different provider", "rotated capability", "revoked generation", "zero evidence", "invalid restore"} {
		t.Run(change, func(t *testing.T) {
			r, c, pr, hint, now := firstContentCacheFixture(t)
			switch change {
			case "missing expiry":
				hint.ExpiresAt = time.Time{}
			case "expired":
				hint.ExpiresAt = now.Add(-time.Nanosecond)
			case "quarantined":
				r.disablePrefixCacheV2Model(c.provider.ID, "model", "ssd", c.provider, r.cacheRouting, hint.Capability)
			case "different provider":
				hint.Provider = &Provider{ID: c.provider.ID}
			case "rotated capability":
				c.provider.prefixCacheRevision++
			case "revoked generation":
				hint.generation.revoked.Store(true)
			case "zero evidence":
				hint.EvidenceWeight = 0
			case "invalid restore":
				hint.StageMs = math.NaN()
			}
			applyServiceHint(r, c, hint)
			r.estimateFirstContent(c, pr, now)
			if c.firstContent.CachedTokens != 0 || c.firstContent.RestoreMs != 0 || c.firstContent.PredictedMs != 21_660 {
				t.Fatalf("unusable holder influenced deadline estimate: %+v", c.firstContent)
			}
		})
	}
}

func TestFirstContentRoutingNoFeasibleEvidencePreservesFallback(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*Provider)
	}{
		{"infeasible", func(p *Provider) { *p.BackendCapacity.Slots[0].Telemetry.IsolatedPrefillTPS = 50 }},
		{"missing telemetry", func(p *Provider) { p.BackendCapacity.Slots[0].Telemetry = nil }},
		{"uninitialized", func(p *Provider) { *p.BackendCapacity.Slots[0].Telemetry.EWMAInitialized = false }},
		{"stale capacity", func(p *Provider) { p.capacitySamplesAt = time.Now().Add(-6 * time.Second) }},
		{"missing queue evidence", func(p *Provider) { p.BackendCapacity.Slots[0].Telemetry.QueuedPrefillTokens = nil }},
		{"partial prefill", func(p *Provider) { *p.BackendCapacity.Slots[0].Telemetry.PartialPrefillRows = 1 }},
		{"queued prefill", func(p *Provider) { *p.BackendCapacity.Slots[0].Telemetry.QueuedPrefillTokens = 100 }},
		{"active eval", func(p *Provider) { p.BackendCapacity.Slots[0].EvalInFlightMs = 10 }},
		{"idle clear", func(p *Provider) { p.BackendCapacity.Slots[0].IdleClearInFlightMs = 10 }},
		{"another model running", func(p *Provider) {
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
				Model: "co-resident-model", State: "running", NumRunning: 1,
			})
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			if err := reg.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
				t.Fatal(err)
			}
			cheap := firstContentTestProvider(t, reg, "fallback", 4_000, 100)
			other := firstContentTestProvider(t, reg, "unproven", 500, 1_800)
			other.mu.Lock()
			tc.mutate(other)
			other.mu.Unlock()
			pr := firstContentTestRequest()
			got, _ := reg.ReserveProviderEx(firstContentTestModel, pr)
			if got != cheap {
				t.Fatalf("no proven feasible candidate: selected=%v, want ordinary-score fallback %s", got, cheap.ID)
			}
			got.RemovePending(pr.RequestID)
		})
	}
}

func TestFirstContentRoutingRetainsOwnerPreference(t *testing.T) {
	reg := New(testLogger())
	if err := reg.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	owned := firstContentTestProvider(t, reg, "owned", 4_000, 100)
	owned.mu.Lock()
	owned.AccountID = "request-owner"
	owned.mu.Unlock()
	firstContentTestProvider(t, reg, "public-feasible", 500, 1_800)
	pr := firstContentTestRequest()
	pr.PreferOwner, pr.OwnerAccountID = true, "request-owner"
	got, _ := reg.ReserveProviderEx(firstContentTestModel, pr)
	if got != owned {
		t.Fatalf("deadline preference escaped the owner pool: selected=%v", got)
	}
	got.RemovePending(pr.RequestID)
}

func TestFirstContentRoutingRollbackPreservesOrdinaryVersionPreference(t *testing.T) {
	r := New(testLogger())
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	cheapAvoided := firstContentTestProvider(t, r, "cheap-avoided", 4_000, 100)
	ordinary := firstContentTestProvider(t, r, "ordinary-diverse", 3_000, 100)
	feasibleAvoided := firstContentTestProvider(t, r, "feasible-avoided", 500, 1_800)
	for _, provider := range []*Provider{cheapAvoided, feasibleAvoided} {
		provider.mu.Lock()
		provider.Version = "0.9.1"
		provider.mu.Unlock()
	}
	ordinary.mu.Lock()
	ordinary.Version = "0.9.2"
	ordinary.mu.Unlock()
	request := firstContentTestRequest()
	request.Traits.AvoidVersion = "0.9.1"
	winner, _, plan := r.ReserveProviderWithPlan(request.Model, request)
	if winner != feasibleAvoided || plan == nil {
		t.Fatalf("feasibility did not precede soft version preference: %v", winner)
	}
	if err := r.ConfigureFirstContentRouting(FirstContentRoutingOff); err != nil {
		t.Fatal(err)
	}
	retry := firstContentTestRequest()
	retry.RequestID = "rollback-retry"
	retry.Traits.AvoidVersion = request.Traits.AvoidVersion
	winner, _, _ = r.ReserveNextFromPlan(retry, plan)
	if winner != ordinary {
		t.Fatalf("ordinary rollback pool lost version narrowing: got %v", winner)
	}
}

func TestFirstContentRoutingReconsidersRateChangeAtCommit(t *testing.T) {
	reg := New(testLogger())
	if err := reg.ConfigureFirstContentRouting(FirstContentRoutingPrefer); err != nil {
		t.Fatal(err)
	}
	changed := firstContentTestProvider(t, reg, "initially-feasible", 4_000, 1_800)
	stillFeasible := firstContentTestProvider(t, reg, "still-feasible", 500, 1_800)
	var once sync.Once
	reg.reservationAfterScan = func(string) {
		once.Do(func() {
			changed.mu.Lock()
			*changed.BackendCapacity.Slots[0].Telemetry.IsolatedPrefillTPS = 100
			changed.mu.Unlock()
		})
	}
	pr := firstContentTestRequest()
	got, _ := reg.ReserveProviderEx(firstContentTestModel, pr)
	if got != stillFeasible {
		t.Fatalf("committed stale feasible winner: got=%v, want %s", got, stillFeasible.ID)
	}
	if n := pendingCountOf(changed); n != 0 {
		t.Fatalf("discarded candidate retained %d reservations", n)
	}
	got.RemovePending(pr.RequestID)
}

func firstContentEstimateFixture() (*routingCandidate, *PendingRequest, time.Time) {
	now := time.Now()
	c := &routingCandidate{costMs: 1234, snapshot: routingSnapshot{
		modelLoaded: true, hasBackendCapacity: true, slotState: "idle",
		firstContentIdle: true, isolatedPrefillTPS: 2_000, isolatedPrefillInitialized: true,
		observedDecodeTPS: 100,
	}}
	pr := firstContentTestRequest()
	pr.FirstContentDeadline = now.Add(30 * time.Second)
	return c, pr, now
}

func TestFirstContentEstimateUsesConservativePromptAndDecodeLead(t *testing.T) {
	reg := New(testLogger())
	if err := reg.ConfigureFirstContentRouting(FirstContentRoutingShadow); err != nil {
		t.Fatal(err)
	}
	for _, maxTokens := range []int{0, 1, 16, 33, 4_096} {
		t.Run(fmt.Sprint(maxTokens), func(t *testing.T) {
			c, pr, now := firstContentEstimateFixture()
			pr.RequestedMaxTokens = maxTokens
			reg.estimateFirstContent(c, pr, now)
			lead := max(1, min(maxTokens, 33))
			want := 10_000.0 + float64(lead)/50*1_000 + 1_000
			if c.firstContent.Status != "feasible" || math.Abs(c.firstContent.PredictedMs-want) > 1e-8 {
				t.Fatalf("estimate=%+v, want feasible %.3fms", c.firstContent, want)
			}
			if c.firstContent.PromptTokens != 10_000 || c.costMs != 1234 || pr.EstimatedPromptTokens != 8_000 {
				t.Fatal("service prediction must use its conservative work count without changing ordinary cost or token accounting")
			}
			if c.firstContent.BudgetMs != 30_000 {
				t.Fatalf("budget=%f, want request-absolute deadline remaining 30000ms", c.firstContent.BudgetMs)
			}
		})
	}
	for _, prompt := range []int{8_192, 16_384, 32_768} {
		t.Run(fmt.Sprintf("prompt-%d", prompt), func(t *testing.T) {
			c, pr, now := firstContentEstimateFixture()
			pr.FirstContentPromptTokens = 0
			pr.EstimatedPromptTokens = prompt
			reg.estimateFirstContent(c, pr, now)
			want := float64(prompt) + 660 + 1_000
			if math.Abs(c.firstContent.PredictedMs-want) > 1e-8 || c.firstContent.PromptTokens != prompt {
				t.Fatalf("estimate=%+v, want raw prompt fallback %d tokens and %.3fms", c.firstContent, prompt, want)
			}
			status := "feasible"
			if want > 30_000 {
				status = "infeasible"
			}
			if c.firstContent.Status != status {
				t.Fatalf("status=%s, want %s", c.firstContent.Status, status)
			}
		})
	}
}

func TestFirstContentEstimateUnknownForUnsupportedEvidence(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*routingCandidate, *PendingRequest)
	}{
		{"no absolute deadline", func(_ *routingCandidate, p *PendingRequest) { p.FirstContentDeadline = time.Time{} }},
		{"vision", func(_ *routingCandidate, p *PendingRequest) { p.RequiresVision = true }},
		{"cold", func(c *routingCandidate, _ *PendingRequest) { c.snapshot.modelLoaded = false }},
		{"stale", func(c *routingCandidate, _ *PendingRequest) { c.snapshot.capacityAgeMs = 5_001 }},
		{"busy box", func(c *routingCandidate, _ *PendingRequest) { c.snapshot.firstContentIdle = false }},
		{"uninitialized rate", func(c *routingCandidate, _ *PendingRequest) { c.snapshot.isolatedPrefillInitialized = false }},
		{"zero prefill rate", func(c *routingCandidate, _ *PendingRequest) { c.snapshot.isolatedPrefillTPS = 0 }},
		{"nan prefill rate", func(c *routingCandidate, _ *PendingRequest) { c.snapshot.isolatedPrefillTPS = math.NaN() }},
		{"infinite prefill rate", func(c *routingCandidate, _ *PendingRequest) { c.snapshot.isolatedPrefillTPS = math.Inf(1) }},
		{"zero decode rate", func(c *routingCandidate, _ *PendingRequest) { c.snapshot.observedDecodeTPS = 0 }},
		{"nan decode rate", func(c *routingCandidate, _ *PendingRequest) { c.snapshot.observedDecodeTPS = math.NaN() }},
		{"infinite decode rate", func(c *routingCandidate, _ *PendingRequest) { c.snapshot.observedDecodeTPS = math.Inf(1) }},
	}
	reg := New(testLogger())
	if err := reg.ConfigureFirstContentRouting(FirstContentRoutingShadow); err != nil {
		t.Fatal(err)
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, pr, now := firstContentEstimateFixture()
			tc.mutate(c, pr)
			reg.estimateFirstContent(c, pr, now)
			if c.firstContent.Status != "unknown" || c.firstContent.Reason == "" {
				t.Fatalf("unsupported evidence must remain explicitly unknown: %+v", c.firstContent)
			}
		})
	}
}
