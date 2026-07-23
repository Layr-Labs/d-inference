package registry

import (
	"context"
	"encoding/base64"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

func TestCacheActivationOnePercentIsStickyAndDistributed(t *testing.T) {
	key := []byte("private-activation-test-key")
	body := []byte(`{"messages":[{"role":"user","content":"same prompt"}]}`)
	cohort := cacheActivationCohort(key, "account", "model", body)
	want := cacheActivationSampledIn(cohort, 1)
	for range 100 {
		if got := cacheActivationSampledIn(
			cacheActivationCohort(key, "account", "model", body), 1,
		); got != want {
			t.Fatalf("identical account/model/prompt changed cohort: got %t want %t", got, want)
		}
	}

	const population = 100_000
	selected := 0
	for i := range population {
		candidate := cacheActivationCohort(
			key,
			fmt.Sprintf("account-%d", i),
			"model",
			[]byte(fmt.Sprintf(`{"messages":[{"role":"user","content":"prompt-%d"}]}`, i)),
		)
		if cacheActivationSampledIn(candidate, 1) {
			selected++
		}
	}
	// A broad deterministic uniformity bound catches percentage/scale mistakes
	// without making the test probabilistic (the HMAC inputs and key are fixed).
	if selected < 850 || selected > 1150 {
		t.Fatalf("1%% cohort selected %d/%d, want approximately 1000", selected, population)
	}
}

func TestCacheActivationQPSLimiterRefillsAndSerializesConcurrency(t *testing.T) {
	gate := newCacheActivationGate(100, 1)
	cohort := []byte("12345678-concurrent-cohort")
	now := time.Unix(1_700_000_000, 0)
	var admitted atomic.Int64
	var workers sync.WaitGroup
	for range 64 {
		workers.Add(1)
		go func() {
			defer workers.Done()
			if gate.allow(cohort, now) == cacheActivationAdmitted {
				admitted.Add(1)
			}
		}()
	}
	workers.Wait()
	if got := admitted.Load(); got != 1 {
		t.Fatalf("concurrent initial admissions=%d, want token-bucket burst 1", got)
	}
	if got := gate.allow(cohort, now.Add(999*time.Millisecond)); got != cacheActivationThrottled {
		t.Fatalf("decision before refill=%q, want throttled", got)
	}
	if got := gate.allow(cohort, now.Add(time.Second)); got != cacheActivationAdmitted {
		t.Fatalf("decision after refill=%q, want admitted", got)
	}
}

func TestCacheActivationBoundsTwentyFiveRawRequestsPerSecondAtOneQPS(t *testing.T) {
	gate := newCacheActivationGate(100, 1)
	cohort := []byte("12345678-production-rate-cohort")
	start := time.Unix(1_700_000_000, 0)
	const (
		rawQPS   = 25
		duration = 3 * time.Second
	)
	requests := rawQPS * int(duration/time.Second)
	interval := time.Second / rawQPS
	admitted := 0
	for i := range requests {
		if gate.allow(cohort, start.Add(time.Duration(i)*interval)) == cacheActivationAdmitted {
			admitted++
		}
	}
	// One initial burst token plus one refill per completed second. The last raw
	// request arrives at 2.96s, so exactly three plans may be admitted.
	if admitted != 3 {
		t.Fatalf("admitted %d/%d plans at %d raw QPS, want 3 with burst=1", admitted, requests, rawQPS)
	}
	status := gate.snapshot()
	if status.Evaluated != uint64(requests) || status.Admitted != 3 ||
		status.RateLimited != uint64(requests-3) {
		t.Fatalf("activation counters=%+v", status)
	}
}

func TestCacheActivationUnlimitedByDefault(t *testing.T) {
	gate := newCacheActivationGate(100, 0)
	now := time.Unix(1_700_000_000, 0)
	for i := range 10_000 {
		cohort := []byte(fmt.Sprintf("12345678-%d", i))
		if got := gate.allow(cohort, now); got != cacheActivationAdmitted {
			t.Fatalf("unlimited decision %d=%q", i, got)
		}
	}
	if status := gate.snapshot(); status.Admitted != 10_000 || status.RateLimited != 0 {
		t.Fatalf("unlimited status=%+v", status)
	}
}

func TestPlanCacheRouteOffAndOperationalThrottleFailCold(t *testing.T) {
	reg := New(testLogger())
	client := promptcontract.NewClient(promptcontract.ClientConfig{
		SocketPath:     filepath.Join(t.TempDir(), "missing-sidecar.sock"),
		RequestTimeout: 50 * time.Millisecond,
	})
	defer client.Close()
	input := CachePlanInput{
		Account: "private-account", Model: "model",
		PromptContractID:     strings.Repeat("b", 64),
		ModelAggregateSHA256: strings.Repeat("a", 64),
		Body:                 []byte(`{"messages":[{"role":"user","content":"private"}]}`),
	}
	if result := reg.PlanCacheRouteWithResult(context.Background(), client, input); result.Outcome != CachePlanOff || result.Plan.present() {
		t.Fatalf("off result=%+v", result)
	}

	if err := reg.ConfigureCacheRouting(CacheRoutingConfig{
		Mode: CacheRoutingOn, ActivationPct: 100, MaxPlanQPS: 1,
		TTL: time.Minute, MaxHolders: 4, MaxDiscountMs: 1000, MaxCostFraction: .35,
		MasterKey: base64.RawURLEncoding.EncodeToString(
			[]byte("0123456789abcdef0123456789abcdef")),
	}); err != nil {
		t.Fatal(err)
	}
	reg.SetModelCatalog([]CatalogEntry{{ID: "model", WeightHash: strings.Repeat("a", 64)}})
	staleInput := input
	staleInput.ModelAggregateSHA256 = strings.Repeat("c", 64)
	if stale := reg.PlanCacheRouteWithResult(context.Background(), client, staleInput); stale.Outcome != CachePlanIneligible || stale.Plan.present() || stale.SidecarCalled {
		t.Fatalf("stale provision identity reached sidecar after catalog promotion: %+v", stale)
	}
	first := reg.PlanCacheRouteWithResult(context.Background(), client, input)
	if first.Outcome != CachePlanSidecarError || first.Plan.present() {
		t.Fatalf("first fail-cold result=%+v", first)
	}
	second := reg.PlanCacheRouteWithResult(context.Background(), client, input)
	if second.Outcome != CachePlanThrottled || second.Plan.present() || second.SidecarCalled {
		t.Fatalf("rate-limited fail-cold result=%+v", second)
	}
	status := reg.CacheRoutingActivationStatus()
	if status.Evaluated != 2 || status.Admitted != 1 || status.RateLimited != 1 || status.PlanFailed != 1 {
		t.Fatalf("activation status=%+v", status)
	}
}

func TestPlanCacheRouteClassifiesDynamicContractAsHealthyColdOnly(t *testing.T) {
	root, err := filepath.EvalSymlinks("/tmp")
	if err != nil {
		t.Fatal(err)
	}
	temp, err := os.MkdirTemp(root, "cache-activation-dynamic-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(temp) })
	socket := filepath.Join(temp, "sidecar.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = w.Write([]byte(`{"error":{"code":"dynamic_time","message":"cold only"}}`))
	})}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })

	client := promptcontract.NewClient(promptcontract.ClientConfig{
		SocketPath: socket, RequestTimeout: time.Second,
	})
	t.Cleanup(client.Close)
	reg := New(testLogger())
	if err := reg.ConfigureCacheRouting(CacheRoutingConfig{
		Mode: CacheRoutingOn, ActivationPct: 100,
		TTL: time.Minute, MaxHolders: 4, MaxDiscountMs: 1000, MaxCostFraction: .35,
		MasterKey: base64.RawURLEncoding.EncodeToString(
			[]byte("0123456789abcdef0123456789abcdef")),
	}); err != nil {
		t.Fatal(err)
	}
	aggregate := strings.Repeat("a", 64)
	reg.SetModelCatalog([]CatalogEntry{{ID: "gpt-oss", WeightHash: aggregate}})
	result := reg.PlanCacheRouteWithResult(context.Background(), client, CachePlanInput{
		Account: "account", Model: "gpt-oss",
		PromptContractID: strings.Repeat("b", 64), ModelAggregateSHA256: aggregate,
		Body: []byte(`{"model":"gpt-oss","messages":[{"role":"user","content":"hi"}]}`),
	})
	if result.Outcome != CachePlanColdOnly || result.Plan.present() || !result.SidecarCalled {
		t.Fatalf("dynamic-time result=%+v", result)
	}
	status := reg.CacheRoutingActivationStatus()
	if status.ColdOnly != 1 || status.PlanFailed != 0 || status.Planned != 0 {
		t.Fatalf("dynamic-time activation status=%+v", status)
	}
}
