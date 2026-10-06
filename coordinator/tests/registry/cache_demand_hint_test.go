package registry_test

import (
	"encoding/json"
	"strings"
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

// First sight travels beside the repeat count, never inside it, so a provider
// can tell a speculative request from a proven repeat. A count of 0 is left
// off the frame.
func TestCachePrepareForwardsFirstSightApartFromTheRepeat(t *testing.T) {
	for _, tc := range []struct{ repeat, firstSight, wantFirstSight int }{
		{0, 4096, 4096}, {2048, 0, 0}, {0, 0, 0}, {0, -5, 0},
	} {
		r, p, f := newPreparationFixture(t)
		plan := f.bind(cacheFlowPlan(cacheFlowAnchor(16, "c")))
		plan.RepeatedPrefixTokens, plan.FirstSightTokens = tc.repeat, tc.firstSight
		pr := &production.PendingRequest{RequestID: "request", Model: "model", CachePlan: plan}
		if err := r.PrepareCacheAttempt(pr, p); err != nil {
			t.Fatal(err)
		}
		var message protocol.InferenceRequestMessage
		pr.CacheAttemptSnapshot().ApplyTo(&message)
		if message.CacheRepeatedPrefixTokens == nil || *message.CacheRepeatedPrefixTokens != tc.repeat ||
			message.CacheFirstSightTokens != tc.wantFirstSight {
			t.Fatalf("planned repeat=%d first sight=%d: wire repeat=%v first sight=%d, want %d and %d",
				tc.repeat, tc.firstSight, message.CacheRepeatedPrefixTokens, message.CacheFirstSightTokens, tc.repeat, tc.wantFirstSight)
		}
		encoded, err := json.Marshal(message)
		if err != nil {
			t.Fatal(err)
		}
		if got := strings.Contains(string(encoded), "cache_first_sight_tokens"); got != (tc.wantFirstSight > 0) {
			t.Fatalf("planned first sight=%d: frame names the field=%v: %s", tc.firstSight, got, encoded)
		}
		r.ForgetCacheAttempt(pr)
	}
}

// A revoked or retired owner sends neither count, whichever one it held.
func TestCacheCountsClearedWithRevokedScope(t *testing.T) {
	for _, planned := range []struct {
		name               string
		repeat, firstSight int
	}{{"repeat", 2048, 0}, {"first sight", 0, 4096}} {
		for _, revoke := range []string{"forget", "terminal", "reconfigure", "off"} {
			t.Run(planned.name+"/"+revoke, func(t *testing.T) {
				r, p, f := newPreparationFixture(t)
				plan := f.bind(cacheFlowPlan(cacheFlowAnchor(16, "c")))
				plan.RepeatedPrefixTokens, plan.FirstSightTokens = planned.repeat, planned.firstSight
				pr := &production.PendingRequest{RequestID: "request", Model: "model", CachePlan: plan}
				if err := r.PrepareCacheAttempt(pr, p); err != nil {
					t.Fatal(err)
				}
				snapshot := pr.CacheAttemptSnapshot()
				var prepared protocol.InferenceRequestMessage
				snapshot.ApplyTo(&prepared)
				if prepared.CacheRepeatedPrefixTokens == nil || *prepared.CacheRepeatedPrefixTokens != planned.repeat ||
					prepared.CacheFirstSightTokens != planned.firstSight {
					t.Fatalf("prepared wire repeat=%v first sight=%d, want %d and %d",
						prepared.CacheRepeatedPrefixTokens, prepared.CacheFirstSightTokens, planned.repeat, planned.firstSight)
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
				stale := 7
				message := protocol.InferenceRequestMessage{CacheScope: "old", CacheRepeatedPrefixTokens: &stale, CacheFirstSightTokens: 9}
				snapshot.ApplyTo(&message)
				if message.CacheRepeatedPrefixTokens != nil || message.CacheFirstSightTokens != 0 || message.CacheScope != "" {
					t.Fatalf("revoked attempt leaked a cache count: %+v", message)
				}
			})
		}
	}
}

// The production plan observer records demand and the live registry preparation
// carries its count into the provider frame. With first sight off (minimum 0)
// neither the novel plan nor the repeat names a first-sight count.
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
		var message protocol.InferenceRequestMessage
		pr.CacheAttemptSnapshot().ApplyTo(&message)
		if got := message.CacheRepeatedPrefixTokens; got == nil || *got != planned.RepeatedPrefixTokens {
			t.Fatalf("%s: wire repeat=%v, want %d", name, got, planned.RepeatedPrefixTokens)
		}
		if planned.FirstSightTokens != 0 || message.CacheFirstSightTokens != 0 {
			t.Fatalf("%s: first sight is off, yet the plan holds %d and the frame carries %d",
				name, planned.FirstSightTokens, message.CacheFirstSightTokens)
		}
		r.ForgetCacheAttempt(pr)
	}
}

// A provider's demand-gate outcomes must be known here, or the coordinator
// drops their counts: skipped_novel for a fleet-novel checkpoint and
// write_speculative_limited for a first-sight checkpoint that yielded to
// write-budget pressure.
func TestDemandGateOutcomesAreKnownDonationOutcomeBuckets(t *testing.T) {
	r, _, _ := exactTestRegistry(t)
	for _, outcome := range []string{"skipped_novel", "write_speculative_limited"} {
		if _, ok := r.CacheRoutingLifecycleStatus().DonationOutcomes[outcome]; !ok {
			t.Fatalf("/v1/cache/status projection lacks the %s bucket", outcome)
		}
		if !cachepolicy.Contains(production.PrefixCacheDonationOutcomes(), outcome) {
			t.Fatalf("exact_cache.donation_outcome gauge vocabulary lacks %s", outcome)
		}
	}
}
