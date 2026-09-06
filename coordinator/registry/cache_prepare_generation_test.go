package registry

import (
	"encoding/base64"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func generationTestConfig(mode string) CacheRoutingConfig {
	return CacheRoutingConfig{Mode: mode, ActivationPct: 100, MasterKey: base64.RawURLEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))}
}

func assertOrdinaryCacheFrame(t *testing.T, snapshot CacheAttemptSnapshot) {
	t.Helper()
	message := protocol.InferenceRequestMessage{CacheReceiptNonce: "old", CacheScope: "old", PrefixCacheProtocol: 2, CacheReceiptBoundaryMode: "old"}
	snapshot.ApplyTo(&message)
	if message.CacheReceiptNonce != "" || message.CacheScope != "" || message.PrefixCacheProtocol != 0 || message.CacheReceiptBoundaryMode != "" {
		t.Fatalf("revoked attempt leaked cache metadata: %+v", message)
	}
}

func TestCachePrepareRejectsUnboundAndRetiredPlans(t *testing.T) {
	for _, mode := range []string{CacheRoutingOn, CacheRoutingOff} {
		t.Run(mode, func(t *testing.T) {
			r, p, _ := exactTestRegistry(t)
			plan := exactTestPlan(exactTestAnchor(16, "c"))
			unbound := &PendingRequest{RequestID: "unbound", Model: "model", CachePlan: plan}
			if err := r.PrepareCacheAttempt(unbound, p); err != nil {
				t.Fatal(err)
			}
			if unbound.CacheRoutingParticipates() || preparedTestCacheMetadata(unbound).CacheReceiptNonce != "" {
				t.Fatal("synthetic unbound plan prepared")
			}
			plan = boundTestCachePlan(r, plan)
			if err := r.ConfigureCacheRouting(generationTestConfig(mode)); err != nil {
				t.Fatal(err)
			}
			stale := &PendingRequest{RequestID: "stale", Model: "model", CachePlan: plan}
			if err := r.PrepareCacheAttempt(stale, p); err != nil {
				t.Fatal(err)
			}
			if stale.CacheRoutingParticipates() || preparedTestCacheMetadata(stale).CacheReceiptNonce != "" {
				t.Fatal("old generation prepared after configuration replacement")
			}
			assertOrdinaryCacheFrame(t, stale.CacheAttemptSnapshot())
			fresh := &PendingRequest{RequestID: "fresh", Model: "model", CachePlan: boundTestCachePlan(r, plan)}
			if err := r.PrepareCacheAttempt(fresh, p); err != nil {
				t.Fatal(err)
			}
			if fresh.CacheRoutingParticipates() != (mode == CacheRoutingOn) {
				t.Fatal("fresh preparation did not honor mode")
			}
			r.ForgetCacheAttempt(fresh)
		})
	}
}

// Exercise the publication boundary itself, with an attempt already inserted
// into its captured tracker. No serving-path test hook or timing sleep is needed.
func TestCachePreparePublicationRevalidatesOwnership(t *testing.T) {
	for _, change := range []string{"none", "reconfigure", "off", "capability", "connection", "forget", "terminal", "replacement"} {
		t.Run(change, func(t *testing.T) {
			r, p, _ := exactTestRegistry(t)
			pr := &PendingRequest{RequestID: "staged", Model: "model"}
			ticket, open := pr.beginCachePreparation()
			if !open {
				t.Fatal("new request closed")
			}
			tracker := r.cacheRouting
			owner := &cacheAttemptOwner{tracker: tracker, generation: tracker.generation, nonce: "staged-nonce", scope: "scope"}
			revision := p.prefixCacheRevision
			tracker.mu.Lock()
			tracker.storeAttemptLocked(owner.nonce, cacheAttempt{RequestID: pr.RequestID, ProviderID: p.ID, Provider: p, Model: pr.Model, ExpiresAt: time.Now().Add(time.Hour)})
			tracker.mu.Unlock()
			switch change {
			case "reconfigure", "off":
				mode := CacheRoutingOn
				if change == "off" {
					mode = CacheRoutingOff
				}
				if err := r.ConfigureCacheRouting(generationTestConfig(mode)); err != nil {
					t.Fatal(err)
				}
			case "capability":
				p.mu.Lock()
				p.prefixCacheRevision++
				p.mu.Unlock()
			case "connection":
				r.mu.Lock()
				r.providers[p.ID] = &Provider{ID: p.ID}
				r.mu.Unlock()
			case "forget":
				r.ForgetCacheAttempt(pr)
			case "terminal":
				r.MarkCacheAttemptTerminal(pr)
			case "replacement":
				next, _ := pr.beginCachePreparation()
				replacement := &cacheAttemptOwner{tracker: tracker, generation: tracker.generation, nonce: "replacement", scope: "new"}
				if !pr.publishCacheAttempt(next, replacement) {
					t.Fatal("replacement failed")
				}
			}
			published := r.publishCacheAttempt(pr, p, revision, ticket, owner)
			if published != (change == "none") {
				t.Fatalf("publication=%v", published)
			}
			tracker.mu.Lock()
			_, retained := tracker.attempts[owner.nonce]
			tracker.mu.Unlock()
			if retained != published {
				t.Fatal("failed publication retained original nonce")
			}
			if change == "replacement" {
				if got := pr.cacheAttempt.Load(); got == nil || got.nonce != "replacement" {
					t.Fatal("old publication overwrote newer request owner")
				}
			} else if pr.CacheRoutingParticipates() != published {
				t.Fatal("unpublished attempt affects calibration")
			}
			r.ForgetCacheAttempt(pr)
		})
	}
}

func TestCacheQueuedRevocationAndAcceptedWriteCutoff(t *testing.T) {
	for _, accepted := range []bool{false, true} {
		for _, revoke := range []string{"reconfigure", "off", "terminal"} {
			t.Run(fmt.Sprintf("accepted=%t/%s", accepted, revoke), func(t *testing.T) {
				r, p, _ := exactTestRegistry(t)
				pr := &PendingRequest{RequestID: "queued", Model: "model", CachePlan: boundTestCachePlan(r, exactTestPlan(exactTestAnchor(16, "c")))}
				if err := r.PrepareCacheAttempt(pr, p); err != nil {
					t.Fatal(err)
				}
				snapshot := pr.CacheAttemptSnapshot()
				var inFlight protocol.InferenceRequestMessage
				if accepted {
					snapshot.ApplyTo(&inFlight)
					if inFlight.CacheReceiptNonce == "" {
						t.Fatal("valid attempt did not dispatch")
					}
				}
				if revoke == "terminal" {
					r.MarkCacheAttemptTerminal(pr)
				} else {
					mode := CacheRoutingOn
					if revoke == "off" {
						mode = CacheRoutingOff
					}
					if err := r.ConfigureCacheRouting(generationTestConfig(mode)); err != nil {
						t.Fatal(err)
					}
				}
				assertOrdinaryCacheFrame(t, snapshot)
				if pr.CacheRoutingParticipates() != accepted {
					t.Fatal("dequeue revocation corrupted accepted-write calibration exclusion")
				}
				if accepted && inFlight.CacheReceiptNonce == "" {
					t.Fatal("reconfiguration changed accepted immutable frame")
				}
				r.ForgetCacheAttempt(pr)
			})
		}
	}
}

func TestCacheOldSnapshotCannotChangeNewAttemptParticipation(t *testing.T) {
	r, p, _ := exactTestRegistry(t)
	pr := &PendingRequest{RequestID: "retry", Model: "model", CachePlan: boundTestCachePlan(r, exactTestPlan(exactTestAnchor(16, "c")))}
	if err := r.PrepareCacheAttempt(pr, p); err != nil {
		t.Fatal(err)
	}
	old := pr.CacheAttemptSnapshot()
	if err := r.PrepareCacheAttempt(pr, p); err != nil {
		t.Fatal(err)
	}
	assertOrdinaryCacheFrame(t, old)
	if !pr.CacheRoutingParticipates() {
		t.Fatal("old queued frame cleared replacement participation")
	}
	var message protocol.InferenceRequestMessage
	pr.CacheAttemptSnapshot().ApplyTo(&message)
	if message.CacheReceiptNonce == "" || message.CacheReceiptNonce == old.owner.nonce {
		t.Fatal("replacement did not retain its nonce")
	}
	r.ForgetCacheAttempt(pr)
}

func TestCacheTerminalRetainsReceiptGraceButRevokesQueue(t *testing.T) {
	r, p, capability := exactTestRegistry(t)
	plan := exactTestPlan(exactTestAnchor(16, "c"))
	pr, ready := checkpointTestAttempt(t, r, p, capability, "completed", plan, 1)
	snapshot := pr.CacheAttemptSnapshot()
	var message protocol.InferenceRequestMessage
	snapshot.ApplyTo(&message)
	r.MarkCacheAttemptTerminal(pr)
	assertOrdinaryCacheFrame(t, snapshot)
	if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("terminal discarded authenticated late donor receipt")
	}
	owner := snapshot.owner
	owner.tracker.mu.Lock()
	attempt, exists := owner.tracker.attempts[owner.nonce]
	owner.tracker.mu.Unlock()
	if !exists || time.Until(attempt.ExpiresAt) > cacheRoutingAttemptTTL {
		t.Fatal("terminal did not shorten original attempt grace")
	}
	if !pr.CacheRoutingParticipates() {
		t.Fatal("accepted cache attempt reentered ordinary calibration")
	}
	if err := r.PrepareCacheAttempt(pr, p); err != nil {
		t.Fatal(err)
	}
	if pr.cacheAttempt.Load() != nil {
		t.Fatal("terminal request reopened cache preparation")
	}
}

func TestCachePrepareReconfigureCancelConcurrent(t *testing.T) {
	r, p, _ := exactTestRegistry(t)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			if err := r.ConfigureCacheRouting(generationTestConfig(CacheRoutingOn)); err != nil {
				t.Error(err)
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			pr := &PendingRequest{RequestID: fmt.Sprintf("r-%d", i), Model: "model", CachePlan: boundTestCachePlan(r, exactTestPlan(exactTestAnchor(16, "c")))}
			if err := r.PrepareCacheAttempt(pr, p); err != nil {
				t.Error(err)
				return
			}
			snapshot := pr.CacheAttemptSnapshot()
			var workers sync.WaitGroup
			workers.Add(2)
			go func() { defer workers.Done(); r.MarkCacheAttemptTerminal(pr) }()
			go func() {
				defer workers.Done()
				var frame protocol.InferenceRequestMessage
				snapshot.ApplyTo(&frame)
				for j := 0; j < 20; j++ {
					_ = pr.CacheRoutingParticipates()
				}
			}()
			workers.Wait()
			assertOrdinaryCacheFrame(t, snapshot)
			r.ForgetCacheAttempt(pr)
		}
	}()
	wg.Wait()
	r.mu.RLock()
	tracker := r.cacheRouting
	r.mu.RUnlock()
	tracker.mu.Lock()
	remaining := len(tracker.attempts)
	tracker.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("cleanup left %d current-generation attempts", remaining)
	}
}
