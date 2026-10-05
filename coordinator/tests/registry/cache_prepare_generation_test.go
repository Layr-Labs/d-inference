package registry_test

import (
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestCachePrepareRejectsUnboundAndRetiredPlans(t *testing.T) {
	for _, mode := range []string{production.CacheRoutingOn, production.CacheRoutingOff} {
		t.Run(mode, func(t *testing.T) {
			r, p, f := newPreparationFixture(t)
			plan := preparationPlan()
			unbound := &production.PendingRequest{RequestID: "unbound", Model: "model", CachePlan: plan}
			if err := r.PrepareCacheAttempt(unbound, p); err != nil {
				t.Fatal(err)
			}
			if unbound.CacheRoutingParticipates() || unbound.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce != "" {
				t.Fatal("synthetic unbound plan prepared")
			}
			plan = f.bind(plan)
			if err := r.ConfigureCacheRouting(generationTestConfig(mode)); err != nil {
				t.Fatal(err)
			}
			stale := &production.PendingRequest{RequestID: "stale", Model: "model", CachePlan: plan}
			if err := r.PrepareCacheAttempt(stale, p); err != nil {
				t.Fatal(err)
			}
			if stale.CacheRoutingParticipates() || stale.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce != "" {
				t.Fatal("old generation prepared after configuration replacement")
			}
			assertOrdinaryCacheFrame(t, stale.CacheAttemptSnapshot())
			fresh := &production.PendingRequest{RequestID: "fresh", Model: "model", CachePlan: f.bind(plan)}
			if err := r.PrepareCacheAttempt(fresh, p); err != nil {
				t.Fatal(err)
			}
			if fresh.CacheRoutingParticipates() != (mode == production.CacheRoutingOn) {
				t.Fatal("fresh preparation did not honor mode")
			}
			r.ForgetCacheAttempt(fresh)
		})
	}
}

func TestCacheQueuedRevocationAndAcceptedWriteCutoff(t *testing.T) {
	for _, accepted := range []bool{false, true} {
		for _, revoke := range []string{"reconfigure", "off", "terminal"} {
			t.Run(fmt.Sprintf("accepted=%t/%s", accepted, revoke), func(t *testing.T) {
				r, p, f := newPreparationFixture(t)
				pr := &production.PendingRequest{RequestID: "queued", Model: "model", CachePlan: f.bind(preparationPlan())}
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
					mode := production.CacheRoutingOn
					if revoke == "off" {
						mode = production.CacheRoutingOff
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
	r, p, f := newPreparationFixture(t)
	pr := &production.PendingRequest{RequestID: "retry", Model: "model", CachePlan: f.bind(preparationPlan())}
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
	if message.CacheReceiptNonce == "" || message.CacheReceiptNonce == old.MetadataMessage().CacheReceiptNonce {
		t.Fatal("replacement did not retain its nonce")
	}
	r.ForgetCacheAttempt(pr)
}

// The real metadata publisher is paused after staging, before the captured
// publication operation runs. All mutations below retain their original order.
func TestCachePreparePublicationRevalidatesOwnership(t *testing.T) {
	for _, change := range []string{"none", "reconfigure", "off", "capability", "connection", "forget", "terminal", "replacement"} {
		t.Run(change, func(t *testing.T) {
			staged := make(chan production.CachePublication, 1)
			resume := make(chan bool, 1)
			var nonceCount, publicationCount atomic.Int32
			r, p, f := newPreparationFixture(t, production.CacheDependencies{
				Nonces: func() (string, error) {
					if nonceCount.Add(1) == 1 {
						return "staged-nonce", nil
					}
					return "replacement", nil
				},
				Publications: func(publication production.CachePublication) production.CachePublisher {
					if publicationCount.Add(1) != 1 {
						return publication
					}
					return deferredCachePublication(func() bool {
						staged <- publication
						return <-resume
					})
				},
			})
			plan := preparationPlan()
			plan.CacheScope = "scope"
			pr := &production.PendingRequest{RequestID: "staged", Model: "model", CachePlan: f.bind(plan)}
			finished := make(chan error, 1)
			go func() { finished <- r.PrepareCacheAttempt(pr, p) }()
			defer close(resume)
			var publication production.CachePublication
			open := false
			select {
			case publication = <-staged:
				open = true
			case <-time.After(time.Second):
			}
			if !open {
				t.Fatal("new request closed")
			}
			attempts := f.attempts
			if _, admitted := attempts.Load("staged-nonce"); !admitted {
				t.Fatal("staged fixture insertion refused")
			}
			// Preserve the original staged receipt record through the same primary
			// directory. The real publisher is parked, so no tracker work races it.
			attempts.Store("staged-nonce", cachetracker.Attempt[*production.Provider]{RequestID: pr.RequestID, ProviderID: p.ID, Provider: p, Model: pr.Model, ExpiresAt: time.Now().Add(time.Hour)})
			switch change {
			case "reconfigure", "off":
				mode := production.CacheRoutingOn
				if change == "off" {
					mode = production.CacheRoutingOff
				}
				if err := r.ConfigureCacheRouting(generationTestConfig(mode)); err != nil {
					t.Fatal(err)
				}
			case "capability":
				p.Mu().Lock()
				f.revision.Advance()
				p.Mu().Unlock()
			case "connection":
				// This request is not in provider pending state: disconnect does
				// not close its ticket or advance the captured provider revision.
				// Publication must reject the replacement connection identity.
				r.Disconnect(p.ID)
				r.Register(p.ID, nil, &protocol.RegisterMessage{})
			case "forget":
				r.ForgetCacheAttempt(pr)
			case "terminal":
				r.MarkCacheAttemptTerminal(pr)
			case "replacement":
				plan.CacheScope = "new"
				pr.CachePlan = f.bind(plan)
				if err := r.PrepareCacheAttempt(pr, p); err != nil || !pr.CacheRoutingParticipates() {
					t.Fatal("replacement failed")
				}
			}
			published := publication.Publish()
			resume <- published
			if err := <-finished; err != nil {
				t.Fatal(err)
			}
			if published != (change == "none") {
				t.Fatalf("publication=%v", published)
			}
			_, retained := attempts.Load("staged-nonce")
			if retained != published {
				t.Fatal("failed publication retained original nonce")
			}
			if change == "replacement" {
				if got := pr.CacheAttemptSnapshot().MetadataMessage(); got.CacheReceiptNonce == "" || got.CacheReceiptNonce != "replacement" {
					t.Fatal("old publication overwrote newer request owner")
				}
			} else if pr.CacheRoutingParticipates() != published {
				t.Fatal("unpublished attempt affects calibration")
			}
			r.ForgetCacheAttempt(pr)
		})
	}
}

func TestCacheTerminalRetainsReceiptGraceButRevokesQueue(t *testing.T) {
	r, p, f := newPreparationFixture(t)
	pr, ready := preparationReady(t, r, p, f)
	snapshot := pr.CacheAttemptSnapshot()
	var message protocol.InferenceRequestMessage
	snapshot.ApplyTo(&message)
	r.MarkCacheAttemptTerminal(pr)
	assertOrdinaryCacheFrame(t, snapshot)
	if !r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("terminal discarded authenticated late donor receipt")
	}
	metadata := snapshot.MetadataMessage()
	attempt, exists := f.attempts.Load(metadata.CacheReceiptNonce)
	if !exists || time.Until(attempt.ExpiresAt) > 2*time.Minute {
		t.Fatal("terminal did not shorten original attempt grace")
	}
	if !pr.CacheRoutingParticipates() {
		t.Fatal("accepted cache attempt reentered ordinary calibration")
	}
	if err := r.PrepareCacheAttempt(pr, p); err != nil {
		t.Fatal(err)
	}
	if pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce != "" {
		t.Fatal("terminal request reopened cache preparation")
	}
}

func TestCachePrepareReconfigureCancelConcurrent(t *testing.T) {
	r, p, f := newPreparationFixture(t)
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
				t.Error(err)
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		for i := 0; i < 100; i++ {
			pr := &production.PendingRequest{RequestID: fmt.Sprintf("r-%d", i), Model: "model", CachePlan: f.bind(preparationPlan())}
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
	remaining := f.attempts.Len()
	if remaining != 0 {
		t.Fatalf("cleanup left %d current-generation attempts", remaining)
	}
}
