package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func warmWorkCapacity(epoch string, prompt, prefills, output, generations int64) *protocol.BackendCapacity {
	return &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "m", State: "idle", PerformanceMeasurements: &protocol.PerformanceMeasurements{Epoch: epoch}, Telemetry: &protocol.SlotTelemetry{
		PrefillTokensTotal: &prompt, PrefillRequestsTotal: &prefills,
		GeneratedTokensTotal: &output, GenerationRequestsTotal: &generations,
	}}}}
}

func TestWarmWorkBaselinesResetsAndPartialOutput(t *testing.T) {
	r := New(testLogger())
	r.ConfigureWarmPool(testWarmPoolConfig())
	p := &Provider{}
	now := time.Now()
	p.reconcileWarmPoolWorkLocked(warmWorkCapacity("a", 10000, 10, 1000, 10), now, r.warmPool, map[string]bool{"m": true})
	if len(r.warmPool.state.snapshot(now, time.Minute)) != 0 {
		t.Fatal("historic baseline became fresh demand")
	}
	p.reconcileWarmPoolWorkLocked(warmWorkCapacity("a", 18000, 18, 1080, 18), now.Add(time.Second), r.warmPool, map[string]bool{"m": true})
	b := r.warmPool.state.snapshot(now.Add(time.Second), time.Minute)["m"]
	if b.promptWork.tokens != 1000 || b.outputWork.tokens != 10 || !b.outputWork.measured(now.Add(time.Second)) {
		t.Fatalf("actual partial output/cold work lost: %+v", b)
	}
	for _, capacity := range []*protocol.BackendCapacity{
		warmWorkCapacity("a", 18000, 18, 1080, 18),       // duplicate counters
		warmWorkCapacity("new", 180000, 180, 10800, 180), // reload between frames
		warmWorkCapacity("new", 1, 1, 1, 1),              // reset
		nil,
		warmWorkCapacity("new", 100000, 100, 10000, 100), // reappearance baseline
	} {
		p.reconcileWarmPoolWorkLocked(capacity, now.Add(2*time.Second), r.warmPool, map[string]bool{"m": true})
	}
	if got := r.warmPool.state.snapshot(now.Add(2*time.Second), time.Minute)["m"]; got.promptWork.count != 8 || got.outputWork.count != 8 {
		t.Fatalf("replay/reset fabricated work: %+v", got)
	}
}

func TestWarmWorkWeightsSamplesAndExpires(t *testing.T) {
	now := time.Now()
	var many, one warmWorkMean
	many.add(800, 8, now)
	one = many
	many.add(8000, 8, now.Add(time.Second))
	one.add(1000, 1, now.Add(time.Second))
	if many.tokens <= one.tokens {
		t.Fatal("heartbeat batches must be weighted by sample count")
	}
	defaults := warmTargetParams{AssumedPromptTokens: 4000, AssumedCompletionTokens: 256}
	b := warmPoolPressureBucket{promptWork: many, outputWork: one}
	if got := measuredWarmServiceParams(defaults, b, now.Add(time.Second)); got.AssumedPromptTokens == 4000 {
		t.Fatal("fresh measured shape ignored")
	}
	if got := measuredWarmServiceParams(defaults, b, now.Add(warmWorkFreshness+2*time.Second)); got.AssumedPromptTokens != 4000 {
		t.Fatal("stale shape did not fall back")
	}
	var reused warmWorkMean
	reused.add(0, 8, now)
	if !reused.measured(now) || reused.tokens != 0 {
		t.Fatal("fully reused prompts are real zero compute")
	}
	reused.add(1000, 0, now)
	if reused.tokens != 0 {
		t.Fatal("unpaired counters became a workload mean")
	}
}

func TestWarmWorkRatesSumProvidersWithoutHeartbeatAmplification(t *testing.T) {
	now := time.Now()
	s := newWarmPoolState()
	s.recordWork("m", 8000, 8, 800, 8, now)
	s.recordWork("m", 8000, 8, 800, 8, now.Add(time.Second))
	s.foldWorkRates(now.Add(time.Second), 5*time.Second)
	if got := s.snapshot(now.Add(time.Second), time.Minute)["m"].promptWorkRate; got != 0 {
		t.Fatal("early fold amplified event heartbeat")
	}
	s.foldWorkRates(now.Add(10*time.Second), 5*time.Second)
	b := s.snapshot(now.Add(10*time.Second), time.Minute)["m"]
	if b.promptWorkRate != 1600 || b.outputWorkRate != 160 {
		t.Fatalf("rates = %v/%v", b.promptWorkRate, b.outputWorkRate)
	}
	f := warmPoolModelSnapshot{prefillTPS: 1000, aggregateDecodeTPS: 400}
	if got := measuredWorkProviders(f, b, now.Add(10*time.Second)); got != 2 {
		t.Fatalf("prompt+generation work = %v, want 2 Macs", got)
	}
	input := warmTargetInputs{Warm: 1, EligibleCold: 9, QualityConcurrency: 8, WorkProviders: 2}
	if got := warmTarget(input, warmTargetParams{HeadroomEnabledParams: true}, time.Second); got != 2 {
		t.Fatalf("target = %d, want 2", got)
	}
	input.DemandPressure = true // cold/refused demand stays visible independently
	if got := warmTarget(input, warmTargetParams{}, time.Second); got < 2 {
		t.Fatal("served-only work erased refused demand")
	}
}

func TestWarmWorkRejectsStaleCapacitySequence(t *testing.T) {
	r := New(testLogger())
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
	b := r.warmPool.state.snapshot(time.Now(), time.Minute)["m"]
	if b.promptWork.count != 8 || b.promptWork.tokens != 1000 {
		t.Fatalf("stale counter applied: %+v", b)
	}
}

func TestWarmWorkLongReportingGapRebaselines(t *testing.T) {
	r := New(testLogger())
	r.ConfigureWarmPool(testWarmPoolConfig())
	p := &Provider{}
	now := time.Now()
	p.reconcileWarmPoolWorkLocked(warmWorkCapacity("a", 0, 0, 0, 0), now, r.warmPool, map[string]bool{"m": true})
	p.reconcileWarmPoolWorkLocked(warmWorkCapacity("a", 100000, 100, 10000, 100), now.Add(time.Hour), r.warmPool, map[string]bool{"m": true})
	if len(r.warmPool.state.snapshot(now.Add(time.Hour), time.Minute)) != 0 {
		t.Fatal("hour of unobserved history became a fresh burst")
	}
}

func TestWarmPoolUsesQualifiedCapacityAndOperatorCap(t *testing.T) {
	p, _ := reviewedProfileFixture(t)
	r := New(testLogger())
	params := warmTargetParams{DecodeFloorTPS: 30, LoadFactorK: effectiveTPSLoadFactor, FallbackQualityConcurrency: 1}
	quality, aggregate, prefill := r.warmPoolCapacityLocked(p, "model", params)
	if quality != 16 || aggregate != 700 || prefill != 6000 {
		t.Fatalf("qualified capacity = %d/%v/%v", quality, aggregate, prefill)
	}
	p.BackendCapacity.Slots[0].MaxConcurrency = 3
	quality, aggregate, _ = r.warmPoolCapacityLocked(p, "model", params)
	if quality != 3 || aggregate != 105 {
		t.Fatalf("operator intermediate cap extrapolated aggregate: %d/%v", quality, aggregate)
	}
}

func TestWarmPoolRefusedPromptWorkIsIndependentOfDecodeWidth(t *testing.T) {
	for _, prompt := range []struct {
		tokens int
		work   time.Duration
		target int
	}{
		{tokens: 64000, work: 64 * time.Second, target: 8},
		{tokens: 256000, work: warmPoolMaxServiceTime, target: 15},
	} {
		for _, width := range []int{1, 4, 16} {
			t.Run(fmt.Sprintf("prompt_%d_width_%d", prompt.tokens, width), func(t *testing.T) {
				reg := New(testLogger())
				const model = "refused-long-prompt"
				for i := 0; i < 20; i++ {
					p := makeWarmPoolColdProvider(t, reg, fmt.Sprintf("cold-%d", i), model, 50, 64, 8)
					p.mu.Lock()
					p.BackendCapacity.Slots = []protocol.BackendSlotCapacity{{
						Model: model, State: "idle_shutdown", MaxConcurrency: width,
						ObservedPrefillTPS: 1000,
					}}
					p.mu.Unlock()
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
				reg.warmPool.state.recordEvent(model, warmPoolEventCapacityReject, now)
				reg.warmPool.state.foldArrivalRates(now, time.Second, 1)
				snaps := reg.warmPool.planObserveOnly(now.Add(8*time.Second), nil)
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
