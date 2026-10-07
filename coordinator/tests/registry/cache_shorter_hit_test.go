package registry_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// P held checkpoints at 2,048 and 4,096 and evicted the 4,096 file without
// rotating its epoch. Its next lookup is a valid hit at 2,048; no miss ever
// fires. The stale 4,096 holder must go for P only, and the scheduler must
// price P with the 2,048 saving it will actually deliver.
func TestShorterHitSupersedesDeeperHolderForThatProviderOnly(t *testing.T) {
	f := newShorterHitFixture(t)
	f.donate(t, f.p, "donor-p", 1, "ssd", f.plan, f.short, f.long)
	f.donate(t, f.q, "donor-q", 1, "ssd", f.plan, f.long)
	before := f.pricing.hints(f.plan, time.Now())
	if before[f.p.ID].CachedTokens != f.long.TokenCount || before[f.q.ID].CachedTokens != f.long.TokenCount {
		t.Fatalf("positive control: both machines should advertise 4,096: %+v", before)
	}

	if got := f.hit(t, f.p, "repeat-p", 3, "ssd", f.plan, f.short); !got.Accepted || cacheReceiptMismatch(got) {
		t.Fatalf("valid shorter hit = %+v", got)
	}

	if f.holds(f.p, f.plan, f.long, "ssd") {
		t.Fatal("P kept its 4,096 holder after proving only 2,048")
	}
	if !f.holds(f.p, f.plan, f.short, "ssd") {
		t.Fatal("P lost the 2,048 holder its hit just proved")
	}
	if !f.holds(f.q, f.plan, f.long, "ssd") {
		t.Fatal("P's shorter hit removed Q's 4,096 holder")
	}
	status := f.r.CacheRoutingLifecycleStatus()
	if status.HolderRemoved[string(cachetracker.RemovalShorterHit)] != 1 ||
		status.HolderRemoved[string(cachetracker.RemovalMissInvalidation)] != 0 ||
		status.HolderRemoved[string(cachetracker.RemovalProofMismatch)] != 0 {
		t.Fatalf("removal accounting = %+v", status.HolderRemoved)
	}
	if f.config.Holders.Len() != 2 {
		t.Fatalf("holders = %d, want P@2,048 and Q@4,096", f.config.Holders.Len())
	}

	// Never a fence, and the revision-free path leaves the capability usable.
	if status.FencesApplied != 0 || status.FencedCapabilities != 0 {
		t.Fatalf("shorter hit fenced the capability: %+v", status)
	}
	if _, reason := f.admission.Admit(f.p.ID, "model", "ssd"); reason != production.CacheReceiptAccepted {
		t.Fatalf("P capability = %s, want accepted", reason)
	}

	// The replay watermark is the hit's own sequence, untouched by removal.
	sequence := cachetracker.SequenceKey{ProviderID: f.p.ID, ModelID: "model", CacheEpoch: f.capability.CacheEpoch, Tier: "ssd"}
	watermark := f.config.Sequences.Lookup(sequence)
	if watermark != 3 {
		t.Fatalf("sequence watermark = %d, want 3", watermark)
	}
	if got := f.hit(t, f.p, "replay-p", 3, "ssd", f.plan, f.short); got.Reason != production.CacheReceiptSequence {
		t.Fatalf("replayed sequence = %+v, want %s", got, production.CacheReceiptSequence)
	}

	// The next hint credits P with what it proved, and Q with what it holds.
	hints := f.pricing.hints(f.plan, time.Now())
	if hint := hints[f.p.ID]; hint.CachedTokens != f.short.TokenCount ||
		hint.PrefillTokensSaved != f.short.TokenCount || hint.StageMs != 50 || hint.Tier != "ssd" {
		t.Fatalf("P hint = %+v, want the 2,048 boundary at its measured stage cost", hint)
	}
	if hint := hints[f.q.ID]; hint.CachedTokens != f.long.TokenCount {
		t.Fatalf("Q hint = %+v, want 4,096", hint)
	}

	// 4,096 tokens at 1,000 tok/s less a 100 ms stage ≈ 3,996 ms; small
	// receipt-age decay is allowed.
	selected, decision, _ := f.reserve(t, "prefers-q")
	if selected != f.q || decision.CacheTier != "ssd" ||
		decision.CacheEstimatedTTFTSavedMs < 3980 || decision.CacheEstimatedTTFTSavedMs > 3996 {
		t.Fatalf("true 4,096 holder was not preferred: provider=%s decision=%+v", selected.ID, decision)
	}

	// With Q gone P still serves, priced at 2,048 tokens less its measured
	// 50 ms stage ≈ 1,998 ms, not the 3,996 ms the stale holder claimed.
	f.r.Disconnect(f.q.ID)
	selected, decision, request := f.reserve(t, "only-p")
	if selected != f.p || decision.CacheTier != "ssd" ||
		decision.CacheEstimatedTTFTSavedMs < 1990 || decision.CacheEstimatedTTFTSavedMs > 1998 {
		t.Fatalf("P was not priced at the boundary it delivers: provider=%s decision=%+v", selected.ID, decision)
	}
	if request.CacheSelectionEstimatedTTFTSavedMs != decision.CacheEstimatedTTFTSavedMs || !request.CacheSelectionSelected {
		t.Fatalf("selection telemetry diverged from the decision: request=%v decision=%v",
			request.CacheSelectionEstimatedTTFTSavedMs, decision.CacheEstimatedTTFTSavedMs)
	}
}

// Removal is advisory. The request that hit at 2,048 prefills the rest and
// publishes 4,096 again; that ready re-teaches the boundary.
func TestShorterHitRemovalIsRetaughtByLaterReady(t *testing.T) {
	f := newShorterHitFixture(t)
	f.donate(t, f.p, "donor", 1, "ssd", f.plan, f.short, f.long)
	nonce := f.attempt(t, f.p, "repeat", f.plan)
	if got := f.lookup(t, f.p, "repeat", nonce, 3, "ssd", f.plan, &f.short); !got.Accepted {
		t.Fatalf("shorter hit = %+v", got)
	}
	if f.holds(f.p, f.plan, f.long, "ssd") {
		t.Fatal("deeper holder survived the shorter hit")
	}
	if got := f.pricing.hints(f.plan, time.Now())[f.p.ID].CachedTokens; got != f.short.TokenCount {
		t.Fatalf("hint after the shorter hit = %d tokens, want 2,048", got)
	}
	f.ready(t, f.p, "repeat", nonce, 4, "ssd", f.long)
	if !f.holds(f.p, f.plan, f.long, "ssd") || !f.holds(f.p, f.plan, f.short, "ssd") {
		t.Fatal("a later ready did not re-teach the deeper boundary")
	}
	if got := f.pricing.hints(f.plan, time.Now())[f.p.ID].CachedTokens; got != f.long.TokenCount {
		t.Fatalf("re-taught hint = %d tokens, want 4,096", got)
	}
	if got := f.removed(cachetracker.RemovalShorterHit); got != 1 {
		t.Fatalf("shorter_hit removals = %d, want 1", got)
	}
}

// Only the receipt's tier is touched: a resident hit says nothing about the
// durable store, and complete-checkpoint engines report a resident win as
// tier memory even when SSD staged a deeper run.
func TestShorterHitLeavesTheOtherTier(t *testing.T) {
	f := newShorterHitFixture(t)
	f.p.Mu().Lock()
	f.p.PrefixCacheMemoryModels = map[string]protocol.PrefixCacheV2Capability{"model": f.capability}
	f.p.Mu().Unlock()
	f.donate(t, f.p, "ssd-donor", 1, "ssd", f.plan, f.short, f.long)
	f.donate(t, f.p, "memory-donor", 1, "memory", f.plan, f.short, f.long)

	if got := f.hit(t, f.p, "resident-repeat", 3, "memory", f.plan, f.short); !got.Accepted {
		t.Fatalf("resident shorter hit = %+v", got)
	}
	if f.holds(f.p, f.plan, f.long, "memory") {
		t.Fatal("resident 4,096 holder survived a resident hit at 2,048")
	}
	if !f.holds(f.p, f.plan, f.long, "ssd") || !f.holds(f.p, f.plan, f.short, "ssd") {
		t.Fatal("a resident hit removed durable evidence")
	}
	if !f.holds(f.p, f.plan, f.short, "memory") {
		t.Fatal("resident hit lost the boundary it proved")
	}
	if got := f.removed(cachetracker.RemovalShorterHit); got != 1 {
		t.Fatalf("shorter_hit removals = %d, want 1", got)
	}
}

// Nothing is removed when the hit is the deepest boundary the provider is
// recorded at, or when the deeper holder belongs to another continuation.
func TestShorterHitRemovesNothingWithoutADeeperHolderOnThisPrompt(t *testing.T) {
	f := newShorterHitFixture(t)
	f.donate(t, f.p, "donor", 1, "ssd", f.plan, f.short, f.long)

	if got := f.hit(t, f.p, "deepest", 3, "ssd", f.plan, f.long); !got.Accepted {
		t.Fatalf("hit at the deepest held boundary = %+v", got)
	}
	if !f.holds(f.p, f.plan, f.long, "ssd") || !f.holds(f.p, f.plan, f.short, "ssd") {
		t.Fatal("hit at the deepest boundary removed a holder")
	}

	// Same first 2,048 tokens, different continuation: its 4,096 boundary
	// has another chain hash, so P's original 4,096 holder is not in this plan.
	diverged := f.pricing.plans.bind(exactTestPlan(
		f.short, exactTestAnchor(16, "9"), exactTestAnchor(17, "8")))
	if got := f.hit(t, f.p, "diverged", 4, "ssd", diverged, f.short); !got.Accepted {
		t.Fatalf("hit on a diverging prompt = %+v", got)
	}
	if !f.holds(f.p, f.plan, f.long, "ssd") {
		t.Fatal("a diverging prompt's shorter hit removed another continuation's holder")
	}
	if got := f.removed(cachetracker.RemovalShorterHit); got != 0 {
		t.Fatalf("shorter_hit removals = %d, want 0", got)
	}
}

// Outcomes that are not a hit never supersede: a skip means the provider did
// not try, and a mismatch takes the fence path with its own accounting.
func TestOnlyAnAcceptedHitSupersedes(t *testing.T) {
	for _, outcome := range []string{"skipped_capacity", "skipped_cost", "skipped_policy"} {
		t.Run(outcome, func(t *testing.T) {
			f := newShorterHitFixture(t)
			f.donate(t, f.p, "donor", 1, "ssd", f.plan, f.short, f.long)
			prompt := f.plan.Boundaries[len(f.plan.Boundaries)-1]
			lookup := fenceTestV2Lookup(f.attempt(t, f.p, "skip", f.plan), f.capability, prompt, 3)
			lookup.RequestID, lookup.Outcome = "skip", outcome
			if got := f.r.ApplyPrefixCacheLookupV2Result(f.p.ID, lookup); !got.Accepted {
				t.Fatalf("%s = %+v", outcome, got)
			}
			if !f.holds(f.p, f.plan, f.long, "ssd") || f.removed(cachetracker.RemovalShorterHit) != 0 {
				t.Fatalf("%s removed a holder", outcome)
			}
		})
	}
	t.Run("matched anchor mismatch", func(t *testing.T) {
		f := newShorterHitFixture(t)
		f.donate(t, f.p, "donor", 1, "ssd", f.plan, f.short, f.long)
		forged := f.short
		forged.ChainHash = strings.Repeat("9", 64)
		if got := f.hit(t, f.p, "forged", 3, "ssd", f.plan, forged); got.Reason != production.CacheReceiptMatchedMismatch {
			t.Fatalf("forged matched anchor = %+v", got)
		}
		status := f.r.CacheRoutingLifecycleStatus()
		if status.HolderRemoved[string(cachetracker.RemovalShorterHit)] != 0 || status.FencesApplied != 1 {
			t.Fatalf("mismatch took the shorter-hit path: %+v", status)
		}
	})
}
