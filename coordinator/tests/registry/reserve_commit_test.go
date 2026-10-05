package registry_test

import (
	"fmt"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// TestReserveCommitAdmitsExactlyTheSerialCapacityUnderConcurrency: N
// goroutines committing against ONE provider admit exactly as many requests
// as a serial loop does (the provider's capacity), the pending set holds
// exactly those requests, and releasing them returns the count to zero in
// both commit modes. This is the no-double-booking invariant: the admit
// re-check and the pending debit share one p.mu section.
func TestReserveCommitAdmitsExactlyTheSerialCapacityUnderConcurrency(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode string) {
		t.Setenv("EIGENINFERENCE_RESERVE_COMMIT_MODE", mode)
		reg := production.New(testLogger())
		const model = "commit-cap-model"
		p := makeSchedulerProvider(t, reg, "capped", model, 100)
		p.Mu().Lock()
		p.BackendCapacity.Slots[0].MaxConcurrency = 4
		p.Mu().Unlock()
		newReq := func(i int) *production.PendingRequest {
			return &production.PendingRequest{
				RequestID:             fmt.Sprintf("%s-%d", mode, i),
				Model:                 model,
				EstimatedPromptTokens: 200,
				RequestedMaxTokens:    128,
				FirstContentBudgetMS:  10_000,
				FirstContentDeadline:  time.Now().Add(10 * time.Second),
			}
		}

		// The provider's capacity, measured serially.
		var serial []*production.PendingRequest
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
		if n := p.PendingCount(); n != 0 {
			t.Fatalf("pending after release = %d, want 0", n)
		}

		const workers = 32
		for round := 0; round < 5; round++ {
			reqs := make([]*production.PendingRequest, workers)
			var admitted atomic.Int32
			var wg sync.WaitGroup
			start := make(chan struct{})
			for i := range reqs {
				reqs[i] = newReq(1000 + round*workers + i)
				wg.Add(1)
				go func(pr *production.PendingRequest) {
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
			if n := p.PendingCount(); n != capacity {
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
			if n := p.PendingCount(); n != 0 {
				t.Fatalf("round %d: pending after release = %d, want 0", round, n)
			}
		}
	})
}

// TestReserveNextFromPlanAdmitsExactlyTheSerialCapacityUnderConcurrency is the
// plan-path twin of the test above: N goroutines, each consuming its own plan
// whose next entry is the same capped alternate, admit exactly the serial
// capacity. The snapshot, admit re-check, probe claim and debit share one
// p.mu hold in tryReserve too, in both commit modes.
func TestReserveNextFromPlanAdmitsExactlyTheSerialCapacityUnderConcurrency(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode string) {
		t.Setenv("EIGENINFERENCE_RESERVE_COMMIT_MODE", mode)
		reg, reservation := newReservationFixture()
		const model = "plan-cap-model"
		// The winner is only there to be excluded from every plan; the
		// alternate is the capped provider every plan consumes next.
		winner := makeSchedulerProvider(t, reg, "plan-winner", model, 100)
		alt := makeSchedulerProvider(t, reg, "plan-alt", model, 100)
		alt.Mu().Lock()
		alt.BackendCapacity.Slots[0].MaxConcurrency = 4
		alt.Mu().Unlock()
		newReq := func(i int) *production.PendingRequest {
			return &production.PendingRequest{
				RequestID:             fmt.Sprintf("plan-%s-%d", mode, i),
				Model:                 model,
				EstimatedPromptTokens: 200,
				RequestedMaxTokens:    128,
				FirstContentBudgetMS:  10_000,
				FirstContentDeadline:  time.Now().Add(10 * time.Second),
			}
		}
		planFor := func(pr *production.PendingRequest) *production.DispatchPlan {
			scan := reservation.planner.ScanCandidates(model, pr, false)
			var w *production.Candidate
			for _, c := range scan.Candidates {
				if c.ProviderID == winner.ID {
					w = c
				}
			}
			if w == nil {
				t.Fatal("winner missing from the scan pool")
			}
			// The alternate is the plan's only entry while it has headroom and
			// drops out of the scan pool (hence the plan) once it is full.
			plan := scan.Plan(model, w)
			next, _ := plan.PeekNext()
			if plan.Len() > 1 || (plan.Len() == 1 && next.ProviderID != alt.ID) {
				t.Fatalf("plan must hold at most the alternate, got %d entries", plan.Len())
			}
			return plan
		}

		var serial []*production.PendingRequest
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
			reqs := make([]*production.PendingRequest, workers)
			plans := make([]*production.DispatchPlan, workers)
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
				go func(pr *production.PendingRequest, plan *production.DispatchPlan) {
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
			if n := alt.PendingCount(); n != capacity {
				t.Fatalf("round %d: pending set holds %d, want %d", round, n, capacity)
			}
			for _, pr := range reqs {
				if pr.ProviderID == alt.ID {
					alt.RemovePending(pr.RequestID)
				}
			}
			if n := alt.PendingCount(); n != 0 {
				t.Fatalf("round %d: pending after release = %d, want 0", round, n)
			}
		}
	})
}

// TestCommitProbeClaimAdmitsExactlyOneAcrossSessions drives the half-open
// probe claim end to end through ReserveProviderEx: two sessions of ONE
// identity serve the model, the identity's capacity cooldown has expired, and
// N concurrent reservations must admit exactly one request, the probe, with
// the gate closed to everyone else afterwards. Commits on different providers
// do not share p.mu; only the check-and-claim under gate.mu makes this exact.
func TestCommitProbeClaimAdmitsExactlyOneAcrossSessions(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode string) {
		t.Setenv("EIGENINFERENCE_RESERVE_COMMIT_MODE", mode)
		synctest.Test(t, func(t *testing.T) {
			reg := production.New(testLogger())
			const model = "probe-race-model"
			p1 := attestSchedulerProvider(t, reg, "probe-sess-1", model, "SER-PROBE-RACE", 100)
			p2 := attestSchedulerProvider(t, reg, "probe-sess-2", model, "SER-PROBE-RACE", 100)
			cfg := identitygate.LoadCapacityCooldownConfig()
			for i := 0; i < cfg.Threshold; i++ {
				reg.RecordCapacityReject(p1.ID, model)
			}
			if !reg.CapacityCooldownActive(p2.ID, model) {
				t.Fatal("precondition: the identity's cooldown must gate both sessions")
			}
			// The real cooldown expires one second before the reservation race;
			// no reservation has claimed its half-open probe yet.
			time.Sleep(cfg.BaseTTL + time.Second)

			const workers = 16
			reqs := make([]*production.PendingRequest, workers)
			var admitted atomic.Int32
			var wg sync.WaitGroup
			start := make(chan struct{})
			for i := range reqs {
				reqs[i] = &production.PendingRequest{
					RequestID:             fmt.Sprintf("probe-%s-%d", mode, i),
					Model:                 model,
					EstimatedPromptTokens: 200,
					RequestedMaxTokens:    128,
					FirstContentBudgetMS:  10_000,
					FirstContentDeadline:  time.Now().Add(10 * time.Second),
				}
				wg.Add(1)
				go func(pr *production.PendingRequest) {
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
			if n := p1.PendingCount() + p2.PendingCount(); n != 1 {
				t.Fatalf("pending across the identity's sessions = %d, want 1", n)
			}
			if !reg.CapacityCooldownActive(p1.ID, model) || !reg.CapacityCooldownActive(p2.ID, model) {
				t.Fatal("the claimed probe must close the gate for both sessions")
			}
		})
	})
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
		if c, _, _, _, _ := f.reg.QuickCapacityCheckWithTTFTForRequest(model, 600, 512, production.RequestTraits{}, false); c == 0 {
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
