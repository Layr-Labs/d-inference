package registry

import (
	"fmt"
	"sort"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type lockWaitSample struct {
	site string
	wait time.Duration
}

type lockWaitRecorder struct {
	mu      sync.Mutex
	samples []lockWaitSample
}

func (r *lockWaitRecorder) observe(site string, wait time.Duration) {
	r.mu.Lock()
	r.samples = append(r.samples, lockWaitSample{site: site, wait: wait})
	r.mu.Unlock()
}

func (r *lockWaitRecorder) bySite(site string) []lockWaitSample {
	r.mu.Lock()
	defer r.mu.Unlock()
	var out []lockWaitSample
	for _, s := range r.samples {
		if s.site == site {
			out = append(out, s)
		}
	}
	return out
}

// TestLockWriteReportsWaitBySite: every request-path recorder reports its
// write-lock acquisition to the observer tagged with its own site, and the
// reported wait reflects time actually spent blocked behind a reader.
func TestLockWriteReportsWaitBySite(t *testing.T) {
	reg := New(testLogger())
	model := "lock-wait-model"
	p := planTestProvider(t, reg, "lock-wait-provider", model, 0)

	// No observer registered: the sites still work.
	reg.ClearDispatchLoadCooldown(p.ID, model)

	rec := &lockWaitRecorder{}
	reg.SetLockWaitObserver(rec.observe)

	// Hold the lock for reading while a recorder tries to write.
	held := make(chan struct{})
	release := make(chan struct{})
	go func() {
		reg.mu.RLock()
		close(held)
		<-release
		reg.mu.RUnlock()
	}()
	<-held
	const hold = 100 * time.Millisecond
	go func() {
		time.Sleep(hold)
		close(release)
	}()
	reg.ClearDispatchLoadCooldown(p.ID, model)
	got := rec.bySite("dispatch_load_cooldown")
	if len(got) != 1 {
		t.Fatalf("dispatch_load_cooldown samples = %d, want 1", len(got))
	}
	// Generous floor: the acquisition blocks for close to the whole hold, but
	// a loaded -race run can delay the caller a few tens of milliseconds.
	if got[0].wait < 30*time.Millisecond {
		t.Fatalf("reported wait %s, want at least 30ms (the acquisition blocked behind a reader for %s)", got[0].wait, hold)
	}

	// Each recorder reports under its own site tag.
	reg.RecordCapacityAcceptOutcome(p.ID, model, true)
	reg.RecordInferenceSuccess(p.ID, model, RequestTraits{}.CooldownShape())
	reg.RecordProviderOutcome(p.ID, true, 200, "")
	reg.RecordProviderServeOutcome("stable-"+p.ID, true, 200, "")
	reg.ReserveProviderWithPlan(model, planTestRequest("lock-wait-req", 10, 10))
	for _, site := range []string{"capacity_accept", "inference_success", "breaker", "health_ejection", "commit"} {
		if len(rec.bySite(site)) == 0 {
			t.Fatalf("site %q reported no lock-wait sample", site)
		}
	}
	p.RemovePending("lock-wait-req")
}

// TestReserveProviderCountsScans: a clean reservation is one scan, a failed
// one is one scan, and a commit that loses the winner rescans and counts it.
func TestReserveProviderCountsScans(t *testing.T) {
	reg := New(testLogger())
	model := "scan-count-model"

	if _, decision, _ := reg.ReserveProviderWithPlan(model, planTestRequest("no-provider", 10, 10)); decision.ScanCount != 1 {
		t.Fatalf("failed scan ScanCount = %d, want 1", decision.ScanCount)
	}

	providers := make([]*Provider, 3)
	for i := range providers {
		providers[i] = planTestProvider(t, reg, fmt.Sprintf("p%02d", i), model, int64(i)*400)
		providers[i].mu.Lock()
		providers[i].BackendCapacity.Slots[0].MaxConcurrency = 1
		providers[i].mu.Unlock()
	}

	_, decision, _ := reg.ReserveProviderWithPlan(model, planTestRequest("single", 10, 10))
	if decision.ProviderID == "" || decision.ScanCount != 1 {
		t.Fatalf("clean reservation = provider %q ScanCount %d, want a provider with 1 scan", decision.ProviderID, decision.ScanCount)
	}
	for _, p := range providers {
		p.RemovePending("single")
	}

	// Three requests scan the same snapshot (barrier after the scan), so two
	// of them lose the commit to the shared winner and must rescan.
	arrived := make(chan struct{}, 3)
	release := make(chan struct{})
	var initialScans atomic.Int32
	reg.reservationAfterScan = func(string) {
		if initialScans.Add(1) > 3 {
			return
		}
		arrived <- struct{}{}
		<-release
	}
	decisions := make([]RoutingDecision, 3)
	var wg sync.WaitGroup
	for i := range decisions {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, decisions[i], _ = reg.ReserveProviderWithPlan(model, planTestRequest(fmt.Sprintf("shared-%d", i), 10, 10))
		}()
	}
	for range 3 {
		select {
		case <-arrived:
		case <-time.After(2 * time.Second):
			close(release)
			t.Fatal("scans did not reach the shared-scan barrier")
		}
	}
	close(release)
	wg.Wait()

	counts := make([]int, 0, 3)
	for i, d := range decisions {
		if d.ProviderID == "" {
			t.Fatalf("request %d found no provider", i)
		}
		counts = append(counts, d.ScanCount)
	}
	sort.Ints(counts)
	if counts[0] != 1 || counts[1] < 2 || counts[2] < 2 {
		t.Fatalf("ScanCount per request = %v, want one clean commit (1) and two rescans (>=2)", counts)
	}
	for i := range decisions {
		for _, p := range providers {
			p.RemovePending(fmt.Sprintf("shared-%d", i))
		}
	}
}

func TestDispatchLoadFailureReportsLockWait(t *testing.T) {
	reg := New(testLogger())
	rec := &lockWaitRecorder{}
	reg.SetLockWaitObserver(rec.observe)
	if !reg.RecordDispatchLoadFailure("load-failure", "model") {
		t.Fatal("first failure did not start a cooldown")
	}
	if got := rec.bySite("dispatch_load_failure"); len(got) != 1 {
		t.Fatalf("failure lock samples = %d, want 1", len(got))
	}
}
