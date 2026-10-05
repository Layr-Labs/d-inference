package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// A retired request's optional receipt grace must not crowd out a new live
// request while an existing live request keeps its original authority.
func TestIndependentTerminalGracePressure(t *testing.T) {
	r, provider, _ := budgetLifecycleRegistry(t)
	// The fixture clock is frozen. A ledger's limit is fixed at construction,
	// so a first generation measures what one live and one retired attempt
	// retain; the control runs on a replacement whose ledger they fill.
	for _, id := range []string{"live", "dead"} {
		budgetLifecyclePrepare(t, r, provider, budgetLifecycleRequest(r, id))
	}
	limit := r.tracker().config.AttemptBudget.Bytes()
	r.setMaxBytes(limit)
	if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
		t.Fatal(err)
	}
	live := budgetLifecycleRequest(r, "live")
	liveOwner := budgetLifecyclePrepare(t, r, provider, live)
	retired := budgetLifecycleRequest(r, "dead")
	budgetLifecyclePrepare(t, r, provider, retired)
	tracker := r.tracker()
	if tracker.config.AttemptBudget.Bytes() != limit {
		t.Fatal("setup: the live and retired attempts do not fill the ledger")
	}
	r.MarkCacheAttemptTerminal(retired)
	next := budgetLifecycleRequest(r, "next")
	if err := r.PrepareCacheAttempt(next, provider); err != nil {
		t.Fatal(err)
	}
	if !next.CacheRoutingParticipates() {
		t.Errorf("new request lost cache scope while terminal grace retained budget (limit=%d)", limit)
	}
	var frame protocol.InferenceRequestMessage
	live.CacheAttemptSnapshot().ApplyTo(&frame)
	if frame.CacheReceiptNonce != liveOwner.CacheReceiptNonce || frame.CacheScope == "" {
		t.Fatal("live request authority was lost")
	}
	if _, _, err := budgetLifecycleInvariant(tracker.config); err != nil {
		t.Fatal(err)
	}
}
