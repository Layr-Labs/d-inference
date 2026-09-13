package registry

import (
	"fmt"
	"os/exec"
	"reflect"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Tests for the reservation commit without the global write lock (shared
// mode) against the fleet-wide serialized commit (global mode, the kill
// switch): the two must admit exactly the same amount, the routing gates must
// decide identically under concurrent recorders, and the request path must
// actually parallelize — the whole point of the change.

// setReserveCommitModeForTest switches the reservation commit lock mode on a
// registry that already exists (the env is read once at construction).
func setReserveCommitModeForTest(r *Registry, mode reserveCommitMode) {
	r.reserveCommitMode = mode
}

func TestParseReserveCommitMode(t *testing.T) {
	cases := map[string]struct {
		mode  reserveCommitMode
		known bool
	}{
		"":         {reserveCommitShared, true},
		"shared":   {reserveCommitShared, true},
		"anything": {reserveCommitShared, false}, // a typo falls back to shared AND is reported
		"global":   {reserveCommitGlobal, true},
		" GLOBAL ": {reserveCommitGlobal, true},
	}
	for raw, want := range cases {
		mode, known := parseReserveCommitMode(raw)
		if mode != want.mode || known != want.known {
			t.Errorf("parseReserveCommitMode(%q) = (%s, %v), want (%s, %v)", raw, mode, known, want.mode, want.known)
		}
	}
	t.Setenv(envReserveCommitMode, "")
	if New(testLogger()).reserveCommitMode != reserveCommitShared {
		t.Fatal("a registry built without EIGENINFERENCE_RESERVE_COMMIT_MODE must default to shared")
	}
}

func forEachCommitMode(t *testing.T, body func(t *testing.T, mode reserveCommitMode)) {
	for _, mode := range []reserveCommitMode{reserveCommitShared, reserveCommitGlobal} {
		t.Run(mode.String(), func(t *testing.T) { body(t, mode) })
	}
}

func pendingCountOf(p *Provider) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pendingCount()
}

// TestReserveCommitAdmitsExactlyTheSerialCapacityUnderConcurrency: N
// goroutines committing against ONE provider admit exactly as many requests
// as a serial loop does (the provider's capacity), the pending set holds
// exactly those requests, and releasing them returns the count to zero — in
// both commit modes. This is the no-double-booking invariant: the admit
// re-check and the pending debit share one p.mu section.
func TestReserveCommitAdmitsExactlyTheSerialCapacityUnderConcurrency(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
		reg := New(testLogger())
		setReserveCommitModeForTest(reg, mode)
		const model = "commit-cap-model"
		p := makeSchedulerProvider(t, reg, "capped", model, 100)
		p.mu.Lock()
		p.BackendCapacity.Slots[0].MaxConcurrency = 4
		p.mu.Unlock()
		newReq := func(i int) *PendingRequest {
			return &PendingRequest{
				RequestID:             fmt.Sprintf("%s-%d", mode, i),
				Model:                 model,
				EstimatedPromptTokens: 200,
				RequestedMaxTokens:    128,
				FirstContentBudgetMS:  10_000,
				FirstContentDeadline:  time.Now().Add(10 * time.Second),
			}
		}

		// The provider's capacity, measured serially.
		var serial []*PendingRequest
		for i := 0; i < 64; i++ {
			pr := newReq(i)
			got, _ := reg.ReserveProviderEx(model, pr)
			if got == nil {
				break
			}
			serial = append(serial, pr)
		}
		capacity := len(serial)
		if capacity < 2 || capacity > 4 {
			t.Fatalf("serial capacity = %d, want 2..4 (MaxConcurrency 4) for the test to mean anything", capacity)
		}
		for _, pr := range serial {
			p.RemovePending(pr.RequestID)
		}
		if n := pendingCountOf(p); n != 0 {
			t.Fatalf("pending after release = %d, want 0", n)
		}

		const workers = 32
		for round := 0; round < 5; round++ {
			reqs := make([]*PendingRequest, workers)
			var admitted atomic.Int32
			var wg sync.WaitGroup
			start := make(chan struct{})
			for i := range reqs {
				reqs[i] = newReq(1000 + round*workers + i)
				wg.Add(1)
				go func(pr *PendingRequest) {
					defer wg.Done()
					<-start
					got, _ := reg.ReserveProviderEx(model, pr)
					if got == nil {
						return
					}
					if got != p {
						t.Errorf("reserved a stranger: %v", got)
					}
					admitted.Add(1)
				}(reqs[i])
			}
			close(start)
			wg.Wait()
			if int(admitted.Load()) != capacity {
				t.Fatalf("round %d: %d admitted concurrently, serial capacity is %d", round, admitted.Load(), capacity)
			}
			if n := pendingCountOf(p); n != capacity {
				t.Fatalf("round %d: pending set holds %d, want %d", round, n, capacity)
			}
			released := 0
			for _, pr := range reqs {
				if pr.ProviderID != p.ID {
					continue
				}
				if p.RemovePending(pr.RequestID) == nil {
					t.Fatalf("round %d: admitted request %s missing from the pending set", round, pr.RequestID)
				}
				released++
			}
			if released != capacity {
				t.Fatalf("round %d: %d requests carry the provider id, %d were admitted", round, released, capacity)
			}
			if n := pendingCountOf(p); n != 0 {
				t.Fatalf("round %d: pending after release = %d, want 0", round, n)
			}
		}
	})
}

// TestReserveNextFromPlanAdmitsExactlyTheSerialCapacityUnderConcurrency is the
// plan-path twin of the test above: N goroutines, each consuming its own plan
// whose next entry is the same capped alternate, admit exactly the serial
// capacity — the snapshot, admit re-check, probe claim and debit share one
// p.mu hold in tryReserve too, in both commit modes.
func TestReserveNextFromPlanAdmitsExactlyTheSerialCapacityUnderConcurrency(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
		reg := New(testLogger())
		setReserveCommitModeForTest(reg, mode)
		const model = "plan-cap-model"
		// The winner is only there to be excluded from every plan; the
		// alternate is the capped provider every plan consumes next.
		winner := makeSchedulerProvider(t, reg, "plan-winner", model, 100)
		alt := makeSchedulerProvider(t, reg, "plan-alt", model, 100)
		alt.mu.Lock()
		alt.BackendCapacity.Slots[0].MaxConcurrency = 4
		alt.mu.Unlock()
		newReq := func(i int) *PendingRequest {
			return &PendingRequest{
				RequestID:             fmt.Sprintf("plan-%s-%d", mode, i),
				Model:                 model,
				EstimatedPromptTokens: 200,
				RequestedMaxTokens:    128,
				FirstContentBudgetMS:  10_000,
				FirstContentDeadline:  time.Now().Add(10 * time.Second),
			}
		}
		planFor := func(pr *PendingRequest) *DispatchPlan {
			reg.mu.RLock()
			scan := reg.scanCandidatesLocked(model, pr, false)
			reg.mu.RUnlock()
			var w *routingCandidate
			for _, c := range scan.pool {
				if c.provider == winner {
					w = c
				}
			}
			if w == nil {
				t.Fatal("winner missing from the scan pool")
			}
			// The alternate is the plan's only entry while it has headroom and
			// drops out of the scan pool (hence the plan) once it is full.
			plan := newDispatchPlan(model, scan, w)
			if plan.Len() > 1 || (plan.Len() == 1 && plan.entries[0].provider != alt) {
				t.Fatalf("plan must hold at most the alternate, got %d entries", plan.Len())
			}
			return plan
		}

		var serial []*PendingRequest
		for i := 0; i < 64; i++ {
			pr := newReq(i)
			plan := planFor(pr)
			if plan.Len() == 0 {
				break
			}
			got, _, _ := reg.ReserveNextFromPlan(pr, plan)
			if got == nil {
				break
			}
			serial = append(serial, pr)
		}
		capacity := len(serial)
		if capacity < 2 || capacity > 4 {
			t.Fatalf("serial plan capacity = %d, want 2..4", capacity)
		}
		for _, pr := range serial {
			alt.RemovePending(pr.RequestID)
		}

		const workers = 32
		for round := 0; round < 5; round++ {
			reqs := make([]*PendingRequest, workers)
			plans := make([]*DispatchPlan, workers)
			for i := range reqs {
				reqs[i] = newReq(1000 + round*workers + i)
				plans[i] = planFor(reqs[i])
				if plans[i].Len() != 1 {
					t.Fatalf("round %d: plan %d must hold the idle alternate", round, i)
				}
			}
			var admitted atomic.Int32
			var wg sync.WaitGroup
			start := make(chan struct{})
			for i := range reqs {
				wg.Add(1)
				go func(pr *PendingRequest, plan *DispatchPlan) {
					defer wg.Done()
					<-start
					got, _, _ := reg.ReserveNextFromPlan(pr, plan)
					if got == nil {
						return
					}
					if got != alt {
						t.Errorf("plan reserved a stranger: %v", got)
					}
					admitted.Add(1)
				}(reqs[i], plans[i])
			}
			close(start)
			wg.Wait()
			if int(admitted.Load()) != capacity {
				t.Fatalf("round %d: %d admitted concurrently through plans, serial capacity is %d", round, admitted.Load(), capacity)
			}
			if n := pendingCountOf(alt); n != capacity {
				t.Fatalf("round %d: pending set holds %d, want %d", round, n, capacity)
			}
			for _, pr := range reqs {
				if pr.ProviderID == alt.ID {
					alt.RemovePending(pr.RequestID)
				}
			}
			if n := pendingCountOf(alt); n != 0 {
				t.Fatalf("round %d: pending after release = %d, want 0", round, n)
			}
		}
	})
}

// TestCommitProbeClaimAdmitsExactlyOneAcrossSessions drives the half-open
// probe claim end to end through ReserveProviderEx: two sessions of ONE
// identity serve the model, the identity's capacity cooldown has expired, and
// N concurrent reservations must admit exactly one request — the probe — with
// the gate closed to everyone else afterwards. Commits on different providers
// do not share p.mu; only the check-and-claim under gate.mu makes this exact.
func TestCommitProbeClaimAdmitsExactlyOneAcrossSessions(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
		reg := New(testLogger())
		setReserveCommitModeForTest(reg, mode)
		const model = "probe-race-model"
		p1 := attestSchedulerProvider(t, reg, "probe-sess-1", model, "SER-PROBE-RACE", 100)
		p2 := attestSchedulerProvider(t, reg, "probe-sess-2", model, "SER-PROBE-RACE", 100)
		for i := 0; i < reg.capacityCooldownCfg.Threshold; i++ {
			reg.RecordCapacityReject(p1.ID, model)
		}
		if !reg.CapacityCooldownActive(p2.ID, model) {
			t.Fatal("precondition: the identity's cooldown must gate both sessions")
		}
		expireCapacityCooldown(reg, p1.ID, model)

		const workers = 16
		reqs := make([]*PendingRequest, workers)
		var admitted atomic.Int32
		var wg sync.WaitGroup
		start := make(chan struct{})
		for i := range reqs {
			reqs[i] = &PendingRequest{
				RequestID:             fmt.Sprintf("probe-%s-%d", mode, i),
				Model:                 model,
				EstimatedPromptTokens: 200,
				RequestedMaxTokens:    128,
				FirstContentBudgetMS:  10_000,
				FirstContentDeadline:  time.Now().Add(10 * time.Second),
			}
			wg.Add(1)
			go func(pr *PendingRequest) {
				defer wg.Done()
				<-start
				if got, _ := reg.ReserveProviderEx(model, pr); got != nil {
					admitted.Add(1)
				}
			}(reqs[i])
		}
		close(start)
		wg.Wait()
		if admitted.Load() != 1 {
			t.Fatalf("%d reservations admitted through an expired cooldown, want exactly the one probe", admitted.Load())
		}
		if n := pendingCountOf(p1) + pendingCountOf(p2); n != 1 {
			t.Fatalf("pending across the identity's sessions = %d, want 1", n)
		}
		if !reg.CapacityCooldownActive(p1.ID, model) || !reg.CapacityCooldownActive(p2.ID, model) {
			t.Fatal("the claimed probe must close the gate for both sessions")
		}
	})
}

// commitModeFleets builds one fleet-scale fixture per commit mode with the same
// fault script applied: a breaker-open advertiser, a health-ejected advertiser,
// a capacity-cooled advertiser, a dispatch-load-cooled advertiser, a
// tools-shape inference-error-cooled advertiser and a budget-clamped
// advertiser (one that reports a token budget). Returns the fleets and the
// faulted provider ids by fault kind.
func commitModeFleets(t *testing.T, model string) (map[reserveCommitMode]*benchFleet, map[string]string) {
	t.Helper()
	fleets := map[reserveCommitMode]*benchFleet{}
	for _, mode := range []reserveCommitMode{reserveCommitShared, reserveCommitGlobal} {
		f := buildBenchFleet(t, benchFleetProviders, benchFleetModels)
		setReserveCommitModeForTest(f.reg, mode)
		fleets[mode] = f
	}
	ref := fleets[reserveCommitShared]
	var budgeted, others []int
	for i := range ref.ids {
		if !benchProviderAdvertises(ref, i, model) {
			continue
		}
		// Even providers carry a live token budget for their primary model
		// (benchHeartbeat), which is what the clamp gates.
		if i%2 == 0 && ref.models[i%benchFleetModels] == model && len(budgeted) < 1 {
			budgeted = append(budgeted, i)
		} else {
			others = append(others, i)
		}
	}
	if len(budgeted) < 1 || len(others) < 8 {
		t.Fatalf("fixture too small: budgeted=%d others=%d", len(budgeted), len(others))
	}
	faulted := map[string]string{
		"breaker":           ref.ids[others[0]],
		"ejected":           ref.ids[others[1]],
		"capacity_cooldown": ref.ids[others[2]],
		"dispatch_load":     ref.ids[others[3]],
		"error_cooldown":    ref.ids[others[4]],
		"budget_clamp":      ref.ids[budgeted[0]],
	}
	for _, f := range fleets {
		r := f.reg
		for i := 0; i < providerBreakerConsecTrip; i++ {
			r.RecordProviderOutcome(faulted["breaker"], false, 500, "internal error")
		}
		r.mu.RLock()
		ejectedP := r.providers[faulted["ejected"]]
		r.mu.RUnlock()
		ejectedP.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "SER-MODE-EJECT"})
		for i := 0; i < healthEjectionConsecTrip+1; i++ {
			r.RecordProviderServeOutcome("serial:SER-MODE-EJECT", false, 500, "boom")
		}
		for i := 0; i < r.capacityCooldownCfg.Threshold+1; i++ {
			r.RecordCapacityReject(faulted["capacity_cooldown"], model)
		}
		r.RecordDispatchLoadFailure(faulted["dispatch_load"], model)
		for i := 0; i < inferenceErrorThreshold; i++ {
			r.RecordInferenceError(faulted["error_cooldown"], model, 500, RequestTraits{HasTools: true}.CooldownShape())
		}
		r.RecordCapacityReject(faulted["budget_clamp"], model)
		if !r.ProviderBreakerOpen(faulted["breaker"]) || !r.HealthEjectionOpen("serial:SER-MODE-EJECT") ||
			!r.CapacityCooldownActive(faulted["capacity_cooldown"], model) ||
			!r.dispatchLoadCooled(faulted["dispatch_load"], model, time.Now()) ||
			!r.InferenceErrorCooldownActive(faulted["error_cooldown"], model, RequestTraits{HasTools: true}.CooldownShape()) ||
			!r.BudgetClampActive(faulted["budget_clamp"], model) {
			t.Fatal("precondition: every fault kind must be armed")
		}
	}
	return fleets, faulted
}

// TestGateDecisionsIdenticalAcrossCommitModesUnderConcurrentRecorders: with
// the same fault script the routing walks (eligible pool, tallies, preflight
// verdicts) are identical in both commit modes, before and after a phase of
// concurrent scans, reservations and recorders — the recorders never touch
// r.mu, so the race detector is what proves the interleavings are safe, and
// the gate-level outcomes of every faulted provider match across modes.
func TestGateDecisionsIdenticalAcrossCommitModesUnderConcurrentRecorders(t *testing.T) {
	setHealthEjectionEnabledForTest(t, true)
	fleets, faulted := commitModeFleets(t, benchFleetModelID(0))
	model := benchFleetModelID(0)
	shapes := []struct {
		name   string
		traits RequestTraits
	}{
		{name: "plain"},
		{name: "tools", traits: RequestTraits{HasTools: true}},
	}
	compareWalks := func(stage string) {
		t.Helper()
		for _, shape := range shapes {
			var want walkOutcome
			for i, mode := range []reserveCommitMode{reserveCommitShared, reserveCommitGlobal} {
				pr := benchPendingRequest(model, 0)
				pr.Traits = shape.traits
				got := runWalks(fleets[mode].reg, model, pr, shape.traits, false)
				if i == 0 {
					want = got
					continue
				}
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("%s/%s: walks differ across commit modes\n shared: %+v\n global: %+v", stage, shape.name, want, got)
				}
			}
			for kind, id := range faulted {
				pr := benchPendingRequest(model, 0)
				pr.Traits = shape.traits
				got := runWalks(fleets[reserveCommitShared].reg, model, pr, shape.traits, false)
				for _, poolID := range got.pool {
					if poolID == id && (kind != "error_cooldown" || shape.name == "tools") {
						t.Fatalf("%s/%s: %s provider %s is in the eligible pool", stage, shape.name, kind, id)
					}
				}
			}
		}
		now := time.Now()
		for kind, id := range faulted {
			var want gateOutcomes
			for i, mode := range []reserveCommitMode{reserveCommitShared, reserveCommitGlobal} {
				r := fleets[mode].reg
				r.mu.RLock()
				p := r.providers[id]
				r.mu.RUnlock()
				got := collectGateOutcomes(r, p, model, now)
				if i == 0 {
					want = got
					continue
				}
				if got != want {
					t.Fatalf("%s: %s provider gate outcomes differ across commit modes\n shared: %+v\n global: %+v", stage, kind, want, got)
				}
			}
		}
	}
	compareWalks("before")

	// Concurrent phase: scans, reservations and every per-request recorder on
	// HEALTHY advertisers (their gate decisions cannot change), interleaved
	// with the faulted providers' state being read by every scan. Identical
	// scripts on both fleets; the interleaving itself is what the race
	// detector checks.
	healthy := func(f *benchFleet) []string {
		var out []string
		for i, id := range f.ids {
			if !benchProviderAdvertises(f, i, model) {
				continue
			}
			isFaulted := false
			for _, fid := range faulted {
				if fid == id {
					isFaulted = true
				}
			}
			if !isFaulted {
				out = append(out, id)
			}
		}
		return out
	}
	for mode, f := range fleets {
		r := f.reg
		ids := healthy(f)
		const workers, iters = 8, 120
		var wg sync.WaitGroup
		for w := 0; w < workers; w++ {
			wg.Add(1)
			go func(w int) {
				defer wg.Done()
				for i := 0; i < iters; i++ {
					id := ids[(w*iters+i)%len(ids)]
					switch i % 7 {
					case 0:
						pr := benchPendingRequest(model, 100_000+w*iters+i)
						if p, _ := r.ReserveProviderEx(model, pr); p != nil {
							p.RemovePending(pr.RequestID)
						}
					case 1:
						r.QuickCapacityCheckForRequest(model, 600, 512, RequestTraits{HasTools: i%2 == 0}, false)
					case 2:
						r.RecordProviderOutcome(id, true, 200, "")
					case 3:
						r.RecordCapacityAccept(id, model)
					case 4:
						r.RecordInferenceSuccess(id, model, "base")
					case 5:
						if sid := r.GetProviderStableIdentity(id); sid != "" {
							r.RecordProviderServeOutcome(sid, true, 200, "")
						}
						r.ClearDispatchLoadCooldown(id, model)
					case 6:
						r.PredictServable(model, 600, 600, 512, 128_000, RequestTraits{}, false)
					}
				}
			}(w)
		}
		wg.Wait()
		if t.Failed() {
			t.Fatalf("%s: concurrent phase failed", mode)
		}
	}
	compareWalks("after")
}

// TestRequestPathParallelSpeedup guards against the walk-wide-lock regression:
// scan + commit + the five per-request recorders must parallelize. Before this
// branch the parallel variant ran at ~1.0–1.3x the serial one (every writer
// drained the fleet-scan reader batch) while a read-only fleet walk on the
// same box parallelized ~3.5x; with per-identity gates and the read-locked
// commit the request path must reach at least 4x at 16 threads.
//
// The machine's own parallel ceiling is measured alongside (a pure RLock
// fleet walk, no writers): a box busy with other work cannot show 4x for ANY
// lock design, so on such a box the guard falls back to the relative
// property — the request path parallelizes at least 60% as well as the
// read-only walk — which the old global-write-lock path fails by a wide
// margin (1.2x vs 3.5x). Each quantity is the best of three interleaved
// fixed-work measurements so load drifting between them does not fake a
// ratio. A box
// whose 1-minute load average exceeds twice GOMAXPROCS cannot measure
// parallelism at all (lock-holder preemption dominates every scheme); the
// numbers are logged and the guard skips. Also skipped under the race
// detector (it serializes goroutines) and on small machines.
func TestRequestPathParallelSpeedup(t *testing.T) {
	if raceDetectorEnabled {
		t.Skip("throughput guard is meaningless under the race detector")
	}
	if testing.Short() {
		t.Skip("-short")
	}
	procs := runtime.GOMAXPROCS(0)
	if procs < 8 {
		t.Skipf("GOMAXPROCS=%d; the speed-up guard needs >= 8", procs)
	}
	f := buildBenchFleet(t, benchFleetProviders, benchFleetModels)
	walk := func(n int) {
		model := f.models[n%len(f.models)]
		if c, _, _, _, _ := f.reg.QuickCapacityCheckWithTTFTForRequest(model, 600, 512, RequestTraits{}, false); c == 0 {
			t.Fatal("no candidates")
		}
	}
	var seq atomic.Int64
	path := func(n int) {
		requestPathOnce(t, f, f.models[n%len(f.models)], n)
	}
	// Fixed work per measurement (no iteration search): ops calls, serially or
	// split evenly across GOMAXPROCS goroutines; the result is ns per op.
	const ops = 2000
	timeOps := func(op func(int), parallel bool) int64 {
		start := time.Now()
		if !parallel {
			for i := 0; i < ops; i++ {
				op(int(seq.Add(1)))
			}
			return time.Since(start).Nanoseconds() / ops
		}
		var wg sync.WaitGroup
		per := ops / procs
		for w := 0; w < procs; w++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for i := 0; i < per; i++ {
					op(int(seq.Add(1)))
				}
			}()
		}
		wg.Wait()
		return time.Since(start).Nanoseconds() / int64(per*procs)
	}
	measure := map[string]func() int64{
		"read serial":   func() int64 { return timeOps(walk, false) },
		"read parallel": func() int64 { return timeOps(walk, true) },
		"path serial":   func() int64 { return timeOps(path, false) },
		"path parallel": func() int64 { return timeOps(path, true) },
	}
	order := []string{"read serial", "read parallel", "path serial", "path parallel"}
	best := map[string]int64{}
	for round := 0; round < 3; round++ {
		for _, name := range order {
			ns := measure[name]()
			if cur, ok := best[name]; !ok || ns < cur {
				best[name] = ns
			}
		}
	}
	readSpeedup := float64(best["read serial"]) / float64(best["read parallel"])
	pathSpeedup := float64(best["path serial"]) / float64(best["path parallel"])
	load, load1 := loadAverage()
	t.Logf("read-only walk: serial %v/op, parallel %v/op, speed-up %.2fx (the box's ceiling)",
		time.Duration(best["read serial"]), time.Duration(best["read parallel"]), readSpeedup)
	t.Logf("request path: serial %v/op, parallel %v/op at %d threads, speed-up %.2fx (%s)",
		time.Duration(best["path serial"]), time.Duration(best["path parallel"]), procs, pathSpeedup, load)
	if load1 > 2*float64(procs) {
		t.Skipf("box saturated (1-minute load %.0f on %d procs): parallelism cannot be measured here", load1, procs)
	}
	if readSpeedup >= 4 {
		if pathSpeedup < 4 {
			t.Fatalf("request path parallel speed-up %.2fx at %d threads, want >= 4x (a walk-wide lock is back?)", pathSpeedup, procs)
		}
		return
	}
	// Busy box: hold the relative property instead.
	if pathSpeedup < 0.6*readSpeedup {
		t.Fatalf("request path parallel speed-up %.2fx is below 60%% of the read-only walk's %.2fx on this box (a walk-wide lock is back?)",
			pathSpeedup, readSpeedup)
	}
	t.Logf("busy box (read-only ceiling %.2fx < 4x): asserted the relative property only", readSpeedup)
}

// loadAverage returns uptime's load-average text and the parsed 1-minute
// value (0 when unavailable).
func loadAverage() (text string, load1 float64) {
	out, err := exec.Command("uptime").Output()
	if err != nil {
		return "load n/a", 0
	}
	text = "load n/a"
	if i := strings.Index(string(out), "load"); i >= 0 {
		text = strings.TrimSpace(string(out)[i:])
	}
	// "load averages: 1.23 4.56 7.89" (darwin) / "load average: 1.23, 4.56, 7.89" (linux)
	fields := strings.Fields(strings.NewReplacer(",", " ", ":", " ").Replace(text))
	for i, fld := range fields {
		if strings.HasPrefix(fld, "average") && i+1 < len(fields) {
			fmt.Sscanf(fields[i+1], "%f", &load1)
			break
		}
	}
	return text, load1
}
