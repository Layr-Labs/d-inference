package registry

import (
	"fmt"
	"math/rand"
	"slices"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// These are property tests over seeded random inputs. Every failure message
// names the seed and the case so that the input can be replayed.

var firstContentInvariantSeeds = []int64{1, 1238, 1243, 1254, 20260929}

var firstContentStatuses = []string{FirstContentFeasible, FirstContentUnknown, FirstContentPredictedLate}

// randomFirstContentSnapshot returns a snapshot across the ranges that
// estimateFirstContent reads, including missing, stale and busy evidence.
func randomFirstContentSnapshot(rng *rand.Rand, now time.Time) *routingCandidate {
	c := measuredFirstContentCandidate(now)
	s := &c.snapshot
	pick := func(values ...int32) int32 { return values[rng.Intn(len(values))] }
	s.capacityAgeMs = pick(-1, 0, 1000, 5000, 5001, 60_000)
	s.performanceAgeMs = pick(-1, 0, 30_000, 120_000, 120_001, 3_600_000)
	s.isolatedPrefillInitialized = rng.Intn(5) > 0
	s.isolatedPrefillTPS = 50 + 4950*rng.Float64()
	s.observedPrefillTPS = 50 + 4950*rng.Float64()
	s.prefillTPS = 50 + 4950*rng.Float64()
	if rng.Intn(4) == 0 {
		s.observedDecodeTPS = 0
	} else {
		s.observedDecodeTPS = 1 + 199*rng.Float64()
	}
	s.decodeTPS = 1 + 199*rng.Float64()
	s.fleetMedianTPS = float64(rng.Intn(2)) * (1 + 199*rng.Float64())
	s.modelLoaded = rng.Intn(5) > 0
	s.wholeMacWorkKnown = rng.Intn(5) > 0
	s.wholeMacBusy = rng.Intn(3) == 0
	s.partialPrefillRows = rng.Intn(3) / 2
	s.queuedPrefillTokens = int64(rng.Intn(3) * rng.Intn(4000))
	s.backendRunning = rng.Intn(3)
	s.otherModelOccupancy = rng.Intn(3)
	s.transportMs = 200 * rng.Float64()
	s.conservativeTransportMs = s.transportMs + 300*rng.Float64()
	return c
}

func randomFirstContentRequest(rng *rand.Rand, now time.Time) *PendingRequest {
	pr := &PendingRequest{
		EstimatedPromptTokens: rng.Intn(9000) - 500,
		RequestedMaxTokens:    rng.Intn(4096),
		RequiresVision:        rng.Intn(10) == 0,
	}
	switch rng.Intn(3) {
	case 0:
		pr.FirstContentDeadline = now.Add(time.Duration(rng.Intn(20_000)) * time.Millisecond)
	case 1:
		pr.MaxTTFTMs = float64(1 + rng.Intn(20_000))
	}
	return pr
}

// TestFirstContentForecastInvariants checks the stated forecast invariants
// on random snapshots. Expected forecasts always rank, the conservative
// forecast is never earlier than the expected one, and only fresh, complete,
// idle evidence that fits the budget is feasible
// (docs/architecture/first-content-routing.md, invariant 4).
func TestFirstContentForecastInvariants(t *testing.T) {
	r := New(testLogger())
	capacityLimit := int32(firstContentFreshness / time.Millisecond)
	performanceLimit := int32(firstContentPerformanceFreshness / time.Millisecond)
	for _, seed := range firstContentInvariantSeeds {
		rng := rand.New(rand.NewSource(seed))
		for i := range 2000 {
			now := time.Now()
			c := randomFirstContentSnapshot(rng, now)
			pr := randomFirstContentRequest(rng, now)
			r.estimateFirstContent(c, pr, now)
			e, s := c.firstContent, &c.snapshot
			fail := func(format string, args ...any) {
				t.Helper()
				t.Fatalf("seed %d case %d: %s\nestimate %+v", seed, i, fmt.Sprintf(format, args...), e)
			}
			if !finitePositive(e.ExpectedMs) || !finitePositive(e.ConservativeMs) {
				fail("forecasts must be finite and positive, also when unknown")
			}
			if e.ConservativeMs < e.ExpectedMs {
				fail("conservative forecast is earlier than the expected forecast")
			}
			switch e.Status {
			case FirstContentFeasible:
				if e.Reason != "" || e.ConservativeMs > e.BudgetMs {
					fail("feasible without qualified evidence inside the budget")
				}
				if s.capacityAgeMs < 0 || s.capacityAgeMs > capacityLimit || s.performanceAgeMs < 0 || s.performanceAgeMs > performanceLimit ||
					!s.modelLoaded || s.wholeMacBusy || !s.wholeMacWorkKnown || pr.RequiresVision {
					fail("feasible with stale, busy, cold or vision work: %+v", s.firstContentSnapshot)
				}
			case FirstContentPredictedLate:
				if e.Reason != "" || e.ConservativeMs <= e.BudgetMs {
					fail("predicted late without a qualified forecast over the budget")
				}
			case FirstContentUnknown:
				if e.Reason == "" {
					fail("unknown without a reason")
				}
			default:
				fail("status %q", e.Status)
			}
		}
	}
}

// TestFirstContentForecastRateMonotonicity checks that a faster measured
// rate never makes the forecast later. Ranking must reward speed, whatever
// the rest of the snapshot says.
func TestFirstContentForecastRateMonotonicity(t *testing.T) {
	r := New(testLogger())
	for _, seed := range firstContentInvariantSeeds {
		rng := rand.New(rand.NewSource(seed))
		for i := range 2000 {
			now := time.Now()
			base := randomFirstContentSnapshot(rng, now)
			pr := randomFirstContentRequest(rng, now)
			factor := 1 + 3*rng.Float64()
			for _, faster := range []struct {
				name   string
				change func(s *routingSnapshot)
			}{
				{"decode", func(s *routingSnapshot) { s.observedDecodeTPS *= factor }},
				{"prefill", func(s *routingSnapshot) { s.observedPrefillTPS *= factor; s.isolatedPrefillTPS *= factor }},
			} {
				slow := *base
				fast := *base
				faster.change(&fast.snapshot)
				r.estimateFirstContent(&slow, pr, now)
				r.estimateFirstContent(&fast, pr, now)
				if fast.firstContent.ExpectedMs > slow.firstContent.ExpectedMs || fast.firstContent.ConservativeMs > slow.firstContent.ConservativeMs {
					t.Fatalf("seed %d case %d: faster %s (x%.2f) made the forecast later: %+v then %+v",
						seed, i, faster.name, factor, slow.firstContent, fast.firstContent)
				}
			}
		}
	}
}

// TestFirstContentPreferenceNeverEmptiesPool checks routing invariant 7 for
// the first-content preference: narrowing keeps a nonempty subset in order,
// never drops a feasible candidate, and never keeps a predicted-late one in
// preference to a feasible one (docs/architecture/routing.md, Invariants).
func TestFirstContentPreferenceNeverEmptiesPool(t *testing.T) {
	for _, seed := range firstContentInvariantSeeds {
		rng := rand.New(rand.NewSource(seed))
		for i := range 2000 {
			pool := make([]*routingCandidate, rng.Intn(12))
			counts := map[string]int{}
			for j := range pool {
				status := firstContentStatuses[rng.Intn(len(firstContentStatuses))]
				pool[j] = &routingCandidate{firstContent: FirstContentEstimate{Status: status}}
				counts[status]++
			}
			original := slices.Clone(pool)
			got := preferFirstContentCandidates(slices.Clone(pool))
			fail := func(msg string) {
				t.Helper()
				t.Fatalf("seed %d case %d: %s (input statuses %v)", seed, i, msg, statusesOf(original))
			}
			if len(original) > 0 && len(got) == 0 {
				fail("preference emptied a nonempty pool")
			}
			if !isOrderedSubset(got, original) {
				fail("preference invented, repeated or reordered candidates")
			}
			kept := map[string]int{}
			for _, c := range got {
				kept[c.firstContent.Status]++
			}
			switch {
			case counts[FirstContentFeasible] > 0:
				if kept[FirstContentFeasible] != counts[FirstContentFeasible] || kept[FirstContentPredictedLate] != 0 {
					fail("feasible candidates must all stay, ahead of predicted-late ones")
				}
			case counts[FirstContentUnknown] > 0:
				if kept[FirstContentUnknown] != counts[FirstContentUnknown] || kept[FirstContentPredictedLate] != 0 {
					fail("without feasible candidates, unknown ones must all stay, ahead of predicted-late ones")
				}
			default:
				if len(got) != len(original) {
					fail("a pool with no preferred candidate must stay whole")
				}
			}
		}
	}
}

func statusesOf(pool []*routingCandidate) []string {
	out := make([]string, len(pool))
	for i, c := range pool {
		out[i] = c.firstContent.Status
	}
	return out
}

func isOrderedSubset(sub, full []*routingCandidate) bool {
	j := 0
	for _, c := range sub {
		for j < len(full) && full[j] != c {
			j++
		}
		if j == len(full) {
			return false
		}
		j++
	}
	return true
}

// TestHeartbeatMeasurementDatingInvariants drives random heartbeat
// sequences through Registry.Heartbeat on a virtual clock. It checks the
// dating rules for both the legacy EWMA path and the explicit metadata path:
// a measurement time never moves later unless a new sample arrives, it is
// never later than the report that carries it, and a replayed capacity
// sequence changes nothing.
func TestHeartbeatMeasurementDatingInvariants(t *testing.T) {
	for _, explicit := range []bool{false, true} {
		for _, seed := range firstContentInvariantSeeds {
			t.Run(fmt.Sprintf("explicit=%t/seed=%d", explicit, seed), func(t *testing.T) {
				synctest.Test(t, func(t *testing.T) {
					checkHeartbeatMeasurementDating(t, seed, explicit)
				})
			})
		}
	}
}

func checkHeartbeatMeasurementDating(t *testing.T, seed int64, explicit bool) {
	const model = "dating-model"
	rng := rand.New(rand.NewSource(seed))
	r := New(testLogger())
	p := makeSchedulerProvider(t, r, "p", model, 50)
	prefill, decode := 1000.0, 50.0
	var prefillCount, decodeCount int64
	var prefillAt, decodeAt time.Time
	seq := uint64(0)
	for step := range 300 {
		time.Sleep(time.Duration(500+rng.Intn(30_000)) * time.Millisecond)
		now := time.Now()
		replay := seq > 0 && rng.Intn(8) == 0
		newPrefill, newDecode := rng.Intn(3) == 0, rng.Intn(3) == 0
		if !replay {
			seq++
			if newPrefill {
				prefill *= 0.9 + 0.2*rng.Float64()
				prefillCount++
				prefillAt = now
			}
			if newDecode {
				decode *= 0.9 + 0.2*rng.Float64()
				decodeCount++
				decodeAt = now
			}
		}
		bc := p.BackendCapacitySnapshot()
		bc.CapacitySeq = seq
		slot := &bc.Slots[0]
		slot.State = "idle"
		slot.ObservedDecodeTPS, slot.ObservedPrefillTPS = decode, prefill
		rate, initialized := prefill, true
		slot.Telemetry = &protocol.SlotTelemetry{QueuedPrefillTokens: new(int64), PartialPrefillRows: new(int64),
			IsolatedPrefillTPS: &rate, EWMAInitialized: &initialized}
		if explicit && prefillCount > 0 && decodeCount > 0 {
			slot.PerformanceMeasurements = &protocol.PerformanceMeasurements{Epoch: "engine",
				IsolatedPrefill: &protocol.PerformanceRateObservation{TokensPerSecond: prefill, SampleCount: prefillCount,
					SampleAgeMS: now.Sub(prefillAt).Milliseconds()},
				Decode: &protocol.PerformanceRateObservation{TokensPerSecond: decode, SampleCount: decodeCount,
					SampleAgeMS: now.Sub(decodeAt).Milliseconds()}}
		}
		p.mu.Lock()
		before, previousAccepted := p.firstContentMeasurements[model], p.CapacityAcceptedAt
		p.mu.Unlock()
		accepted := r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: bc})
		p.mu.Lock()
		after := p.firstContentMeasurements[model]
		p.mu.Unlock()
		fail := func(msg string) {
			t.Helper()
			t.Fatalf("seed %d step %d (explicit=%t replay=%t newPrefill=%t newDecode=%t): %s\nbefore %+v\nafter  %+v",
				seed, step, explicit, replay, newPrefill, newDecode, msg, before, after)
		}
		if replay {
			if accepted || after != before {
				fail("a replayed capacity sequence changed measurement evidence")
			}
			continue
		}
		for _, phase := range []struct {
			name              string
			old, new          time.Time
			renewed           bool
			changedByNewValue bool
		}{
			{"prefill", before.observedAfter, after.observedAfter, newPrefill, newPrefill},
			{"decode", before.decodeObservedAfter, after.decodeObservedAfter, newDecode, newDecode},
		} {
			if phase.new.After(now) {
				fail(phase.name + " measurement is dated after the report that carries it")
			}
			if !phase.renewed && !phase.old.IsZero() && phase.new.After(phase.old) {
				fail(phase.name + " measurement became younger without a new sample")
			}
			if !explicit && phase.changedByNewValue && !phase.new.IsZero() && !phase.old.IsZero() && !phase.new.Equal(previousAccepted) {
				fail(phase.name + " changed legacy value is not dated at the previous accepted report")
			}
		}
		// The age that routing reads never runs ahead of the true sample age.
		c := &routingCandidate{}
		p.mu.Lock()
		r.fillRoutingSnapshotPLocked(&c.snapshot, p, model, now)
		p.mu.Unlock()
		if age := c.snapshot.performanceAgeMs; age >= 0 && prefillCount > 0 && decodeCount > 0 {
			trueAge := max(now.Sub(prefillAt), now.Sub(decodeAt))
			if time.Duration(age)*time.Millisecond < trueAge-time.Millisecond {
				fail(fmt.Sprintf("routing age %dms is younger than the newest sample age %s", age, trueAge))
			}
		}
	}
}
