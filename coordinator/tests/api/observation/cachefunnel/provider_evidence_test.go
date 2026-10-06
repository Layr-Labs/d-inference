package cachefunnel_test

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/internal/observation/cachefunnel"
)

func hitOn(tier cachefunnel.Tier, reused, prefillSaved, providerPrompt int) cachefunnel.Completion {
	return cachefunnel.Completion{
		Lookup: cachefunnel.LookupHit, Tier: tier, Reused: cachefunnel.KnownTokens(reused),
		PrefillSaved: cachefunnel.KnownTokens(prefillSaved), ProviderPrompt: cachefunnel.KnownTokens(providerPrompt),
	}
}

func TestHitRequestsAreSplitByTier(t *testing.T) {
	ledger, collector := newCollectedLedger()
	for _, completion := range []cachefunnel.Completion{
		hitOn(cachefunnel.TierMemory, 2048, 2048, 4096),
		hitOn(cachefunnel.TierSSD, 1024, 768, 4096),
		hitOn(cachefunnel.TierSSD, 512, 512, 4096),
		// A miss that names a tier is not reuse from that tier.
		{Lookup: cachefunnel.LookupMiss, Tier: cachefunnel.TierSSD, Reused: cachefunnel.KnownTokens(0)},
	} {
		request := ledger.Enter()
		completedAs(selectedScoped, completion)(request)
		request.Close(false)
	}
	unselected := ledger.Enter()
	completedAs(coldScoped, hitOn(cachefunnel.TierMemory, 256, 256, 4096))(unselected)
	unselected.Close(false)

	status := ledger.Snapshot()
	if hit := requestsFor(status, cachefunnel.Hit); hit.Requests != 3 || hit.MemoryHitRequests != 1 || hit.SSDHitRequests != 2 {
		t.Fatalf("hit = %+v, want three requests: one memory, two ssd", hit)
	}
	if hit := requestsFor(status, cachefunnel.HitWithoutSelection); hit.Requests != 1 || hit.MemoryHitRequests != 1 || hit.SSDHitRequests != 0 {
		t.Fatalf("hit_without_selection = %+v, want its one memory hit", hit)
	}
	if miss := requestsFor(status, cachefunnel.SelectedMiss); miss.Requests != 1 || miss.MemoryHitRequests != 0 || miss.SSDHitRequests != 0 {
		t.Fatalf("selected_miss = %+v, want no tier counted for a miss", miss)
	}
	if status.Total.MemoryHitRequests != 2 || status.Total.SSDHitRequests != 2 {
		t.Fatalf("total = %+v, want two memory and two ssd hits", status.Total)
	}
	tiers := make(map[string]int)
	for _, record := range collector.snapshot() {
		tiers[record.HitTier.String()]++
	}
	if tiers["memory"] != 2 || tiers["ssd"] != 2 || tiers["none"] != 1 {
		t.Fatalf("record tiers = %v, want two memory, two ssd and the miss as none", tiers)
	}
	requireReconciled(t, status, collector.snapshot())
}

// Reused tokens are what is billed at the cache-read rate; prefill saved is
// the work skipped. With the provider's own prompt count beside them, reused
// and recomputed tokens and a reused-token share come from one source.
func TestProviderReportedTokensAreSummedBesideThePlannerCount(t *testing.T) {
	ledger, collector := newCollectedLedger()
	request := ledger.Enter()
	completedAs(selectedScoped, hitOn(cachefunnel.TierSSD, 1024, 768, 4100))(request)
	request.Close(false)

	hit := requestsFor(ledger.Snapshot(), cachefunnel.Hit)
	if hit.PromptTokens != 4096 || hit.ProviderPromptTokens != 4100 || hit.ReusedTokens != 1024 || hit.PrefillSavedTokens != 768 ||
		hit.ProviderPromptTokensUnknown != 0 || hit.PrefillSavedTokensUnknown != 0 {
		t.Fatalf("hit = %+v, want planner prompt 4096, provider prompt 4100, reused 1024, prefill saved 768", hit)
	}
	if recomputed := hit.ProviderPromptTokens - hit.PrefillSavedTokens; recomputed != 3332 {
		t.Fatalf("recomputed tokens = %d, want provider prompt minus prefill saved = 3332", recomputed)
	}
	requireReconciled(t, ledger.Snapshot(), collector.snapshot())
}

func TestCompletionWithoutCacheUsageKeepsItsProviderPromptCount(t *testing.T) {
	ledger, collector := newCollectedLedger()
	completed := ledger.Enter()
	completedAs(selectedScoped, cachefunnel.Completion{ProviderPrompt: cachefunnel.KnownTokens(4096)})(completed)
	completed.Close(false)
	abandoned := ledger.Enter()
	dispatchedAs(selectedScoped)(abandoned)
	abandoned.Close(false)

	status := ledger.Snapshot()
	unknown := requestsFor(status, cachefunnel.SelectedOutcomeUnknown)
	if unknown.ProviderPromptTokens != 4096 || unknown.ProviderPromptTokensUnknown != 0 ||
		unknown.ReusedTokensUnknown != 1 || unknown.PrefillSavedTokensUnknown != 1 {
		t.Fatalf("selected_outcome_unknown = %+v, want the provider prompt known and both reuse quantities unknown", unknown)
	}
	if failed := requestsFor(status, cachefunnel.ErroredAfterDispatch); failed.ProviderPromptTokensUnknown != 1 || failed.ProviderPromptTokens != 0 {
		t.Fatalf("errored_after_dispatch = %+v, want no provider prompt count for a request no provider completed", failed)
	}
	requireReconciled(t, status, collector.snapshot())
}

func TestPlannedAndDispatchedRequestsAreCountedDirectly(t *testing.T) {
	ledger, collector := newCollectedLedger()
	miss := completedWith(cachefunnel.LookupMiss, cachefunnel.KnownTokens(0))
	for _, drive := range []func(*cachefunnel.Request){
		planned,                                      // planned, never dispatched
		completedAs(coldScoped, miss),                // planned and dispatched
		dispatchedAs(selectedScoped),                 // planned and dispatched, never completed
		planningOnly(cachefunnel.PlanningSampledOut), // dispatched without a plan
		func(request *cachefunnel.Request) { // retried: two attempts, one request
			planned(request)
			request.NoteAttemptDispatched(coldScoped)
			request.NoteAttemptDispatched(coldScoped)
		},
		func(*cachefunnel.Request) {}, // ended before any planning decision
	} {
		request := ledger.Enter()
		drive(request)
		request.Close(false)
	}

	status := ledger.Snapshot()
	if status.Total.Requests != 6 || status.Total.Planned != 4 || status.Total.Dispatched != 4 || status.Total.Attempts != 5 {
		t.Fatalf("total = %+v, want 6 requests, 4 planned, 4 dispatched, 5 attempts", status.Total)
	}
	if sampled := requestsFor(status, cachefunnel.SampledOut); sampled.Planned != 0 || sampled.Dispatched != 1 {
		t.Fatalf("sampled_out = %+v, want a request served without a plan", sampled)
	}
	if early := requestsFor(status, cachefunnel.ErroredBeforeDispatch); early.Requests != 2 || early.Planned != 1 || early.Dispatched != 0 {
		t.Fatalf("errored_before_dispatch = %+v, want two requests, one of them planned, none dispatched", early)
	}
	requireReconciled(t, status, collector.snapshot())
}

func TestEvidenceAfterCloseIsCountedNotDropped(t *testing.T) {
	ledger, collector := newCollectedLedger()
	request := ledger.Enter()
	dispatchedAs(selectedScoped)(request)
	request.Close(true)
	// The client left; the provider finished anyway and a hedge frame landed.
	request.NoteAttemptCompleted(selectedScoped, hitOn(cachefunnel.TierSSD, 2048, 2048, 4096))
	request.NoteAttemptDispatched(coldScoped)
	request.NoteAttemptDispatched(coldScoped)

	status := ledger.Snapshot()
	if want := (cachefunnel.LateEvidence{Completions: 1, SSDHitCompletions: 1, AttemptDispatches: 2}); status.Late != want {
		t.Fatalf("late = %+v, want %+v", status.Late, want)
	}
	if got := requestsFor(status, cachefunnel.CancelledAfterDispatch); got.Requests != 1 || got.Attempts != 1 || status.Total.SSDHitRequests != 0 {
		t.Fatalf("status = %+v, want the closed request unchanged by late evidence", status)
	}
	if public := status.Public(); public.Late != status.Late {
		t.Fatalf("public late = %+v, want %+v", public.Late, status.Late)
	}
	requireReconciled(t, status, collector.snapshot())
}

// A late completion still feeds the per-completion usage counters, so it is
// counted in their units: hits by tier, and the reuse it reported by tier.
// Only then does "funnel plus late" equal those counters.
func TestLateCompletionsAreCountedByWhatTheyReported(t *testing.T) {
	ledger, collector := newCollectedLedger()
	completions := []cachefunnel.Completion{
		hitOn(cachefunnel.TierSSD, 2048, 1024, 4096),
		hitOn(cachefunnel.TierMemory, 512, 512, 4096),
		{Lookup: cachefunnel.LookupMiss, Tier: cachefunnel.TierSSD, Reused: cachefunnel.KnownTokens(0), PrefillSaved: cachefunnel.KnownTokens(0)},
		{ProviderPrompt: cachefunnel.KnownTokens(4096)}, // cache usage absent or rejected
	}
	for _, completion := range completions {
		request := ledger.Enter()
		dispatchedAs(selectedScoped)(request)
		request.Close(true)
		request.NoteAttemptCompleted(selectedScoped, completion)
	}

	status := ledger.Snapshot()
	if want := (cachefunnel.LateEvidence{Completions: 4, MemoryHitCompletions: 1, SSDHitCompletions: 1}); status.Late != want {
		t.Fatalf("late = %+v, want %+v", status.Late, want)
	}
	if total := status.Total; total.MemoryHitRequests != 0 || total.SSDHitRequests != 0 || total.LookupOutcomeReported != 0 || total.ReusedTokens != 0 {
		t.Fatalf("total = %+v, want no late completion folded into a closed request", total)
	}
	want := []cachefunnel.LateCompletion{
		{HitTier: cachefunnel.TierSSD, ReusedTokens: cachefunnel.KnownTokens(2048), PrefillSavedTokens: cachefunnel.KnownTokens(1024)},
		{HitTier: cachefunnel.TierMemory, ReusedTokens: cachefunnel.KnownTokens(512), PrefillSavedTokens: cachefunnel.KnownTokens(512)},
		// A miss on the SSD tier reused nothing and counts under no tier.
		{ReusedTokens: cachefunnel.KnownTokens(0), PrefillSavedTokens: cachefunnel.KnownTokens(0)},
		{},
	}
	got := collector.lateCompletions()
	if len(got) != len(want) {
		t.Fatalf("the sink received %d late completions, want %d: %+v", len(got), len(want), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("late completion %d = %+v, want %+v", i, got[i], want[i])
		}
	}
	requireReconciled(t, status, collector.snapshot())
}

// A hedged twin that completes second classifies nothing, but its usage has
// already fed the per-completion counters. It is late evidence even though
// the request is still open, or those counters would exceed the funnel by an
// amount nothing states.
func TestASecondCompletionBeforeCloseIsLateEvidence(t *testing.T) {
	ledger, collector := newCollectedLedger()
	request := ledger.Enter()
	planned(request)
	request.NoteAttemptDispatched(selectedScoped)
	request.NoteAttemptDispatched(selectedScoped)
	request.NoteAttemptCompleted(selectedScoped, hitOn(cachefunnel.TierMemory, 2048, 2048, 4096))
	request.NoteAttemptCompleted(selectedScoped, hitOn(cachefunnel.TierSSD, 2048, 1024, 4096))
	request.Close(false)

	status := ledger.Snapshot()
	if hit := requestsFor(status, cachefunnel.Hit); hit.Requests != 1 || hit.MemoryHitRequests != 1 || hit.SSDHitRequests != 0 || hit.Attempts != 2 {
		t.Fatalf("hit = %+v, want the first completion's memory hit over two attempts", hit)
	}
	if want := (cachefunnel.LateEvidence{Completions: 1, SSDHitCompletions: 1}); status.Late != want {
		t.Fatalf("late = %+v, want the second completion's SSD hit", status.Late)
	}
	if late := collector.lateCompletions(); len(late) != 1 || late[0].ReusedTokens != cachefunnel.KnownTokens(2048) {
		t.Fatalf("the sink received %+v, want the second completion's reuse", late)
	}
	requireReconciled(t, status, collector.snapshot())
}

// Close counts the completing attempt even when its dispatch note has not
// landed. That note must not be counted a second time as late evidence.
func TestDispatchNoteTrailingItsCompletionPastCloseIsCountedOnce(t *testing.T) {
	ledger, collector := newCollectedLedger()
	request := ledger.Enter()
	planned(request)
	request.NoteAttemptCompleted(selectedScoped, completedWith(cachefunnel.LookupMiss, cachefunnel.KnownTokens(0)))
	request.Close(false)
	request.NoteAttemptDispatched(selectedScoped)

	status := ledger.Snapshot()
	if status.Total.Attempts != 1 || status.Late.AttemptDispatches != 0 {
		t.Fatalf("attempts %d late attempt dispatches %d, want the one attempt counted once", status.Total.Attempts, status.Late.AttemptDispatches)
	}
	// A further note is a second frame the record did not count.
	request.NoteAttemptDispatched(coldScoped)
	if late := ledger.Snapshot().Late; late.AttemptDispatches != 1 {
		t.Fatalf("late = %+v, want the second frame counted as late", late)
	}
	requireReconciled(t, ledger.Snapshot(), collector.snapshot())
}

// The public form keeps every request and attempt count and no token sum.
func TestPublicStatusCarriesCountsOnly(t *testing.T) {
	ledger := cachefunnel.NewLedger(nil)
	request := ledger.Enter()
	attempt := cachefunnel.Attempt{Routing: cachefunnel.RoutingSelected, Scoped: true, Predicted: cachefunnel.KnownTokens(2048)}
	planned(request)
	request.NoteAttemptDispatched(attempt)
	request.NoteAttemptCompleted(attempt, hitOn(cachefunnel.TierSSD, 2048, 1024, 4096))
	request.Close(false)

	public := ledger.Snapshot().Public()
	want := cachefunnel.PublicTotals{Requests: 1, Planned: 1, Dispatched: 1, Attempts: 1, LookupOutcomeReported: 1, SSDHitRequests: 1}
	if public.Total != want {
		t.Fatalf("public total = %+v, want %+v", public.Total, want)
	}
	encoded, err := json.Marshal(public)
	if err != nil {
		t.Fatal(err)
	}
	for _, sum := range []string{"prompt_tokens", "repeated_prefix_tokens", "predicted_tokens", "reused_tokens",
		"prefill_saved_tokens", "provider_prompt_tokens"} {
		if strings.Contains(string(encoded), `"`+sum+`":`) {
			t.Fatalf("public status carries token sum %q: %s", sum, encoded)
		}
	}
}
