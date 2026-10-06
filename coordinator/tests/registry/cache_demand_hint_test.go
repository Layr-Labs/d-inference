package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func repeatedPrefixTokensOnWire(t *testing.T, pr *production.PendingRequest) *int {
	t.Helper()
	var message protocol.InferenceRequestMessage
	pr.CacheAttemptSnapshot().ApplyTo(&message)
	return message.CacheRepeatedPrefixTokens
}

// The provider gates complete-checkpoint writes on this count, so a granted
// scope must always carry it: 0 (novel fleet-wide) is a real value and only an
// absent field means "older coordinator, keep writing".
func TestCachePrepareForwardsRepeatedPrefixTokensWithGrantedScope(t *testing.T) {
	for _, tc := range []struct{ planned, want int }{{1024, 1024}, {0, 0}, {-5, 0}} {
		r, p, f := newPreparationFixture(t)
		plan := f.bind(cacheFlowPlan(cacheFlowAnchor(16, "c")))
		plan.RepeatedPrefixTokens = tc.planned
		pr := &production.PendingRequest{RequestID: "request", Model: "model", CachePlan: plan}
		if err := r.PrepareCacheAttempt(pr, p); err != nil {
			t.Fatal(err)
		}
		if !pr.CacheRoutingParticipates() {
			t.Fatal("prepared attempt did not participate")
		}
		got := repeatedPrefixTokensOnWire(t, pr)
		if got == nil || *got != tc.want {
			t.Fatalf("planned %d: wire repeat=%v, want %d", tc.planned, got, tc.want)
		}
		r.ForgetCacheAttempt(pr)
	}
}

func TestCacheRepeatedPrefixTokensClearedWithRevokedScope(t *testing.T) {
	for _, revoke := range []string{"forget", "terminal", "reconfigure", "off"} {
		t.Run(revoke, func(t *testing.T) {
			r, p, f := newPreparationFixture(t)
			plan := f.bind(cacheFlowPlan(cacheFlowAnchor(16, "c")))
			plan.RepeatedPrefixTokens = 2048
			pr := &production.PendingRequest{RequestID: "request", Model: "model", CachePlan: plan}
			if err := r.PrepareCacheAttempt(pr, p); err != nil {
				t.Fatal(err)
			}
			snapshot := pr.CacheAttemptSnapshot()
			if got := repeatedPrefixTokensOnWire(t, pr); got == nil || *got != 2048 {
				t.Fatalf("prepared wire repeat=%v, want 2048", got)
			}
			switch revoke {
			case "forget":
				r.ForgetCacheAttempt(pr)
			case "terminal":
				r.MarkCacheAttemptTerminal(pr)
			case "reconfigure":
				if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
					t.Fatal(err)
				}
			case "off":
				if err := r.ConfigureCacheRouting(production.CacheRoutingConfig{Mode: production.CacheRoutingOff, ActivationPct: 100}); err != nil {
					t.Fatal(err)
				}
			}
			message := protocol.InferenceRequestMessage{CacheScope: "old"}
			stale := 7
			message.CacheRepeatedPrefixTokens = &stale
			snapshot.ApplyTo(&message)
			if message.CacheRepeatedPrefixTokens != nil || message.CacheScope != "" {
				t.Fatalf("revoked attempt leaked repeat demand: %+v", message)
			}
		})
	}
}

// The production plan observer records demand and the live registry preparation
// carries its count into the provider frame.
func TestObservedDemandReachesPreparedFrame(t *testing.T) {
	r, p, f := newPreparationFixture(t)
	history := cachedemand.New(cachedemand.MaxEntries, time.Minute, cachehistory.New())
	key := []byte("private-route-key")
	plan := f.bind(cacheFlowPlan(
		cacheFlowAnchor(1, "c"), cacheFlowAnchor(2, "c"), cacheFlowAnchor(3, "c"), cacheFlowAnchor(4, "c")))
	first := plan
	first.ObserveRouteDemand(f.generation, history, key, time.Now(), 0)
	if first.RepeatedPrefixTokens != 0 {
		t.Fatalf("first plan matched itself: %d", first.RepeatedPrefixTokens)
	}
	second := plan
	second.ObserveRouteDemand(f.generation, history, key, time.Now(), 0)
	if second.RepeatedPrefixTokens != cacheFlowAnchor(4, "c").TokenCount {
		t.Fatalf("second plan repeat=%d, want final boundary", second.RepeatedPrefixTokens)
	}
	for name, planned := range map[string]production.CachePlan{"novel": first, "repeat": second} {
		pr := &production.PendingRequest{RequestID: name, Model: "model", CachePlan: planned}
		if err := r.PrepareCacheAttempt(pr, p); err != nil {
			t.Fatal(err)
		}
		got := repeatedPrefixTokensOnWire(t, pr)
		if got == nil || *got != planned.RepeatedPrefixTokens {
			t.Fatalf("%s: wire repeat=%v, want %d", name, got, planned.RepeatedPrefixTokens)
		}
		r.ForgetCacheAttempt(pr)
	}
}

func TestSkippedNovelIsAKnownDonationOutcomeBucket(t *testing.T) {
	r, _, _ := exactTestRegistry(t)
	if _, ok := r.CacheRoutingLifecycleStatus().DonationOutcomes["skipped_novel"]; !ok {
		t.Fatal("/v1/cache/status projection lacks the skipped_novel bucket")
	}
	if !cachepolicy.Contains(production.PrefixCacheDonationOutcomes(), "skipped_novel") {
		t.Fatal("exact_cache.donation_outcome gauge vocabulary lacks skipped_novel")
	}
}
