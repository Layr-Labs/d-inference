package registry_test

import (
	"sync"
	"testing"
	"time"

	"fmt"
	"sort"

	"sync/atomic"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
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

func TestDispatchLoadFailureReportsGateWait(t *testing.T) {
	options := identitygate.DefaultOptions()
	entered, released, finished := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var hold atomic.Bool
	options.Now = func() time.Time {
		if hold.CompareAndSwap(true, false) {
			close(entered)
			<-released
		}
		return time.Now()
	}
	gates := identitygate.New(testLogger(), &options)
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates})
	rec := &lockWaitRecorder{}
	reg.SetGateWaitObserver(rec.observe)
	gates.ResolveSession("load-failure", true)
	hold.Store(true)
	go func() {
		reg.RecordProviderOutcome("load-failure", false, 429, "")
		close(finished)
	}()
	<-entered
	var once sync.Once
	release := func() { once.Do(func() { close(released) }) }
	t.Cleanup(func() { release(); <-finished })
	go func() { time.Sleep(30 * time.Millisecond); release() }()
	if !reg.RecordDispatchLoadFailure("load-failure", "model") {
		t.Fatal("first failure did not start a cooldown")
	}
	if got := rec.bySite("dispatch_load_failure"); len(got) != 1 {
		t.Fatalf("failure gate samples = %d, want 1", len(got))
	}
}

// TestReserveProviderCountsScans: a clean reservation is one scan, a failed
// one is one scan, and a commit that loses the winner rescans and counts it.
func TestReserveProviderCountsScans(t *testing.T) {
	fixture := newPlanRegistryFixture()
	reg, preparation := fixture.registry, fixture.preparation
	model := "scan-count-model"

	if _, decision, _ := reg.ReserveProviderWithPlan(model, planTestRequest("no-provider", 10, 10)); decision.ScanCount != 1 {
		t.Fatalf("failed scan ScanCount = %d, want 1", decision.ScanCount)
	}

	providers := make([]*production.Provider, 3)
	for i := range providers {
		providers[i] = fixture.provider(t, fmt.Sprintf("p%02d", i), model, int64(i)*400)
		providers[i].Mu().Lock()
		providers[i].BackendCapacity.Slots[0].MaxConcurrency = 1
		providers[i].PrefillTPS = 1000 / float64(1+i*100)
		providers[i].Mu().Unlock()
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
	preparation.after = func(string) {
		if initialScans.Add(1) > 3 {
			return
		}
		arrived <- struct{}{}
		<-release
	}
	decisions := make([]production.RoutingDecision, 3)
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

// Global compatibility mode retains the write-wait observer. Per-identity
// recorders use their separate gate observer in both commit modes.
func TestLockWriteReportsWaitBySite(t *testing.T) {
	t.Setenv("EIGENINFERENCE_RESERVE_COMMIT_MODE", "global")
	fixture := newPlanRegistryFixture()
	reg := fixture.registry
	model := "lock-wait-model"
	p := fixture.provider(t, "lock-wait-provider", model, 0)
	other := fixture.provider(t, "lock-wait-other", model, 400)
	rec := &lockWaitRecorder{}
	reg.SetLockWaitObserver(rec.observe)
	prepared := fixture.preparation.planner.Prepare(model, planTestRequest("held-scan", 10, 10))
	go func() { time.Sleep(100 * time.Millisecond); prepared.Close() }()
	reg.ReserveProviderEx(model, planTestRequest("blocked-commit", 10, 10))
	p.RemovePending("blocked-commit")
	got := rec.bySite("commit")
	if len(got) != 1 || got[0].wait < 30*time.Millisecond {
		t.Fatalf("global commit wait: %+v", got)
	}
	primary, _, plan := reg.ReserveProviderWithPlan(model, planTestRequest("global-primary", 10, 10))
	if primary == nil || plan == nil {
		t.Fatal("primary reservation failed")
	}
	next, _, _ := reg.ReserveNextFromPlan(planTestRequest("global-next", 10, 10), plan, primary.ID)
	if next == nil {
		t.Fatal("plan reservation failed")
	}
	if len(rec.bySite("commit_plan")) != 1 {
		t.Fatal("global plan commit omitted write-wait sample")
	}
	reg.RecordCapacityAcceptOutcome(p.ID, model, true)
	reg.RecordInferenceSuccess(p.ID, model, production.RequestTraits{}.CooldownShape())
	reg.RecordProviderOutcome(p.ID, true, 200, "")
	reg.RecordProviderServeOutcome("stable-"+p.ID, true, 200, "")
	reg.ClearDispatchLoadCooldown(p.ID, model)
	for _, site := range []string{"capacity_accept", "inference_success", "breaker", "health_ejection", "dispatch_load_cooldown"} {
		if len(rec.bySite(site)) != 0 {
			t.Fatalf("gate recorder %s reported a global write wait", site)
		}
	}
	for _, provider := range []*production.Provider{p, other} {
		provider.RemovePending("global-primary")
		provider.RemovePending("global-next")
	}
}
