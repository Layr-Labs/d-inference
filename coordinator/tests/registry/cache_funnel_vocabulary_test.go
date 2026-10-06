package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/cacheusage"
	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
	metriclabels "github.com/eigeninference/d-inference/coordinator/internal/observation/labels"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// The funnel reads an attempt's routing stage from the registry's opportunity
// reason by name. Every state an evaluated attempt can be in must land in a
// named routing stage; a renamed reason would otherwise file every request
// under routing_unobserved without failing anything.
func TestEveryEvaluatedCacheOpportunityHasAFunnelRoutingStage(t *testing.T) {
	cases := []struct {
		reason   string
		selected bool
		state    registry.CacheOpportunity
		want     cachefunnel.Routing
	}{
		{"no_repeat_observed", false, registry.CacheOpportunity{Evaluated: true}, cachefunnel.RoutingNoRepeat},
		{"repeat_without_holder", false, registry.CacheOpportunity{Evaluated: true, RepeatedPrefixTokens: 256}, cachefunnel.RoutingRepeatWithoutHolder},
		{"holder_evidence_unusable", false, registry.CacheOpportunity{Evaluated: true, MatchingHolders: 1}, cachefunnel.RoutingHolderUnusableOrUnavailable},
		{"holder_unavailable", false, registry.CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1}, cachefunnel.RoutingHolderUnusableOrUnavailable},
		{"holder_no_positive_credit", false, registry.CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1, UsableCandidates: 1}, cachefunnel.RoutingHolderUnusableOrUnavailable},
		{"holder_not_selected", false, registry.CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1, UsableCandidates: 1, CreditedCandidates: 1}, cachefunnel.RoutingHolderNotSelected},
		{"selected", true, registry.CacheOpportunity{Evaluated: true, MatchingHolders: 1, ValidHolders: 1, UsableCandidates: 1, CreditedCandidates: 1}, cachefunnel.RoutingSelected},
		{"selected_near_tie", true, registry.CacheOpportunity{Evaluated: true, CreditWonNearTie: true, MatchingHolders: 1, ValidHolders: 1, UsableCandidates: 1, CreditedCandidates: 1}, cachefunnel.RoutingSelected},
	}
	for _, c := range cases {
		t.Run(c.reason, func(t *testing.T) {
			attempt := &registry.PendingRequest{CacheOpportunity: c.state, CacheSelectionSelected: c.selected}
			if got := attempt.CacheOpportunityReason(); got != c.reason {
				t.Fatalf("opportunity reason = %q, want the fixture to be in state %q", got, c.reason)
			}
			if got := attempt.CacheFunnelAttempt().Routing; got != c.want || got == cachefunnel.RoutingNotObserved {
				t.Fatalf("funnel routing stage = %d, want %d", got, c.want)
			}
		})
	}
	unevaluated := &registry.PendingRequest{CacheSelectionSelected: true}
	if got := unevaluated.CacheFunnelAttempt().Routing; got != cachefunnel.RoutingNotObserved {
		t.Fatalf("an attempt that was never evaluated has routing stage %d, want unobserved", got)
	}
}

// Every cache outcome the usage validator accepts must map to a lookup stage,
// and nothing it rejects may be read as one.
func TestEveryValidCacheUsageOutcomeHasAFunnelLookupStage(t *testing.T) {
	accepted := map[string]cachefunnel.Lookup{
		"hit":              cachefunnel.LookupHit,
		"miss_absent":      cachefunnel.LookupMiss,
		"miss_corrupt":     cachefunnel.LookupMiss,
		"skipped_capacity": cachefunnel.LookupSkip,
		"skipped_cost":     cachefunnel.LookupSkip,
		"skipped_policy":   cachefunnel.LookupSkip,
	}
	for outcome, want := range accepted {
		usage := protocol.UsageInfo{PromptTokens: 512, CacheOutcome: outcome}
		if outcome == "hit" {
			usage.CacheTier, usage.CachedTokens, usage.PrefillTokensSaved = "memory", 256, 256
		}
		if !cacheusage.Valid(usage) {
			t.Fatalf("the usage validator no longer accepts %q; the funnel's lookup vocabulary is stale", outcome)
		}
		if got := cachefunnel.LookupFromUsageOutcome(outcome); got != want || got == cachefunnel.LookupNotReported {
			t.Fatalf("lookup stage for %q = %d, want %d", outcome, got, want)
		}
	}
	// Outcome names from the lookup receipt protocol that usage does not carry.
	for _, outcome := range []string{"", "miss", "skipped", "hit_partial", "unreported", "invalid"} {
		if cacheusage.Valid(protocol.UsageInfo{PromptTokens: 512, CacheOutcome: outcome}) &&
			cachefunnel.LookupFromUsageOutcome(outcome) == cachefunnel.LookupNotReported {
			t.Fatalf("the usage validator accepts %q, which the funnel does not map to a lookup stage", outcome)
		}
	}
}

// Both tiers the usage validator accepts on a hit must map to a funnel tier
// whose metric label is the tier's own name; anything else stays unreported.
// The label must also be the one the per-completion usage counters use, or
// the two families could not be summed by tier.
func TestEveryValidCacheUsageTierHasAFunnelTier(t *testing.T) {
	for tier, want := range map[string]cachefunnel.Tier{"memory": cachefunnel.TierMemory, "ssd": cachefunnel.TierSSD} {
		usage := protocol.UsageInfo{PromptTokens: 512, CacheOutcome: "hit", CacheTier: tier, CachedTokens: 256, PrefillTokensSaved: 256}
		if !cacheusage.Valid(usage) {
			t.Fatalf("the usage validator no longer accepts a %q hit; the funnel's tier vocabulary is stale", tier)
		}
		if got := cachefunnel.TierFromUsage(tier); got != want || got.String() != tier || got.String() != metriclabels.LowCardinalityCacheTier(tier) {
			t.Fatalf("funnel tier for %q = %d (%s), want %d", tier, got, got, want)
		}
	}
	for _, tier := range []string{"", "disk", "SSD", "remote"} {
		usage := protocol.UsageInfo{PromptTokens: 512, CacheOutcome: "hit", CacheTier: tier, CachedTokens: 256, PrefillTokensSaved: 256}
		if cacheusage.Valid(usage) {
			t.Fatalf("the usage validator accepts a hit on tier %q, which the funnel does not count", tier)
		}
		if got := cachefunnel.TierFromUsage(tier); got != cachefunnel.TierNotReported || got.String() != metriclabels.LowCardinalityCacheTier(tier) {
			t.Fatalf("funnel tier for %q = %d (%s), want not reported", tier, got, got)
		}
	}
}

// An attempt routed to a credited holder predicts that holder's anchor depth.
// An attempt with no selected holder predicts nothing, which is unknown, not
// zero.
func TestFunnelAttemptPredictsTheSelectedHoldersAnchorDepth(t *testing.T) {
	f := newCreditTestFixture(t)
	holder := f.holder(t, "holder")
	f.cold(t, "cold")

	_, _, first := f.reserve(t, "first-sight")
	if first.CacheSelectionSelected || first.CacheFunnelAttempt().Predicted.Known {
		t.Fatalf("an attempt with no holder predicts %+v, want unknown", first.CacheFunnelAttempt().Predicted)
	}

	f.publish(t, holder, "donor", f.checkpoint, 100)
	selected, _, repeat := f.reserve(t, "repeat")
	if selected != holder || !repeat.CacheSelectionSelected {
		t.Fatalf("the credited holder was not selected: %s %+v", selected.ID, repeat.CacheOpportunity)
	}
	if got := repeat.CacheFunnelAttempt().Predicted; got != cachefunnel.KnownTokens(f.checkpoint.TokenCount) {
		t.Fatalf("predicted = %+v, want the holder's %d-token anchor", got, f.checkpoint.TokenCount)
	}
}
