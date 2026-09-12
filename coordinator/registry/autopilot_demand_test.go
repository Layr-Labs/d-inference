package registry

import (
	"fmt"
	"math"
	"reflect"
	"sync"
	"testing"
	"time"
)

func autopilotDemandTestClock() time.Time {
	return time.Date(2026, 9, 11, 23, 0, 0, 0, time.UTC)
}

func autopilotDemandTestSample(at time.Time) AutopilotDemandSample {
	return AutopilotDemandSample{
		Model: "model", ReceivedAt: at, PromptTokens: 27, RequestedMaxTokens: 1024,
	}
}

func TestAutopilotDemandArrivalWindowDoesNotShiftToTerminal(t *testing.T) {
	now := autopilotDemandTestClock()
	window := 5 * time.Minute
	var d autopilotDemandTracker
	s := autopilotDemandTestSample(now.Add(-4 * time.Minute))
	s.CapacityShed, s.Reason = true, "deadline"
	d.record(s, now, window)
	v := d.snapshot(now, window)["model"]
	if v.Requests != 1 || v.CapacityShed != 1 || !v.LastDemand.Equal(s.ReceivedAt) {
		t.Fatalf("terminal replaced arrival: %+v", v)
	}
	// No fast-window request: a delayed terminal must not create a fresh spike.
	if math.Abs(v.Rate-1.0/240) > 1e-12 {
		t.Fatalf("delayed terminal rate=%g, want 1/240", v.Rate)
	}
	v = d.snapshot(now.Add(time.Minute+autopilotDemandBucketWidth), window)["model"]
	if v.Requests != 0 || v.Rate != 0 || !v.LastDemand.Equal(s.ReceivedAt) {
		t.Fatalf("expired arrival was renewed by its terminal: %+v", v)
	}
}

func TestAutopilotDemandOutOfOrderCompletionsCoalesceArrivalBuckets(t *testing.T) {
	now := autopilotDemandTestClock()
	window := 5 * time.Minute
	offsets := []time.Duration{-3 * time.Minute, -time.Second, -4 * time.Minute, -2 * time.Second, -2 * time.Minute}
	var forward, reverse autopilotDemandTracker
	for i := range offsets {
		forward.record(autopilotDemandTestSample(now.Add(offsets[i])), now, window)
		reverse.record(autopilotDemandTestSample(now.Add(offsets[len(offsets)-1-i])), now, window)
	}
	a, b := forward.snapshot(now, window), reverse.snapshot(now, window)
	if !reflect.DeepEqual(a, b) || a["model"].Requests != len(offsets) {
		t.Fatalf("completion order changed demand: forward=%+v reverse=%+v", a, b)
	}
	buckets := forward.models["model"].buckets
	if len(buckets) != 4 || buckets[len(buckets)-1].requests != 2 {
		t.Fatalf("same arrival interval was duplicated: %+v", buckets)
	}
	for i := 1; i < len(buckets); i++ {
		if !buckets[i-1].at.Before(buckets[i].at) {
			t.Fatalf("arrival buckets are not strictly sorted: %+v", buckets)
		}
	}
}

func TestAutopilotDemandArrivalClockBoundaryAndFallback(t *testing.T) {
	now := autopilotDemandTestClock()
	window := 5 * time.Minute
	for _, tc := range []struct {
		name    string
		arrival time.Time
		want    int
	}{
		{"exact old boundary", now.Add(-window), 1},
		{"older than window", now.Add(-window - time.Nanosecond), 0},
		{"future clock", now.Add(time.Nanosecond), 0},
		{"exact current time", now, 1},
		{"missing clock fallback", time.Time{}, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var d autopilotDemandTracker
			d.record(autopilotDemandTestSample(tc.arrival), now, window)
			v := d.snapshot(now, window)["model"]
			if v.Requests != tc.want {
				t.Fatalf("requests=%d, want %d", v.Requests, tc.want)
			}
			if tc.arrival.IsZero() && !v.LastDemand.Equal(now) {
				t.Fatalf("missing arrival did not use explicit fallback: %+v", v)
			}
		})
	}
}

func TestAutopilotDemandPartialBucketRetentionIsBounded(t *testing.T) {
	now := autopilotDemandTestClock()
	window := time.Minute
	var d autopilotDemandTracker
	d.record(autopilotDemandTestSample(now), now, window)
	// An unaligned cutoff retains the intersecting interval, at most <10s.
	if got := d.snapshot(now.Add(window+9*time.Second), window)["model"].Requests; got != 1 {
		t.Fatalf("intersecting bucket discarded: %d", got)
	}
	if got := d.snapshot(now.Add(window+10*time.Second), window)["model"].Requests; got != 0 {
		t.Fatalf("old bucket survived its upper bound: %d", got)
	}
}

func TestAutopilotDemandOutputAndWarmServiceHaveIndependentSamples(t *testing.T) {
	now := autopilotDemandTestClock()
	window := 5 * time.Minute
	var d autopilotDemandTracker
	for i := 0; i < 8; i++ {
		s := autopilotDemandTestSample(now)
		s.Completed, s.ObservedOutputTokens = true, 2000
		// Both unknown/cold timing and overly long service retain actual output.
		if i%2 == 0 {
			s.ServiceTime = 11 * time.Minute
		}
		d.record(s, now, window)
	}
	v := d.snapshot(now, window)["model"]
	if v.Completed != 8 || v.OutputTokens != 2000 || v.ServiceSamples != 0 || v.ServiceSeconds != 0 {
		t.Fatalf("valid outputs depended on warm timing: %+v", v)
	}
	for i := 0; i < 8; i++ {
		s := autopilotDemandTestSample(now)
		s.Completed, s.ObservedOutputTokens, s.ServiceTime = true, 1000, 10*time.Second
		d.record(s, now, window)
	}
	v = d.snapshot(now, window)["model"]
	if v.Completed != 16 || v.OutputTokens != 1500 || v.ServiceSamples != 8 || v.ServiceSeconds != 10 {
		t.Fatalf("service mean used output-sample denominator: %+v", v)
	}
}

func TestAutopilotDemandCompletionBoundsAndSparsePriors(t *testing.T) {
	now := autopilotDemandTestClock()
	window := 5 * time.Minute
	var d autopilotDemandTracker
	for i := 0; i < 7; i++ {
		s := autopilotDemandTestSample(now)
		s.Completed, s.ObservedOutputTokens, s.ServiceTime = true, 0, 2*time.Second
		d.record(s, now, window)
	}
	v := d.snapshot(now, window)["model"]
	if v.Completed != 7 || v.ServiceSamples != 7 || v.OutputTokens != 256 || v.ServiceSeconds != 0 {
		t.Fatalf("sparse observations replaced conservative priors: %+v", v)
	}
	for _, output := range []int{-1, autopilotDemandMaxTokens + 1} {
		s := autopilotDemandTestSample(now)
		s.Completed, s.ObservedOutputTokens, s.ServiceTime = true, output, time.Second
		d.record(s, now, window)
	}
	s := autopilotDemandTestSample(now)
	s.Completed, s.ObservedOutputTokens, s.ServiceTime = true, 0, 2*time.Second
	d.record(s, now, window)
	v = d.snapshot(now, window)["model"]
	if v.Completed != 8 || v.ServiceSamples != 8 || v.OutputTokens != 1 || v.ServiceSeconds != 2 {
		t.Fatalf("invalid/zero output or service handling changed: %+v", v)
	}
}

func TestAutopilotDemandMeanWorkIsSeparateFromTailFit(t *testing.T) {
	now := autopilotDemandTestClock()
	var d autopilotDemandTracker
	for i := 0; i < 10; i++ {
		s := autopilotDemandTestSample(now)
		s.PromptTokens = 25
		if i >= 8 {
			s.PromptTokens = 4096
		}
		d.record(s, now, 5*time.Minute)
	}
	v := d.snapshot(now, 5*time.Minute)["model"]
	if v.PromptTokens != 840 || v.TailPromptTokens != 4096 {
		t.Fatalf("tail inflated average work or tail lost: %+v", v)
	}
}

func TestAutopilotDemandLogicalTerminalReasonsDoNotMultiplyArrivals(t *testing.T) {
	now := autopilotDemandTestClock()
	var d autopilotDemandTracker
	for _, reason := range []string{"deadline", "capacity_shed", "completed", "client_departure"} {
		s := autopilotDemandTestSample(now)
		s.Reason = reason
		s.CapacityShed = reason == "deadline" || reason == "capacity_shed"
		d.record(s, now, 5*time.Minute)
	}
	v := d.snapshot(now, 5*time.Minute)["model"]
	// API owns once-only delivery across retries; this layer never turns an
	// exhausted ladder or a shed flag into additional logical arrival counts.
	if v.Requests != 4 || v.CapacityShed != 2 || v.PromptTokens != 27 || v.TailPromptTokens != 64 {
		t.Fatalf("reason changed logical count or excluded honest short input: %+v", v)
	}
}

func TestAutopilotDemandExcludesIntrinsicAndCoordinatorSaturation(t *testing.T) {
	now := autopilotDemandTestClock()
	var d autopilotDemandTracker
	for _, reason := range []string{"intrinsic_unservable", "routing_saturated"} {
		s := autopilotDemandTestSample(now)
		s.Reason, s.CapacityShed = reason, true
		d.record(s, now, 5*time.Minute)
	}
	if len(d.models) != 0 || len(d.snapshot(now, 5*time.Minute)) != 0 {
		t.Fatal("excluded reasons created a model target")
	}
}

func TestAutopilotDemandBoundedCardinalityAndExpiredReplacement(t *testing.T) {
	now := autopilotDemandTestClock()
	window := time.Minute
	var d autopilotDemandTracker
	for i := 0; i < autopilotDemandMaxModels+1; i++ {
		s := autopilotDemandTestSample(now)
		s.Model = fmt.Sprintf("model-%03d", i)
		d.record(s, now, window)
	}
	if len(d.models) != autopilotDemandMaxModels {
		t.Fatalf("unbounded model count: %d", len(d.models))
	}
	later := now.Add(2*window + time.Second)
	s := autopilotDemandTestSample(later)
	s.Model = "model-000" // renewal must expire even if snapshot has not run
	d.record(s, later, window)
	v := d.snapshot(later, window)[s.Model]
	if len(d.models) != 1 || v.Requests != 1 || !d.models[s.Model].first.Equal(later) {
		t.Fatalf("old model state biased renewed demand: models=%d view=%+v", len(d.models), v)
	}
}

func TestAutopilotDemandBoundedBucketsOverLongRun(t *testing.T) {
	now := autopilotDemandTestClock()
	window := time.Minute
	var d autopilotDemandTracker
	for i := 0; i < 3600; i++ {
		at := now.Add(time.Duration(i) * time.Second)
		d.record(autopilotDemandTestSample(at), at, window)
		if n := len(d.models["model"].buckets); n > int(window/autopilotDemandBucketWidth)+1 {
			t.Fatalf("unbounded arrival intervals after %d seconds: %d", i, n)
		}
	}
	later := now.Add(time.Hour + 2*window)
	if len(d.snapshot(later, window)) != 0 || len(d.models) != 0 {
		t.Fatal("idle model storage was not reclaimed")
	}
}

func TestAutopilotDemandRejectsInvalidWindowAndEnvelope(t *testing.T) {
	now := autopilotDemandTestClock()
	for _, window := range []time.Duration{0, -time.Second, autopilotDemandMaxWindow + time.Second} {
		var d autopilotDemandTracker
		d.record(autopilotDemandTestSample(now), now, window)
		if len(d.models) != 0 || len(d.snapshot(now, window)) != 0 {
			t.Fatalf("invalid window retained state: %s", window)
		}
	}
	for _, change := range []func(*AutopilotDemandSample){
		func(s *AutopilotDemandSample) { s.Model = "" },
		func(s *AutopilotDemandSample) { s.PromptTokens = 0 },
		func(s *AutopilotDemandSample) { s.PromptTokens = autopilotDemandMaxTokens + 1 },
		func(s *AutopilotDemandSample) { s.RequestedMaxTokens = -1 },
		func(s *AutopilotDemandSample) { s.RequestedMaxTokens = autopilotDemandMaxTokens + 1 },
	} {
		var d autopilotDemandTracker
		s := autopilotDemandTestSample(now)
		change(&s)
		d.record(s, now, time.Minute)
		if len(d.models) != 0 {
			t.Fatalf("invalid envelope retained: %+v", s)
		}
	}
}

func TestAutopilotDemandConcurrentRecordAndSnapshot(t *testing.T) {
	now := autopilotDemandTestClock()
	var d autopilotDemandTracker
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				d.record(autopilotDemandTestSample(now.Add(-time.Duration(g)*time.Second)), now, time.Minute)
				d.snapshot(now, time.Minute)
			}
		}(g)
	}
	wg.Wait()
	v := d.snapshot(now, time.Minute)["model"]
	if v.Requests != 800 || math.IsNaN(v.Rate) || math.IsInf(v.Rate, 0) {
		t.Fatalf("concurrent demand lost or became nonfinite: %+v", v)
	}
}
