package registry

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
	"unsafe"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func budgetLifecycleRegistry(t *testing.T) (*Registry, *Provider, protocol.PrefixCacheV2Capability) {
	t.Helper()
	r, provider, capability := exactTestRegistry(t)
	capability.ReadyBoundaryMode = protocol.PrefixCacheReadyBoundaryCheckpoint
	provider.mu.Lock()
	provider.Models = []protocol.ModelInfo{{ID: "model", WeightHash: capability.ModelAggregateHash}}
	provider.PrefixCacheV2Models["model"] = capability
	r.modelIndex.sync(provider)
	provider.mu.Unlock()
	return r, provider, capability
}

func budgetLifecycleRequest(r *Registry, id string) *PendingRequest {
	return &PendingRequest{RequestID: id, Model: "model", EstimatedPromptTokens: 4096,
		CachePlan: boundTestCachePlan(r, exactTestPlan(exactTestAnchor(16, "c")))}
}

func budgetLifecyclePrepare(t *testing.T, r *Registry, provider *Provider, request *PendingRequest) *cacheAttemptOwner {
	t.Helper()
	if err := r.PrepareCacheAttempt(request, provider); err != nil {
		t.Fatal(err)
	}
	owner := request.cacheAttempt.Load()
	if owner == nil || !request.CacheRoutingParticipates() {
		t.Fatal("fixture did not prepare an admitted cache attempt")
	}
	return owner
}

// This checks conservation of stored immutable charges, independently of the
// production charging function. Formula correctness belongs to the unit suite.
// Returning errors lets concurrent callers report without Fatal in a goroutine.
func budgetLifecycleInvariant(tracker *cacheRoutingTracker) (int, uint64, error) {
	tracker.mu.Lock()
	defer tracker.mu.Unlock()
	count := len(tracker.attempts)
	if count != len(tracker.attemptOrder) || count != len(tracker.attemptOrderByNonce) || count > tracker.maxAttempts {
		return count, tracker.attemptBytes, fmt.Errorf("attempt map/heap/count cap mismatch")
	}
	var sum uint64
	for nonce, attempt := range tracker.attempts {
		if attempt.accountedBytes == 0 || attempt.accountedBytes > ^uint64(0)-sum {
			return count, tracker.attemptBytes, fmt.Errorf("zero or overflowing stored charge")
		}
		sum += attempt.accountedBytes
		entry := tracker.attemptOrderByNonce[nonce]
		if entry == nil || entry.nonce != nonce || entry.index < 0 || entry.index >= len(tracker.attemptOrder) || tracker.attemptOrder[entry.index] != entry {
			return count, tracker.attemptBytes, fmt.Errorf("attempt heap ownership mismatch")
		}
	}
	if sum != tracker.attemptBytes || sum > tracker.maxAttemptBytes {
		return count, tracker.attemptBytes, fmt.Errorf("retained charge sum=%d ledger=%d limit=%d", sum, tracker.attemptBytes, tracker.maxAttemptBytes)
	}
	return count, sum, nil
}

func budgetLifecycleWant(t *testing.T, tracker *cacheRoutingTracker, count int) uint64 {
	t.Helper()
	got, bytes, err := budgetLifecycleInvariant(tracker)
	if err != nil || got != count {
		t.Fatalf("attempts=%d want=%d bytes=%d invariant=%v", got, count, bytes, err)
	}
	return bytes
}

func TestCacheAttemptBudgetRefusalPreservesOrdinaryMetadataAndCalibration(t *testing.T) {
	r, provider, _ := budgetLifecycleRegistry(t)
	request := budgetLifecycleRequest(r, t.Name())
	request.Attempt = 3
	tracker := r.cacheRouting
	tracker.mu.Lock()
	tracker.maxAttemptBytes = 1
	tracker.mu.Unlock()
	ttftCalibration.notePrediction(request.RequestID, request.Attempt, request.Model, "M3", 100)
	t.Cleanup(func() {
		r.ForgetCacheAttempt(request)
		ttftCalibration.discardPrediction(request.RequestID, request.Attempt)
	})
	hasPrediction := func() bool {
		ttftCalibration.mu.Lock()
		defer ttftCalibration.mu.Unlock()
		_, exists := ttftCalibration.pending[ttftPendingKey(request.RequestID, request.Attempt)]
		return exists
	}
	if !hasPrediction() {
		t.Fatal("calibration control was not recorded")
	}
	if err := r.PrepareCacheAttempt(request, provider); err != nil {
		t.Fatalf("optional byte refusal became an inference error: %v", err)
	}
	metadata := preparedTestCacheMetadata(request)
	if request.cacheAttempt.Load() != nil || request.CacheRoutingParticipates() ||
		metadata.CacheReceiptNonce != "" || metadata.CacheScope != "" || metadata.PrefixCacheProtocol != 0 || metadata.CacheReceiptBoundaryMode != "" {
		t.Fatal("byte-refused preparation published ownership or cache metadata")
	}
	assertOrdinaryCacheFrame(t, request.CacheAttemptSnapshot())
	if !hasPrediction() || !request.CacheRoutingTelemetryEligible() {
		t.Fatal("byte refusal erased ordinary calibration or the existing telemetry population")
	}
	budgetLifecycleWant(t, tracker, 0)

	tracker.mu.Lock()
	tracker.maxAttemptBytes = cacheRoutingMaxAttemptBytes
	tracker.mu.Unlock()
	budgetLifecyclePrepare(t, r, provider, request)
	if hasPrediction() {
		t.Fatal("admitted positive control failed to discard cache-contaminated prediction")
	}
	budgetLifecycleWant(t, tracker, 1)
	r.ForgetCacheAttempt(request)
	r.ForgetCacheAttempt(request)
	budgetLifecycleWant(t, tracker, 0)
}

func TestCacheAttemptBudgetPublishedOwnerUsesDetachedAdmittedScope(t *testing.T) {
	r, provider, _ := budgetLifecycleRegistry(t)
	request := budgetLifecycleRequest(r, t.Name())
	backing := strings.Repeat("s", 1<<20)
	callerScope := backing[4096 : 4096+64]
	request.CachePlan.CacheScope = callerScope
	owner := budgetLifecyclePrepare(t, r, provider, request)
	t.Cleanup(func() { r.ForgetCacheAttempt(request) })
	tracker := owner.tracker
	tracker.mu.Lock()
	admitted := tracker.attempts[owner.nonce]
	tracker.mu.Unlock()
	if owner.scope != callerScope || unsafe.StringData(owner.scope) == unsafe.StringData(callerScope) ||
		unsafe.StringData(owner.scope) != unsafe.StringData(admitted.Plan.CacheScope) {
		t.Fatal("published owner did not borrow the detached admitted scope")
	}
	snapshot := request.CacheAttemptSnapshot()
	request.CachePlan.CacheScope = "caller-replaced-header"
	var frame protocol.InferenceRequestMessage
	snapshot.ApplyTo(&frame)
	if frame.CacheScope != callerScope || frame.CacheReceiptNonce != owner.nonce {
		t.Fatal("caller plan mutation changed immutable prepared metadata")
	}
	budgetLifecycleWant(t, tracker, 1)
	r.ForgetCacheAttempt(request)
	budgetLifecycleWant(t, tracker, 0)
	assertOrdinaryCacheFrame(t, snapshot)
	if owner.scope != callerScope {
		t.Fatal("tracker refund rewrote separately surviving owner storage")
	}
	// The retained local owner/snapshot is deliberately outside the byte budget;
	// zero accounting does not claim that every referencing allocation was freed.
}

func TestCacheAttemptBudgetTerminalGraceRetainsChargeAndLateReady(t *testing.T) {
	r, provider, capability := budgetLifecycleRegistry(t)
	request, ready := checkpointTestAttempt(t, r, provider, capability, t.Name(), exactTestPlan(exactTestAnchor(16, "c")), 1)
	t.Cleanup(func() { r.ForgetCacheAttempt(request) })
	owner := request.cacheAttempt.Load()
	tracker := owner.tracker
	before := budgetLifecycleWant(t, tracker, 1)
	tracker.mu.Lock()
	original := tracker.attempts[owner.nonce]
	tracker.mu.Unlock()
	if original.ExpiresAt.Sub(original.CreatedAt) != cacheRoutingInFlightAttemptTTL {
		t.Fatal("ordinary preparation changed the two-hour inflight lifetime")
	}
	snapshot := request.CacheAttemptSnapshot()
	var dispatched protocol.InferenceRequestMessage
	snapshot.ApplyTo(&dispatched)
	if dispatched.CacheReceiptNonce == "" {
		t.Fatal("positive frame-acceptance control was not established")
	}
	terminalAt := original.CreatedAt.Add(time.Second)
	request.markCacheAttemptTerminal(terminalAt)
	assertOrdinaryCacheFrame(t, snapshot)
	if !request.CacheRoutingParticipates() || dispatched.CacheReceiptNonce != owner.nonce {
		t.Fatal("terminal rewrote accepted-frame participation; original cutoff must survive")
	}
	tracker.mu.Lock()
	terminal := tracker.attempts[owner.nonce]
	tracker.mu.Unlock()
	if !terminal.ExpiresAt.Equal(terminalAt.Add(cacheRoutingAttemptTTL)) || terminal.accountedBytes != original.accountedBytes {
		t.Fatal("terminal grace changed immutable charge or did not retain the exact grace")
	}
	if !r.ApplyPrefixCacheReadyV2(provider.ID, ready) {
		t.Fatal("authenticated late READY was rejected inside terminal grace")
	}
	if budgetLifecycleWant(t, tracker, 1) != before {
		t.Fatal("prepaid READY update changed the charge")
	}
	tracker.mu.Lock()
	tracker.sweepLocked(terminal.ExpiresAt.Add(-time.Nanosecond))
	tracker.mu.Unlock()
	if budgetLifecycleWant(t, tracker, 1) != before {
		t.Fatal("attempt charge was refunded before terminal grace expired")
	}
	tracker.mu.Lock()
	tracker.sweepLocked(terminal.ExpiresAt)
	tracker.mu.Unlock()
	budgetLifecycleWant(t, tracker, 0)
	r.MarkCacheAttemptTerminal(request)
	r.ForgetCacheAttempt(request)
	r.ForgetCacheAttempt(request)
	budgetLifecycleWant(t, tracker, 0)
}

func TestCacheAttemptBudgetInflightExpiryRefundPaths(t *testing.T) {
	for _, method := range []string{"active_lookup", "sweep"} {
		t.Run(method, func(t *testing.T) {
			r, provider, _ := budgetLifecycleRegistry(t)
			request := budgetLifecycleRequest(r, t.Name())
			owner := budgetLifecyclePrepare(t, r, provider, request)
			t.Cleanup(func() { r.ForgetCacheAttempt(request) })
			tracker := owner.tracker
			budgetLifecycleWant(t, tracker, 1)
			tracker.mu.Lock()
			expires := tracker.attempts[owner.nonce].ExpiresAt
			_, retainedBefore := tracker.activeAttemptLocked(owner.nonce, expires.Add(-time.Nanosecond))
			retainedAtExpiry := false
			if method == "active_lookup" {
				_, retainedAtExpiry = tracker.activeAttemptLocked(owner.nonce, expires)
			} else {
				tracker.sweepLocked(expires)
				_, retainedAtExpiry = tracker.attempts[owner.nonce]
			}
			tracker.mu.Unlock()
			if !retainedBefore || retainedAtExpiry {
				t.Fatal("expiry cutoff changed")
			}
			budgetLifecycleWant(t, tracker, 0)
			r.ForgetCacheAttempt(request)
			budgetLifecycleWant(t, tracker, 0)
		})
	}
}

func TestCacheAttemptBudgetCountEvictionRefundsWithoutChangingPublication(t *testing.T) {
	for _, cap := range []int{0, 1} {
		t.Run(fmt.Sprint(cap), func(t *testing.T) {
			r, provider, _ := budgetLifecycleRegistry(t)
			tracker := r.cacheRouting
			tracker.mu.Lock()
			tracker.maxAttempts = cap
			tracker.mu.Unlock()
			var requests []*PendingRequest
			t.Cleanup(func() {
				for _, request := range requests {
					r.ForgetCacheAttempt(request)
				}
			})
			for index := 0; index < 2; index++ {
				request := budgetLifecycleRequest(r, fmt.Sprintf("count-cutoff-%d", index))
				requests = append(requests, request)
				budgetLifecyclePrepare(t, r, provider, request)
				budgetLifecycleWant(t, tracker, cap)
			}
			// A successful insertion can lose legacy count retention before
			// publication. A live owner is not proof of a retained charged record.
			for _, request := range requests {
				if !request.CacheRoutingParticipates() {
					t.Fatal("count policy unexpectedly changed owner publication")
				}
				r.ForgetCacheAttempt(request)
				r.ForgetCacheAttempt(request)
			}
			budgetLifecycleWant(t, tracker, 0)
		})
	}
}

func TestCacheAttemptBudgetLifecycleInvalidationRefunds(t *testing.T) {
	for _, change := range []string{"capability_removed", "epoch_changed", "protocol_downgrade", "model_replaced", "disconnect", "reconfigure"} {
		t.Run(change, func(t *testing.T) {
			r, provider, capability := budgetLifecycleRegistry(t)
			request := budgetLifecycleRequest(r, t.Name())
			owner := budgetLifecyclePrepare(t, r, provider, request)
			t.Cleanup(func() { r.ForgetCacheAttempt(request) })
			tracker := owner.tracker
			budgetLifecycleWant(t, tracker, 1)
			switch change {
			case "capability_removed":
				if err := r.UpdatePrefixCacheCapabilities(provider.ID, 2, nil); err != nil {
					t.Fatal(err)
				}
			case "epoch_changed":
				capability.CacheEpoch = "22222222-2222-2222-2222-222222222222"
				if err := r.UpdatePrefixCacheCapabilities(provider.ID, 2, []protocol.PrefixCacheV2Capability{capability}); err != nil {
					t.Fatal(err)
				}
			case "protocol_downgrade":
				if err := r.UpdatePrefixCacheCapabilities(provider.ID, 1, nil); err != nil {
					t.Fatal(err)
				}
			case "model_replaced":
				r.SetModelCatalog([]CatalogEntry{{ID: "model", WeightHash: capability.ModelAggregateHash}, {ID: "replacement"}})
				r.SetModelAliases(map[string]AliasTarget{"public": {Desired: "replacement", Previous: "model"}})
				merged, dropped := r.MergeProviderModels(provider.ID, []protocol.ModelInfo{{ID: "replacement"}})
				if len(merged) != 1 || len(dropped) != 1 || dropped[0] != "model" {
					t.Fatal("model replacement fixture did not remove original model")
				}
			case "disconnect":
				r.Disconnect(provider.ID)
			case "reconfigure":
				if err := r.ConfigureCacheRouting(generationTestConfig(CacheRoutingOn)); err != nil {
					t.Fatal(err)
				}
			}
			budgetLifecycleWant(t, tracker, 0)
			tracker.markAttemptTerminal(owner.nonce, time.Now())
			tracker.forgetAttempt(owner.nonce)
			r.ForgetCacheAttempt(request)
			r.ForgetCacheAttempt(request)
			budgetLifecycleWant(t, tracker, 0)
		})
	}
}

func TestCacheAttemptBudgetRetiredCallbacksCannotChargeReplacement(t *testing.T) {
	r, provider, _ := budgetLifecycleRegistry(t)
	request := budgetLifecycleRequest(r, "retired-budget-request")
	owner := budgetLifecyclePrepare(t, r, provider, request)
	old := owner.tracker
	old.mu.Lock()
	retained := old.attempts[owner.nonce]
	old.mu.Unlock()
	if err := r.ConfigureCacheRouting(generationTestConfig(CacheRoutingOn)); err != nil {
		t.Fatal(err)
	}
	budgetLifecycleWant(t, old, 0)
	fresh := budgetLifecycleRequest(r, "replacement-budget-request")
	freshOwner := budgetLifecyclePrepare(t, r, provider, fresh)
	t.Cleanup(func() { r.ForgetCacheAttempt(request); r.ForgetCacheAttempt(fresh) })
	before := budgetLifecycleWant(t, freshOwner.tracker, 1)
	old.mu.Lock()
	accepted := old.storeAttemptLocked("late-retired-nonce", retained)
	old.removeAttemptLocked(owner.nonce)
	old.mu.Unlock()
	if accepted {
		t.Fatal("retired tracker repopulated")
	}
	old.markAttemptTerminal(owner.nonce, time.Now())
	r.MarkCacheAttemptTerminal(request)
	r.ForgetCacheAttempt(request)
	r.ForgetCacheAttempt(request)
	budgetLifecycleWant(t, old, 0)
	if budgetLifecycleWant(t, freshOwner.tracker, 1) != before {
		t.Fatal("old cleanup changed replacement-generation accounting")
	}
	r.ForgetCacheAttempt(fresh)
	budgetLifecycleWant(t, freshOwner.tracker, 0)
}

func TestCacheAttemptBudgetFailedPublicationRefundsAdmission(t *testing.T) {
	for _, change := range []string{"none", "revision", "terminal", "request_ticket", "reconfigure"} {
		t.Run(change, func(t *testing.T) {
			r, provider, capability := budgetLifecycleRegistry(t)
			request := budgetLifecycleRequest(r, "budget-publication-"+change)
			ticket, open := request.beginCachePreparation()
			if !open {
				t.Fatal("new request was closed")
			}
			tracker := r.cacheRouting
			provider.mu.Lock()
			revision := provider.prefixCacheRevision
			provider.mu.Unlock()
			now, nonce := time.Now(), "staged-budget-"+change
			t.Cleanup(func() { r.ForgetCacheAttempt(request); tracker.forgetAttempt(nonce) })
			attempt := cacheAttempt{RequestID: request.RequestID, ProviderID: provider.ID, Provider: provider,
				Model: request.Model, CreatedAt: now, ExpiresAt: now.Add(cacheRoutingInFlightAttemptTTL),
				V2: true, Plan: request.CachePlan, V2Capability: capability, ExpectedPrompt: request.CachePlan.Boundaries[0]}
			tracker.mu.Lock()
			admitted := tracker.storeAttemptLocked(nonce, attempt)
			scope := tracker.attempts[nonce].Plan.CacheScope
			tracker.mu.Unlock()
			if !admitted {
				t.Fatal("publication-boundary fixture was not admitted")
			}
			owner := &cacheAttemptOwner{tracker: tracker, generation: tracker.generation, nonce: nonce, scope: scope, boundaryMode: capability.ReadyBoundaryMode}
			budgetLifecycleWant(t, tracker, 1)
			switch change {
			case "revision":
				provider.mu.Lock()
				provider.prefixCacheRevision++
				provider.mu.Unlock()
			case "terminal":
				r.MarkCacheAttemptTerminal(request)
			case "request_ticket":
				r.ForgetCacheAttempt(request)
			case "reconfigure":
				if err := r.ConfigureCacheRouting(generationTestConfig(CacheRoutingOn)); err != nil {
					t.Fatal(err)
				}
			}
			published := r.publishCacheAttempt(request, provider, revision, ticket, owner)
			if published != (change == "none") {
				t.Fatal("existing publication cutoff changed")
			}
			want := 0
			if published {
				want = 1
			}
			budgetLifecycleWant(t, tracker, want)
			r.ForgetCacheAttempt(request)
			tracker.forgetAttempt(nonce)
			budgetLifecycleWant(t, tracker, 0)
		})
	}
}

func TestCacheAttemptBudgetConcurrentPrepareRefuseSweepAndReconfigure(t *testing.T) {
	r, provider, _ := budgetLifecycleRegistry(t)
	old := r.cacheRouting
	old.mu.Lock()
	old.maxAttemptBytes = 4096
	old.mu.Unlock()
	const count = 16
	plan := boundTestCachePlan(r, exactTestPlan(exactTestAnchor(16, "c")))
	requests := make([]*PendingRequest, 2*count)
	for index := range requests {
		requests[index] = &PendingRequest{RequestID: fmt.Sprintf("budget-race-%02d", index), Model: "model", CachePlan: plan}
	}
	t.Cleanup(func() {
		for _, request := range requests {
			r.ForgetCacheAttempt(request)
		}
	})
	errors := make(chan error, 8*count+32)
	check := func() {
		if _, _, err := budgetLifecycleInvariant(old); err != nil {
			errors <- err
		}
	}
	run := func(jobs []func()) {
		start := make(chan struct{})
		var group sync.WaitGroup
		for _, job := range jobs {
			group.Add(1)
			go func(work func()) { defer group.Done(); <-start; work() }(job)
		}
		close(start)
		group.Wait()
	}
	prepare := func(request *PendingRequest) func() {
		return func() {
			if err := r.PrepareCacheAttempt(request, provider); err != nil {
				errors <- err
			}
			check()
		}
	}
	var first []func()
	for _, request := range requests[:count] {
		first = append(first, prepare(request))
	}
	run(first)
	admitted := 0
	for _, request := range requests[:count] {
		if request.cacheAttempt.Load() != nil {
			admitted++
		}
	}
	if admitted == 0 || admitted == count {
		t.Fatal("bounded burst did not exercise both admission and byte refusal")
	}
	var second []func()
	for _, request := range requests[count:] {
		second = append(second, prepare(request))
	}
	second = append(second,
		func() { old.mu.Lock(); old.sweepLocked(time.Now().Add(3 * time.Hour)); old.mu.Unlock(); check() },
		func() {
			if err := r.ConfigureCacheRouting(generationTestConfig(CacheRoutingOn)); err != nil {
				errors <- err
			}
			check()
		},
		func() {
			for _, request := range requests[:count] {
				r.ForgetCacheAttempt(request)
				r.ForgetCacheAttempt(request)
				check()
			}
		},
	)
	run(second)
	for _, request := range requests {
		r.ForgetCacheAttempt(request)
		r.ForgetCacheAttempt(request)
	}
	close(errors)
	for err := range errors {
		t.Error(err)
	}
	budgetLifecycleWant(t, old, 0)
	r.mu.RLock()
	current := r.cacheRouting
	r.mu.RUnlock()
	if current == old || !old.generation.revoked.Load() {
		t.Fatal("reconfiguration transition was not exercised")
	}
	budgetLifecycleWant(t, current, 0)
}
