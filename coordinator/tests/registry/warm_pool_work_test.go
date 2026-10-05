package registry_test

import (
	"testing"
	"time"

	"fmt"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestWarmWorkWeightsSamplesAndExpires(t *testing.T) {
	now := time.Now()
	var many, one warmplan.WorkMean
	many.Add(800, 8, now)
	one = many
	many.Add(8000, 8, now.Add(time.Second))
	one.Add(1000, 1, now.Add(time.Second))
	if many.Tokens <= one.Tokens {
		t.Fatal("heartbeat batches must be weighted by sample count")
	}
	defaults := warmplan.TargetParams{AssumedPromptTokens: 4000, AssumedCompletionTokens: 256}
	b := warmplan.Pressure{PromptWork: many, OutputWork: one}
	if got := warmplan.MeasuredWarmServiceParams(defaults, b, now.Add(time.Second)); got.AssumedPromptTokens == 4000 {
		t.Fatal("fresh measured shape ignored")
	}
	if got := warmplan.MeasuredWarmServiceParams(defaults, b, now.Add(warmplan.WarmWorkFreshness+2*time.Second)); got.AssumedPromptTokens != 4000 {
		t.Fatal("stale shape did not fall back")
	}
	var reused warmplan.WorkMean
	reused.Add(0, 8, now)
	if !reused.Measured(now) || reused.Tokens != 0 {
		t.Fatal("fully reused prompts are real zero compute")
	}
	reused.Add(1000, 0, now)
	if reused.Tokens != 0 {
		t.Fatal("unpaired counters became a workload mean")
	}
}

func TestWarmWorkRatesSumProvidersWithoutHeartbeatAmplification(t *testing.T) {
	now := time.Now()
	s := warmplan.NewState()
	s.RecordWork("m", 8000, 8, 800, 8, now)
	s.RecordWork("m", 8000, 8, 800, 8, now.Add(time.Second))
	s.FoldWorkRates(now.Add(time.Second), 5*time.Second)
	if got := s.Snapshot(now.Add(time.Second), time.Minute)["m"].PromptWorkRate; got != 0 {
		t.Fatal("early fold amplified event heartbeat")
	}
	s.FoldWorkRates(now.Add(10*time.Second), 5*time.Second)
	b := s.Snapshot(now.Add(10*time.Second), time.Minute)["m"]
	if b.PromptWorkRate != 1600 || b.OutputWorkRate != 160 {
		t.Fatalf("rates = %v/%v", b.PromptWorkRate, b.OutputWorkRate)
	}
	f := warmplan.Fleet{PrefillTPS: 1000, AggregateDecodeTPS: 400}
	if got := warmplan.MeasuredWorkProviders(f, b, now.Add(10*time.Second)); got != 2 {
		t.Fatalf("prompt+generation work = %v, want 2 Macs", got)
	}
	input := warmplan.TargetInputs{Warm: 1, EligibleCold: 9, QualityConcurrency: 8, WorkProviders: 2}
	if got := warmplan.WarmTarget(input, warmplan.TargetParams{HeadroomEnabledParams: true}, time.Second); got != 2 {
		t.Fatalf("target = %d, want 2", got)
	}
	input.DemandPressure = true // cold/refused demand stays visible independently
	if got := warmplan.WarmTarget(input, warmplan.TargetParams{}, time.Second); got < 2 {
		t.Fatal("served-only work erased refused demand")
	}
}

func warmWorkCapacity(epoch string, prompt, prefills, output, generations int64) *protocol.BackendCapacity {
	return &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "m", State: "idle", PerformanceMeasurements: &protocol.PerformanceMeasurements{Epoch: epoch}, Telemetry: &protocol.SlotTelemetry{
		PrefillTokensTotal: &prompt, PrefillRequestsTotal: &prefills,
		GeneratedTokensTotal: &output, GenerationRequestsTotal: &generations,
	}}}}
}

func TestWarmWorkRejectsStaleCapacitySequence(t *testing.T) {
	r := newWarmRegistry(t)
	p := makeSchedulerProvider(t, r, "p", "m", 100)
	r.ConfigureWarmPool(testWarmPoolConfig())
	first := warmWorkCapacity("a", 0, 0, 0, 0)
	first.CapacitySeq = 1
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: first})
	fresh := warmWorkCapacity("a", 8000, 8, 800, 8)
	fresh.CapacitySeq = 3
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: fresh})
	stale := warmWorkCapacity("a", 800000, 800, 80000, 800)
	stale.CapacitySeq = 2
	if r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: stale}) {
		t.Fatal("stale sequence accepted")
	}
	b := warmFixtureFor(r).deps.State.Snapshot(time.Now(), time.Minute)["m"]
	if b.PromptWork.Count != 8 || b.PromptWork.Tokens != 1000 {
		t.Fatalf("stale counter applied: %+v", b)
	}
}

func TestWarmPoolRefusedPromptWorkIsIndependentOfDecodeWidth(t *testing.T) {
	for _, prompt := range []struct {
		tokens int
		work   time.Duration
		target int
	}{
		{tokens: 64000, work: 64 * time.Second, target: 8},
		{tokens: 256000, work: warmplan.WarmPoolMaxServiceTime, target: 15},
	} {
		for _, width := range []int{1, 4, 16} {
			t.Run(fmt.Sprintf("prompt_%d_width_%d", prompt.tokens, width), func(t *testing.T) {
				reg := newWarmRegistry(t)
				const model = "refused-long-prompt"
				for i := 0; i < 20; i++ {
					p := makeWarmPoolColdProvider(t, reg, fmt.Sprintf("cold-%d", i), model, 50, 64, 8)
					p.Mu().Lock()
					p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{
						Model: model, State: "idle_shutdown", MaxConcurrency: width,
						ObservedPrefillTPS: 1000,
					}}
					p.Mu().Unlock()
				}
				cfg := testWarmPoolConfig()
				cfg.ObserveOnly = true
				cfg.AssumedPromptTokens = prompt.tokens
				cfg.AssumedCompletionTokens = 0
				reg.ConfigureWarmPool(cfg)

				// All offered work was refused: one arrival per eight seconds.
				// No running request or completed-work counter can rescue an
				// understated spill target. Decode width does not parallelize
				// this serial prompt work, and its clamp is in Mac-time units.
				now := time.Now()
				warmFixtureFor(reg).deps.State.RecordEvent(model, warmplan.WarmPoolEventCapacityReject, now)
				warmFixtureFor(reg).deps.State.FoldArrivalRates(now, time.Second, 1)
				snaps := warmFixtureFor(reg).runtime.PlanObserveOnly(now.Add(8*time.Second), nil)
				if len(snaps) != 1 {
					t.Fatalf("snapshots = %d, want 1", len(snaps))
				}
				snap := snaps[0]
				if snap.WorkProviders != 0 || snap.RunningRequests != 0 || snap.SpillArrivalRate != 0.125 {
					t.Fatalf("expected refused-only demand, got %+v", snap)
				}
				if snap.TargetWarm != prompt.target {
					t.Fatalf("target = %d, want %d Macs for refused prompt work", snap.TargetWarm, prompt.target)
				}
				if snap.QualityConcurrency != width || snap.ServiceTime != prompt.work*time.Duration(width) {
					t.Fatalf("quality/service = %d/%v, want %d/%v", snap.QualityConcurrency, snap.ServiceTime, width, prompt.work*time.Duration(width))
				}
			})
		}
	}
}

func TestWarmWorkBaselinesResetsAndPartialOutput(t *testing.T) {
	r := newWarmRegistry(t)
	r.ConfigureWarmPool(testWarmPoolConfig())
	p := new(warmplan.WorkHistory)
	now := time.Now()
	p.Reconcile(warmWorkCapacity("a", 10000, 10, 1000, 10), now, warmFixtureFor(r).deps.State, map[string]bool{"m": true}, 2*time.Minute)
	if len(warmFixtureFor(r).deps.State.Snapshot(now, time.Minute)) != 0 {
		t.Fatal("historic baseline became fresh demand")
	}
	p.Reconcile(warmWorkCapacity("a", 18000, 18, 1080, 18), now.Add(time.Second), warmFixtureFor(r).deps.State, map[string]bool{"m": true}, 2*time.Minute)
	b := warmFixtureFor(r).deps.State.Snapshot(now.Add(time.Second), time.Minute)["m"]
	if b.PromptWork.Tokens != 1000 || b.OutputWork.Tokens != 10 || !b.OutputWork.Measured(now.Add(time.Second)) {
		t.Fatalf("actual partial output/cold work lost: %+v", b)
	}
	for _, capacity := range []*protocol.BackendCapacity{
		warmWorkCapacity("a", 18000, 18, 1080, 18),       // duplicate counters
		warmWorkCapacity("new", 180000, 180, 10800, 180), // reload between frames
		warmWorkCapacity("new", 1, 1, 1, 1),              // reset
		nil,
		warmWorkCapacity("new", 100000, 100, 10000, 100), // reappearance baseline
	} {
		p.Reconcile(capacity, now.Add(2*time.Second), warmFixtureFor(r).deps.State, map[string]bool{"m": true}, 2*time.Minute)
	}
	if got := warmFixtureFor(r).deps.State.Snapshot(now.Add(2*time.Second), time.Minute)["m"]; got.PromptWork.Count != 8 || got.OutputWork.Count != 8 {
		t.Fatalf("replay/reset fabricated work: %+v", got)
	}
}

func TestWarmWorkLongReportingGapRebaselines(t *testing.T) {
	r := newWarmRegistry(t)
	r.ConfigureWarmPool(testWarmPoolConfig())
	p := new(warmplan.WorkHistory)
	now := time.Now()
	p.Reconcile(warmWorkCapacity("a", 0, 0, 0, 0), now, warmFixtureFor(r).deps.State, map[string]bool{"m": true}, 2*time.Minute)
	p.Reconcile(warmWorkCapacity("a", 100000, 100, 10000, 100), now.Add(time.Hour), warmFixtureFor(r).deps.State, map[string]bool{"m": true}, 2*time.Minute)
	if len(warmFixtureFor(r).deps.State.Snapshot(now.Add(time.Hour), time.Minute)) != 0 {
		t.Fatal("hour of unobserved history became a fresh burst")
	}
}

func TestWarmPoolUsesQualifiedCapacityAndOperatorCap(t *testing.T) {
	var fleet func(time.Time) map[string]warmplan.Fleet
	r, p, _ := reviewedServingProvider(t, func(deps *production.Dependencies) {
		deps.WarmPlanning = func(deps warmplan.Dependencies[production.ModelLoadAction]) *warmplan.Controller[production.ModelLoadAction] {
			fleet = deps.Fleet
			return warmplan.NewController(deps)
		}
	})
	cfg := testWarmPoolConfig()
	cfg.DecodeFloorTPS, cfg.FallbackQualityConcurrency = 30, 1
	r.ConfigureWarmPool(cfg)
	snapshot := fleet(time.Now())["model"]
	quality, aggregate, prefill := snapshot.QualityConc, snapshot.AggregateDecodeTPS, snapshot.PrefillTPS
	if quality != 16 || aggregate != 700 || prefill != 6000 {
		t.Fatalf("qualified capacity = %d/%v/%v", quality, aggregate, prefill)
	}
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].MaxConcurrency = 3
	p.Mu().Unlock()
	snapshot = fleet(time.Now())["model"]
	quality, aggregate = snapshot.QualityConc, snapshot.AggregateDecodeTPS
	if quality != 3 || aggregate != 105 {
		t.Fatalf("operator intermediate cap extrapolated aggregate: %d/%v", quality, aggregate)
	}
}
