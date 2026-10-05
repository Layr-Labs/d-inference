package registry_test

import (
	"fmt"
	"math/rand"
	"slices"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/capacityvalue"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/forecast"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

// These are property tests over seeded random inputs. Every failure message
// names the seed and the case so that the input can be replayed.

var firstContentInvariantSeeds = []int64{1, 1238, 1243, 1254, 20260929}

var firstContentStatuses = []string{forecast.Feasible, forecast.Unknown, forecast.PredictedLate}

// firstContentForecastInputs keeps the reported rates apart from the
// evidence, so that a test can change one rate and let the production rate
// chain resolve the forecast rates again.
type firstContentForecastInputs struct {
	evidence forecast.Evidence
	rates    performance.Rates
}

func (in firstContentForecastInputs) resolvedEvidence() forecast.Evidence {
	e := in.evidence
	e.ObservedDecodeTPS = in.rates.ObservedDecode
	e.PrefillTPS = in.rates.Prefill()
	e.DecodeTPS = in.rates.EffectiveDecode(e.LoadFactor)
	return e
}

// randomFirstContentForecastInputs spans the ranges that the forecast reads,
// including missing, stale and busy evidence.
func randomFirstContentForecastInputs(rng *rand.Rand, now time.Time) firstContentForecastInputs {
	in := firstContentForecastInputs{evidence: measuredFirstContentEvidence(now)}
	e, history, work, rates := &in.evidence, &in.evidence.Calibration, &in.evidence.Workload, &in.rates
	e.LoadFactor = warmplan.DecodeLoadFactor
	pick := func(values ...int32) int32 { return values[rng.Intn(len(values))] }
	history.CapacityAgeMS = pick(-1, 0, 1000, 5000, 5001, 60_000)
	history.PerformanceAgeMS = pick(-1, 0, 30_000, 120_000, 120_001, 3_600_000)
	history.IsolatedInitialized = rng.Intn(5) > 0
	history.IsolatedPrefillTPS = 50 + 4950*rng.Float64()
	rates.ObservedPrefill = 50 + 4950*rng.Float64()
	rates.StaticPrefill = 50 + 4950*rng.Float64()
	if rng.Intn(4) == 0 {
		rates.ObservedDecode = 0
	} else {
		rates.ObservedDecode = 1 + 199*rng.Float64()
	}
	rates.StaticDecode = 1 + 199*rng.Float64()
	rates.FleetMedian = float64(rng.Intn(2)) * (1 + 199*rng.Float64())
	history.ModelLoaded = rng.Intn(5) > 0
	work.WholeMacKnown = rng.Intn(5) > 0
	work.WholeMacBusy = rng.Intn(3) == 0
	work.PartialPrefillRows = rng.Intn(3) / 2
	work.PrefillAhead = float64(rng.Intn(3) * rng.Intn(4000))
	rates.ObservedBatch = rng.Intn(3)
	rates.Occupancy = rates.ObservedBatch
	work.OtherModelOccupancy = rng.Intn(3)
	e.Transport.ExpectedMS = 200 * rng.Float64()
	e.Transport.ConservativeMS = e.Transport.ExpectedMS + 300*rng.Float64()
	return in
}

func randomFirstContentRequest(rng *rand.Rand, now time.Time) forecast.Request {
	estimated := rng.Intn(9000) - 500
	r := forecast.Request{Incoming: performance.IncomingWork{RequestedMaxTokens: rng.Intn(4096), RequiresVision: rng.Intn(10) == 0}}
	r.PromptTokens, r.UpperBoundTokens = forecast.PromptCounts(estimated, 0, nil, "", "", 0, false)
	switch rng.Intn(3) {
	case 0:
		r.Deadline = now.Add(time.Duration(rng.Intn(20_000)) * time.Millisecond)
	case 1:
		r.MaxTTFTMS = float64(1 + rng.Intn(20_000))
	}
	return r
}

// TestFirstContentForecastInvariants checks the stated forecast invariants
// on random evidence. Expected forecasts always rank, the conservative
// forecast is never earlier than the expected one, and only fresh, complete,
// idle evidence that fits the budget is feasible
// (docs/architecture/first-content-routing.md, invariant 4).
func TestFirstContentForecastInvariants(t *testing.T) {
	capacityLimit := int32(forecast.CapacityFreshness / time.Millisecond)
	performanceLimit := int32(forecast.PerformanceFreshness / time.Millisecond)
	for _, seed := range firstContentInvariantSeeds {
		rng := rand.New(rand.NewSource(seed))
		for i := range 2000 {
			now := time.Now()
			evidence := randomFirstContentForecastInputs(rng, now).resolvedEvidence()
			r := randomFirstContentRequest(rng, now)
			e, history, work := forecast.Evaluate(&evidence, r, now).Estimate, &evidence.Calibration, &evidence.Workload
			fail := func(format string, args ...any) {
				t.Helper()
				t.Fatalf("seed %d case %d: %s\nestimate %+v", seed, i, fmt.Sprintf(format, args...), e)
			}
			if !capacityvalue.FinitePositive(e.ExpectedMs) || !capacityvalue.FinitePositive(e.ConservativeMs) {
				fail("forecasts must be finite and positive, also when unknown")
			}
			if e.ConservativeMs < e.ExpectedMs {
				fail("conservative forecast is earlier than the expected forecast")
			}
			switch e.Status {
			case forecast.Feasible:
				if e.Reason != "" || e.ConservativeMs > e.BudgetMs {
					fail("feasible without qualified evidence inside the budget")
				}
				if history.CapacityAgeMS < 0 || history.CapacityAgeMS > capacityLimit ||
					history.PerformanceAgeMS < 0 || history.PerformanceAgeMS > performanceLimit ||
					!history.ModelLoaded || work.WholeMacBusy || !work.WholeMacKnown || r.Incoming.RequiresVision {
					fail("feasible with stale, busy, cold or vision work: %+v", evidence)
				}
			case forecast.PredictedLate:
				if e.Reason != "" || e.ConservativeMs <= e.BudgetMs {
					fail("predicted late without a qualified forecast over the budget")
				}
			case forecast.Unknown:
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
// the rest of the evidence says.
func TestFirstContentForecastRateMonotonicity(t *testing.T) {
	for _, seed := range firstContentInvariantSeeds {
		rng := rand.New(rand.NewSource(seed))
		for i := range 2000 {
			now := time.Now()
			base := randomFirstContentForecastInputs(rng, now)
			r := randomFirstContentRequest(rng, now)
			factor := 1 + 3*rng.Float64()
			for _, faster := range []struct {
				name   string
				change func(in *firstContentForecastInputs)
			}{
				{"decode", func(in *firstContentForecastInputs) { in.rates.ObservedDecode *= factor }},
				{"prefill", func(in *firstContentForecastInputs) {
					in.rates.ObservedPrefill *= factor
					in.evidence.Calibration.IsolatedPrefillTPS *= factor
				}},
			} {
				fast := base
				faster.change(&fast)
				slowEvidence, fastEvidence := base.resolvedEvidence(), fast.resolvedEvidence()
				slow, quick := forecast.Evaluate(&slowEvidence, r, now).Estimate, forecast.Evaluate(&fastEvidence, r, now).Estimate
				if quick.ExpectedMs > slow.ExpectedMs || quick.ConservativeMs > slow.ConservativeMs {
					t.Fatalf("seed %d case %d: faster %s (x%.2f) made the forecast later: %+v then %+v",
						seed, i, faster.name, factor, slow, quick)
				}
			}
		}
	}
}

// TestFirstContentPreferenceNeverEmptiesPool checks routing invariant 7 for
// the preference that first-content routing narrows its pool with: narrowing
// keeps a nonempty subset in order, keeps every preferred candidate, and
// keeps no other candidate while a preferred one exists
// (docs/architecture/routing.md, Invariants). Each pool is narrowed once for
// each status.
func TestFirstContentPreferenceNeverEmptiesPool(t *testing.T) {
	for _, seed := range firstContentInvariantSeeds {
		rng := rand.New(rand.NewSource(seed))
		for i := range 2000 {
			pool := make([]*forecast.Estimate, rng.Intn(12))
			counts := map[string]int{}
			for j := range pool {
				status := firstContentStatuses[rng.Intn(len(firstContentStatuses))]
				pool[j] = &forecast.Estimate{Status: status}
				counts[status]++
			}
			for _, preferred := range firstContentStatuses {
				got := selection.Prefer(slices.Clone(pool), func(e *forecast.Estimate) bool { return e.Status == preferred })
				fail := func(msg string) {
					t.Helper()
					t.Fatalf("seed %d case %d prefer %s: %s (input statuses %v)", seed, i, preferred, msg, firstContentStatusesOf(pool))
				}
				if len(pool) > 0 && len(got) == 0 {
					fail("preference emptied a nonempty pool")
				}
				if !isOrderedEstimateSubset(got, pool) {
					fail("preference invented, repeated or reordered candidates")
				}
				switch {
				case counts[preferred] > 0:
					if len(got) != counts[preferred] || slices.ContainsFunc(got, func(e *forecast.Estimate) bool { return e.Status != preferred }) {
						fail("preferred candidates must all stay, and only they")
					}
				case len(got) != len(pool):
					fail("a pool with no preferred candidate must stay whole")
				}
			}
		}
	}
}

func firstContentStatusesOf(pool []*forecast.Estimate) []string {
	out := make([]string, len(pool))
	for i, e := range pool {
		out[i] = e.Status
	}
	return out
}

func isOrderedEstimateSubset(sub, full []*forecast.Estimate) bool {
	j := 0
	for _, e := range sub {
		for j < len(full) && full[j] != e {
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
	f := newObservedForecastFixture(t, "p", model, 50)
	r, p, history := f.r, f.p, f.history
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
		p.Mu().Lock()
		before, _ := history.Lookup(model)
		previousAccepted := p.CapacityAcceptedAt
		p.Mu().Unlock()
		accepted := r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: bc})
		p.Mu().Lock()
		after, _ := history.Lookup(model)
		p.Mu().Unlock()
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
			name      string
			old, new  time.Time
			newSample bool
		}{
			{"prefill", before.ObservedAfter, after.ObservedAfter, newPrefill},
			{"decode", before.DecodeObservedAfter, after.DecodeObservedAfter, newDecode},
		} {
			if phase.new.After(now) {
				fail(phase.name + " measurement is dated after the report that carries it")
			}
			if !phase.newSample && !phase.old.IsZero() && phase.new.After(phase.old) {
				fail(phase.name + " measurement became younger without a new sample")
			}
			if !explicit && phase.newSample && !phase.new.IsZero() && !phase.old.IsZero() && !phase.new.Equal(previousAccepted) {
				fail(phase.name + " changed legacy value is not dated at the previous accepted report")
			}
		}
		// The age that routing reads never runs ahead of the true sample age.
		// The provider keeps passing challenges, so routing can still select it.
		p.Mu().Lock()
		p.LastChallengeVerified = now
		p.Mu().Unlock()
		pr := &production.PendingRequest{RequestID: fmt.Sprintf("dating-%d", step), Model: model,
			EstimatedPromptTokens: 1000, RequestedMaxTokens: 128, FirstContentDeadline: now.Add(10 * time.Second)}
		selected, decision := r.ReserveProviderEx(model, pr)
		if selected != p {
			fail(fmt.Sprintf("routing did not select the only provider: %+v", decision.FirstContent))
		}
		p.RemovePending(pr.RequestID)
		if age := decision.FirstContent.PerformanceAgeMs; age >= 0 && prefillCount > 0 && decodeCount > 0 {
			trueAge := max(now.Sub(prefillAt), now.Sub(decodeAt))
			if time.Duration(age)*time.Millisecond < trueAge-time.Millisecond {
				fail(fmt.Sprintf("routing age %dms is younger than the newest sample age %s", age, trueAge))
			}
		}
	}
}
