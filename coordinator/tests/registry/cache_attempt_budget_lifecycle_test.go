package registry_test

import (
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"
	"unsafe"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCacheAttemptBudgetRefusalPreservesOrdinaryMetadataAndCalibration(t *testing.T) {
	r, provider, _ := budgetLifecycleRegistry(t, func(f *budgetLifecycleFixture, _ *production.CacheDependencies) {
		f.maxBytes = 1
	})
	request := budgetLifecycleRequest(r, t.Name())
	request.Attempt = 3
	tracker := r.tracker()
	notePrediction := func() {
		production.NoteTTFTPrediction(request.RequestID, request.Attempt, request.Model, "M3", 100)
	}
	notePrediction()
	t.Cleanup(func() {
		r.ForgetCacheAttempt(request)
		production.ResetTTFTCalibration()
	})
	// The pending join is observable only as settlement observes it, by
	// consuming the prediction. Each positive reading records it again.
	hasPrediction := func() bool {
		_, exists := production.RecordTTFTObservation(request.RequestID, request.Attempt, 100)
		if exists {
			notePrediction()
		}
		return exists
	}
	if !hasPrediction() {
		t.Fatal("calibration control was not recorded")
	}
	if err := r.PrepareCacheAttempt(request, provider); err != nil {
		t.Fatalf("optional byte refusal became an inference error: %v", err)
	}
	metadata := preparedTestCacheMetadata(request)
	if request.CacheRoutingParticipates() ||
		metadata.CacheReceiptNonce != "" || metadata.CacheScope != "" || metadata.PrefixCacheProtocol != 0 || metadata.CacheReceiptBoundaryMode != "" {
		t.Fatal("byte-refused preparation published ownership or cache metadata")
	}
	assertOrdinaryCacheFrame(t, request.CacheAttemptSnapshot())
	if !hasPrediction() || !request.CacheRoutingTelemetryEligible() {
		t.Fatal("byte refusal erased ordinary calibration or the existing telemetry population")
	}
	budgetLifecycleWant(t, tracker, 0)

	// A ledger's limit is fixed at construction: the positive control runs on a
	// replacement generation with the registry's default ledger.
	r.setMaxBytes(0)
	if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
		t.Fatal(err)
	}
	tracker = r.tracker()
	if tracker.config.AttemptBudget.MaxBytes() != indexKernelMaxAttemptBytes {
		t.Fatal("replacement generation did not receive the default byte limit")
	}
	request.CachePlan = r.plans.bind(request.CachePlan)
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
	tracker := r.tracker()
	admitted := tracker.config.Attempts.Lookup(owner.CacheReceiptNonce)
	if owner.CacheScope != callerScope || unsafe.StringData(owner.CacheScope) == unsafe.StringData(callerScope) ||
		unsafe.StringData(owner.CacheScope) != unsafe.StringData(admitted.Plan.CacheScope) {
		t.Fatal("published owner did not borrow the detached admitted scope")
	}
	snapshot := request.CacheAttemptSnapshot()
	request.CachePlan.CacheScope = "caller-replaced-header"
	var frame protocol.InferenceRequestMessage
	snapshot.ApplyTo(&frame)
	if frame.CacheScope != callerScope || frame.CacheReceiptNonce != owner.CacheReceiptNonce {
		t.Fatal("caller plan mutation changed immutable prepared metadata")
	}
	budgetLifecycleWant(t, tracker, 1)
	r.ForgetCacheAttempt(request)
	budgetLifecycleWant(t, tracker, 0)
	assertOrdinaryCacheFrame(t, snapshot)
	if snapshot.MetadataMessage().CacheScope != callerScope {
		t.Fatal("tracker refund rewrote separately surviving owner storage")
	}
	// The retained local owner/snapshot is deliberately outside the byte budget;
	// zero accounting does not claim that every referencing allocation was freed.
}

func TestCacheAttemptBudgetTerminalGraceRetainsChargeAndLateReady(t *testing.T) {
	r, provider, capability := budgetLifecycleRegistry(t)
	request, ready := checkpointPricingAttempt(t, r.Registry, provider, capability, t.Name(), r.plans.bind(exactTestPlan(exactTestAnchor(16, "c"))), 1)
	t.Cleanup(func() { r.ForgetCacheAttempt(request) })
	owner := preparedTestCacheMetadata(request)
	tracker := r.tracker()
	before := budgetLifecycleWant(t, tracker, 1)
	original := tracker.config.Attempts.Lookup(owner.CacheReceiptNonce)
	if original.ExpiresAt.Sub(original.CreatedAt) != indexKernelInFlightAttemptTTL {
		t.Fatal("ordinary preparation changed the two-hour inflight lifetime")
	}
	snapshot := request.CacheAttemptSnapshot()
	var dispatched protocol.InferenceRequestMessage
	snapshot.ApplyTo(&dispatched)
	if dispatched.CacheReceiptNonce == "" {
		t.Fatal("positive frame-acceptance control was not established")
	}
	terminalAt := original.CreatedAt.Add(time.Second)
	r.clock.Advance(terminalAt.Sub(r.clock.Now()))
	r.MarkCacheAttemptTerminal(request)
	assertOrdinaryCacheFrame(t, snapshot)
	if !request.CacheRoutingParticipates() || dispatched.CacheReceiptNonce != owner.CacheReceiptNonce {
		t.Fatal("terminal rewrote accepted-frame participation; original cutoff must survive")
	}
	terminal := tracker.config.Attempts.Lookup(owner.CacheReceiptNonce)
	if !terminal.ExpiresAt.Equal(terminalAt.Add(indexKernelAttemptTTL)) || terminal.AccountedBytes != original.AccountedBytes {
		t.Fatal("terminal grace changed immutable charge or did not retain the exact grace")
	}
	if !r.ApplyPrefixCacheReadyV2(provider.ID, ready) {
		t.Fatal("authenticated late READY was rejected inside terminal grace")
	}
	if budgetLifecycleWant(t, tracker, 1) != before {
		t.Fatal("prepaid READY update changed the charge")
	}
	tracker.core.SweepLocked(terminal.ExpiresAt.Add(-time.Nanosecond))
	if budgetLifecycleWant(t, tracker, 1) != before {
		t.Fatal("attempt charge was refunded before terminal grace expired")
	}
	tracker.core.SweepLocked(terminal.ExpiresAt)
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
			tracker := r.tracker()
			budgetLifecycleWant(t, tracker, 1)
			expires := tracker.config.Attempts.Lookup(owner.CacheReceiptNonce).ExpiresAt
			_, retainedBefore := tracker.core.ActiveAttemptLocked(owner.CacheReceiptNonce, expires.Add(-time.Nanosecond))
			retainedAtExpiry := false
			if method == "active_lookup" {
				_, retainedAtExpiry = tracker.core.ActiveAttemptLocked(owner.CacheReceiptNonce, expires)
			} else {
				tracker.core.SweepLocked(expires)
				_, retainedAtExpiry = tracker.config.Attempts.Load(owner.CacheReceiptNonce)
			}
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
			// Under the frozen test clock both records expire together and the
			// expiry heap breaks the tie on the nonce. The newer nonce sorts first,
			// so a cap of one evicts the newer record before its owner is
			// published, the scenario a zero cap covered before the registry
			// stopped accepting one.
			nonces := []string{"count-cutoff-nonce-1", "count-cutoff-nonce-0"}
			r, provider, _ := budgetLifecycleRegistry(t, func(f *budgetLifecycleFixture, deps *production.CacheDependencies) {
				// The registry accepts only a positive count cap. The zero case
				// therefore reaches the kernel alone, which applies it below.
				deps.MaxAttempts = cap
				f.kernel = func(config *cachetracker.Config[*production.Provider]) { config.MaxAttempts = cap }
				deps.Nonces = func() (string, error) {
					if len(nonces) == 0 {
						return "", fmt.Errorf("count-cutoff fixture ran out of nonces")
					}
					next := nonces[0]
					nonces = nonces[1:]
					return next, nil
				}
			})
			tracker := r.tracker()
			var requests []*production.PendingRequest
			t.Cleanup(func() {
				for _, request := range requests {
					r.ForgetCacheAttempt(request)
				}
			})
			for index := 0; index < 2; index++ {
				request := budgetLifecycleRequest(r, fmt.Sprintf("count-cutoff-%d", index))
				requests = append(requests, request)
				budgetLifecyclePrepare(t, r, provider, request)
				if cap == 0 {
					tracker.core.EnforceAttemptCapLocked()
				}
				budgetLifecycleWant(t, tracker, cap)
			}
			if cap == 1 {
				if _, retained := tracker.config.Attempts.Load("count-cutoff-nonce-0"); retained {
					t.Fatal("the newer record was not the one the count cap evicted before publication")
				}
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
			tracker := r.tracker()
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
				r.SetModelCatalog([]production.CatalogEntry{{ID: "model", WeightHash: capability.ModelAggregateHash}, {ID: "replacement"}})
				r.SetModelAliases(map[string]production.AliasTarget{"public": {Desired: "replacement", Previous: "model"}})
				merged, dropped := r.MergeProviderModels(provider.ID, []protocol.ModelInfo{{ID: "replacement"}})
				if len(merged) != 1 || len(dropped) != 1 || dropped[0] != "model" {
					t.Fatal("model replacement fixture did not remove original model")
				}
			case "disconnect":
				r.Disconnect(provider.ID)
			case "reconfigure":
				if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
					t.Fatal(err)
				}
			}
			budgetLifecycleWant(t, tracker, 0)
			tracker.core.MarkAttemptTerminal(owner.CacheReceiptNonce, time.Now())
			tracker.core.RemoveAttemptLocked(owner.CacheReceiptNonce)
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
	old := r.tracker()
	retained := old.config.Attempts.Lookup(owner.CacheReceiptNonce)
	if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
		t.Fatal(err)
	}
	budgetLifecycleWant(t, old, 0)
	fresh := budgetLifecycleRequest(r, "replacement-budget-request")
	budgetLifecyclePrepare(t, r, provider, fresh)
	current := r.tracker()
	t.Cleanup(func() { r.ForgetCacheAttempt(request); r.ForgetCacheAttempt(fresh) })
	before := budgetLifecycleWant(t, current, 1)
	accepted := old.core.StoreAttemptLocked("late-retired-nonce", retained)
	old.core.RemoveAttemptLocked(owner.CacheReceiptNonce)
	if accepted {
		t.Fatal("retired tracker repopulated")
	}
	old.core.MarkAttemptTerminal(owner.CacheReceiptNonce, time.Now())
	r.MarkCacheAttemptTerminal(request)
	r.ForgetCacheAttempt(request)
	r.ForgetCacheAttempt(request)
	budgetLifecycleWant(t, old, 0)
	if budgetLifecycleWant(t, current, 1) != before {
		t.Fatal("old cleanup changed replacement-generation accounting")
	}
	r.ForgetCacheAttempt(fresh)
	budgetLifecycleWant(t, current, 0)
}

// The real publisher is paused after the attempt was admitted and charged,
// before the captured publication operation runs.
func TestCacheAttemptBudgetFailedPublicationRefundsAdmission(t *testing.T) {
	for _, change := range []string{"none", "revision", "terminal", "request_ticket", "reconfigure"} {
		t.Run(change, func(t *testing.T) {
			nonce := "staged-budget-" + change
			staged := make(chan production.CachePublication, 1)
			resume := make(chan bool, 1)
			r, provider, _ := budgetLifecycleRegistry(t, func(_ *budgetLifecycleFixture, deps *production.CacheDependencies) {
				deps.Nonces = func() (string, error) { return nonce, nil }
				deps.Publications = func(publication production.CachePublication) production.CachePublisher {
					return deferredCachePublication(func() bool {
						staged <- publication
						return <-resume
					})
				}
			})
			request := budgetLifecycleRequest(r, "budget-publication-"+change)
			tracker := r.tracker()
			t.Cleanup(func() { r.ForgetCacheAttempt(request); tracker.core.RemoveAttemptLocked(nonce) })
			finished := make(chan error, 1)
			go func() { finished <- r.PrepareCacheAttempt(request, provider) }()
			defer close(resume)
			var publication production.CachePublication
			select {
			case publication = <-staged:
			case <-time.After(time.Second):
				t.Fatal("new request was closed")
			}
			if _, admitted := tracker.config.Attempts.Load(nonce); !admitted {
				t.Fatal("publication-boundary fixture was not admitted")
			}
			budgetLifecycleWant(t, tracker, 1)
			switch change {
			case "revision":
				provider.Mu().Lock()
				r.revision.Advance()
				provider.Mu().Unlock()
			case "terminal":
				r.MarkCacheAttemptTerminal(request)
			case "request_ticket":
				r.ForgetCacheAttempt(request)
			case "reconfigure":
				if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
					t.Fatal(err)
				}
			}
			published := publication.Publish()
			resume <- published
			if err := <-finished; err != nil {
				t.Fatal(err)
			}
			if published != (change == "none") {
				t.Fatal("existing publication cutoff changed")
			}
			want := 0
			if published {
				want = 1
			}
			budgetLifecycleWant(t, tracker, want)
			r.ForgetCacheAttempt(request)
			tracker.core.RemoveAttemptLocked(nonce)
			budgetLifecycleWant(t, tracker, 0)
		})
	}
}

func TestCacheAttemptBudgetConcurrentPrepareRefuseSweepAndReconfigure(t *testing.T) {
	r, provider, _ := budgetLifecycleRegistry(t, func(f *budgetLifecycleFixture, _ *production.CacheDependencies) {
		f.maxBytes = 4096
	})
	old := r.tracker()
	r.setMaxBytes(0)
	const count = 16
	plan := r.plans.bind(exactTestPlan(exactTestAnchor(16, "c")))
	requests := make([]*production.PendingRequest, 2*count)
	for index := range requests {
		requests[index] = &production.PendingRequest{RequestID: fmt.Sprintf("budget-race-%02d", index), Model: "model", CachePlan: plan}
	}
	t.Cleanup(func() {
		for _, request := range requests {
			r.ForgetCacheAttempt(request)
		}
	})
	errors := make(chan error, 8*count+32)
	// Only the registry's private receipt mutex serializes the retained
	// indexes. Operations share this gate and a check excludes them, so each
	// check reads the tracker between concurrent operations, never inside one.
	var gate sync.RWMutex
	operate := func(work func()) {
		gate.RLock()
		defer gate.RUnlock()
		work()
	}
	check := func() {
		gate.Lock()
		defer gate.Unlock()
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
	prepare := func(request *production.PendingRequest) func() {
		return func() {
			operate(func() {
				if err := r.PrepareCacheAttempt(request, provider); err != nil {
					errors <- err
				}
			})
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
		if preparedTestCacheMetadata(request).CacheReceiptNonce != "" {
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
		func() {
			// The retained maintainer sweeps under the tracker's own mutex.
			operate(func() { old.maintenance.StateCounts(time.Now().Add(3 * time.Hour)) })
			check()
		},
		func() {
			operate(func() {
				if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
					errors <- err
				}
			})
			check()
		},
		func() {
			for _, request := range requests[:count] {
				operate(func() {
					r.ForgetCacheAttempt(request)
					r.ForgetCacheAttempt(request)
				})
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
	current := r.tracker()
	if current == old || old.config.Generation.Active() {
		t.Fatal("reconfiguration transition was not exercised")
	}
	budgetLifecycleWant(t, current, 0)
}
