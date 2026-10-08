package registry_test

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// A few ordinary attempt records fill this limit, so a test reaches byte
// pressure without large prompts.
const reclaimTestMaxAttemptBytes = 16 << 10

// fillAttemptBudget prepares requests until the byte budget refuses one. It
// returns the admitted requests, all still in flight, and the refused one.
func fillAttemptBudget(t *testing.T, r *budgetLifecycleFixture, provider *production.Provider) ([]*production.PendingRequest, *production.PendingRequest) {
	t.Helper()
	var admitted []*production.PendingRequest
	for index := 0; index < 64; index++ {
		request := budgetLifecycleRequest(r, fmt.Sprintf("%s-%02d", t.Name(), index))
		t.Cleanup(func() { r.ForgetCacheAttempt(request) })
		if err := r.PrepareCacheAttempt(request, provider); err != nil {
			t.Fatalf("optional byte refusal became an inference error: %v", err)
		}
		if !request.CacheRoutingParticipates() {
			return admitted, request
		}
		admitted = append(admitted, request)
	}
	t.Fatalf("setup: the byte budget never refused (%d admitted)", len(admitted))
	return nil, nil
}

// A finished request's record waits only for a late write-behind READY. When
// such records fill the budget, a new request reclaims the one that expires
// first instead of being dispatched without a cache scope.
func TestCacheAttemptBudgetReclaimsFinishedRecordsBeforeRefusing(t *testing.T) {
	r, provider, _ := budgetLifecycleRegistry(t, func(f *budgetLifecycleFixture, _ *production.CacheDependencies) {
		f.maxBytes = reclaimTestMaxAttemptBytes
	})
	tracker := r.tracker()
	finished, _ := fillAttemptBudget(t, r, provider)
	if len(finished) < 2 {
		t.Fatalf("setup: %d records fill the budget, want at least 2", len(finished))
	}
	budgetLifecycleWant(t, tracker, len(finished))
	nonces := make([]string, len(finished))
	for index, request := range finished {
		nonces[index] = preparedTestCacheMetadata(request).CacheReceiptNonce
		r.MarkCacheAttemptTerminal(request)
		r.clock.Advance(time.Millisecond) // distinct grace deadlines, oldest first
	}
	r.clock.Advance(time.Second) // far inside the two-minute terminal grace

	fresh := budgetLifecycleRequest(r, t.Name()+"-fresh")
	t.Cleanup(func() { r.ForgetCacheAttempt(fresh) })
	owner := budgetLifecyclePrepare(t, r, provider, fresh)
	if owner.CacheScope == "" || owner.PrefixCacheProtocol != 2 {
		t.Fatal("a new request reclaimed room but was dispatched without its cache scope")
	}
	retained := budgetLifecycleWant(t, tracker, len(finished))
	if _, exists := tracker.config.Attempts.Load(nonces[0]); exists {
		t.Error("the finished record that expires first was not the one reclaimed")
	}
	for _, nonce := range nonces[1:] {
		if _, exists := tracker.config.Attempts.Load(nonce); !exists {
			t.Error("more finished records were reclaimed than the new record needed")
		}
	}
	status := r.CacheRoutingLifecycleStatus()
	if status.AttemptGraceReclaimed != 1 || status.AttemptBudgetRefused != 1 || status.AttemptBytes != retained {
		t.Errorf("status grace_reclaimed=%d budget_refused=%d bytes=%d, want 1, 1 (the fill's refusal) and %d",
			status.AttemptGraceReclaimed, status.AttemptBudgetRefused, status.AttemptBytes, retained)
	}
}

// Reclaiming never takes an in-flight record: when in-flight records alone
// fill the budget, the new request is dispatched without a cache scope as
// before, and the cache status reports the refusal.
func TestCacheAttemptBudgetRefusesWhenInFlightRecordsFillIt(t *testing.T) {
	r, provider, _ := budgetLifecycleRegistry(t, func(f *budgetLifecycleFixture, _ *production.CacheDependencies) {
		f.maxBytes = reclaimTestMaxAttemptBytes
	})
	tracker := r.tracker()
	inFlight, refused := fillAttemptBudget(t, r, provider)
	assertOrdinaryCacheFrame(t, refused.CacheAttemptSnapshot())
	r.clock.Advance(time.Hour) // still inside the two-hour in-flight lifetime

	again := budgetLifecycleRequest(r, t.Name()+"-again")
	t.Cleanup(func() { r.ForgetCacheAttempt(again) })
	if err := r.PrepareCacheAttempt(again, provider); err != nil {
		t.Fatalf("optional byte refusal became an inference error: %v", err)
	}
	if again.CacheRoutingParticipates() {
		t.Fatal("an in-flight record was reclaimed to admit a new request")
	}
	assertOrdinaryCacheFrame(t, again.CacheAttemptSnapshot())
	budgetLifecycleWant(t, tracker, len(inFlight))
	for _, request := range inFlight {
		if _, exists := tracker.config.Attempts.Load(preparedTestCacheMetadata(request).CacheReceiptNonce); !exists {
			t.Fatal("an in-flight record was removed by byte pressure")
		}
	}

	raw, err := json.Marshal(r.CacheRoutingLifecycleStatus())
	if err != nil {
		t.Fatal(err)
	}
	var status map[string]any
	if err := json.Unmarshal(raw, &status); err != nil {
		t.Fatal(err)
	}
	if refused, _ := status["attempt_budget_refused"].(float64); refused != 2 {
		t.Errorf("attempt_budget_refused=%v, want 2: both dispatches lost their cache scope to the byte budget", status["attempt_budget_refused"])
	}
	if reclaimed, _ := status["attempt_grace_reclaimed"].(float64); reclaimed != 0 {
		t.Errorf("attempt_grace_reclaimed=%v, want 0: no finished record existed", status["attempt_grace_reclaimed"])
	}
	if bytes, _ := status["attempt_bytes"].(float64); bytes <= 0 || bytes > reclaimTestMaxAttemptBytes {
		t.Errorf("attempt_bytes=%v, want the retained total within the limit", status["attempt_bytes"])
	}
}
