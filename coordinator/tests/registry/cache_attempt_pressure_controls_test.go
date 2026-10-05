package registry_test

import (
	"fmt"
	"math/rand"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// A ledger's byte limit is fixed when its kernel is constructed, so these
// controls size it from the production charge of the records it must hold,
// the value the original controls read back from the tracker.
func pressureTestCharge(t *testing.T, nonce string, a indexKernelAttempt) uint64 {
	t.Helper()
	charge, ok := cachetracker.CacheAttemptCharge(nonce, a)
	if !ok {
		t.Fatal("charge")
	}
	return charge
}

// fullTerminalKernel fills a ledger exactly with 65 equal terminal records, one
// more than an admission under byte pressure may examine. It returns the
// tracker, the record and its charge.
func fullTerminalKernel(t *testing.T) (*receiptKernelFixture, indexKernelAttempt, uint64) {
	t.Helper()
	a := budgetTestAttempt()
	charge := pressureTestCharge(t, "n000", a)
	tr := budgetTestKernel(65 * charge)
	for i := 0; i < 65; i++ {
		nonce := fmt.Sprintf("n%03d", i)
		if !tr.StoreAttemptLocked(nonce, a) {
			t.Fatal("setup")
		}
		tr.MarkAttemptTerminal(nonce, a.CreatedAt.Add(time.Second))
	}
	return tr, a, charge
}

func TestCacheAttemptPressureRefusalDoesNotDiscardTerminalEvidence(t *testing.T) {
	for _, invalid := range []string{"oversized", "duplicate", "all-live"} {
		t.Run(invalid, func(t *testing.T) {
			a := budgetTestAttempt()
			// The incumbent alone fills the ledger.
			tr := budgetTestKernel(pressureTestCharge(t, "old", a))
			if !tr.StoreAttemptLocked("old", a) {
				t.Fatal("setup")
			}
			if invalid != "all-live" {
				tr.MarkAttemptTerminal("old", a.CreatedAt.Add(time.Second))
			}
			candidate := budgetTestAttempt()
			if invalid == "oversized" {
				candidate.Plan.CacheScope = strings.Repeat("x", 4096)
			}
			if invalid == "duplicate" {
				candidate.Plan.Boundaries[0] = candidate.Plan.Boundaries[1]
				candidate.ExpectedBoundaries = nil
			}
			accepted := tr.StoreAttemptLocked("new", candidate)
			_, old := tr.config.Attempts.Load("old")
			reclaimed := tr.AttemptLifecycle().GraceReclaimed
			if accepted || !old || reclaimed != 0 {
				t.Fatal("refusal discarded incumbent evidence")
			}
			if _, _, err := budgetLifecycleInvariant(tr.config); err != nil {
				t.Fatal(err)
			}
		})
	}
}

// The selector is reached through its only caller: a candidate that needs
// every retained byte asks it for all 65 records, and replacing the earliest
// terminal record by one twice its size asks it for one record other than the
// one being replaced.
func TestCacheAttemptPressureWorkBoundAndTerminalIdempotence(t *testing.T) {
	tr, a, charge := fullTerminalKernel(t)
	attempts, terminal := tr.config.Attempts, tr.config.TerminalOrder
	before := attempts.Lookup("n000").ExpiresAt
	tr.MarkAttemptTerminal("n000", a.CreatedAt.Add(2*time.Second))
	if !attempts.Lookup("n000").ExpiresAt.Equal(before) || terminal.Len() != 65 {
		t.Fatal("duplicate terminal extended grace or duplicated index")
	}
	everything := a
	everything.Plan.CacheScope += strings.Repeat("x", int(64*charge))
	if tr.StoreAttemptLocked("next", everything) || attempts.Len() != 65 || tr.AttemptLifecycle().GraceReclaimed != 0 {
		t.Fatal("reclamation exceeded 64-record work bound")
	}
	larger := a
	larger.Plan.CacheScope += strings.Repeat("x", int(charge))
	if !tr.StoreAttemptLocked("n000", larger) || attempts.Len() != 64 || tr.AttemptLifecycle().GraceReclaimed != 1 {
		t.Fatal("replacement nonce was not protected")
	}
	if _, _, err := budgetLifecycleInvariant(tr.config); err != nil {
		t.Fatal(err)
	}
}

func TestCacheAttemptPressureReclaimedLateReadyCannotRecreateHolder(t *testing.T) {
	r, p, cap := budgetLifecycleRegistry(t)
	plan := func() production.CachePlan { return r.plans.bind(exactTestPlan(exactTestAnchor(16, "c"))) }
	// The retired attempt's charge is read on a first generation; the control
	// runs on a replacement whose ledger holds it or the candidate, not both.
	measured, _ := checkpointPricingAttempt(t, r.Registry, p, cap, "dead", plan(), 1)
	limit := r.tracker().config.AttemptBudget.Bytes()
	r.ForgetCacheAttempt(measured)
	// Use a smaller valid candidate so pressure has one deterministic victim.
	a := budgetTestAttempt()
	charge := pressureTestCharge(t, "next", a)
	r.setMaxBytes(max(limit, charge))
	if err := r.ConfigureCacheRouting(generationTestConfig(production.CacheRoutingOn)); err != nil {
		t.Fatal(err)
	}
	retired, ready := checkpointPricingAttempt(t, r.Registry, p, cap, "dead", plan(), 1)
	tr := r.tracker()
	r.MarkCacheAttemptTerminal(retired)
	inserted := tr.core.StoreAttemptLocked("next", a)
	reclaimed := tr.core.AttemptLifecycle().GraceReclaimed
	if !inserted || reclaimed != 1 {
		t.Fatal("terminal evidence was not reclaimed")
	}
	if r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatal("reclaimed nonce recreated cache authority")
	}
	if _, _, err := budgetLifecycleInvariant(tr.config); err != nil {
		t.Fatal(err)
	}
}

func TestCacheAttemptPressureInsertionHonorsWorkBound(t *testing.T) {
	tr, a, charge := fullTerminalKernel(t)
	a.Plan.CacheScope += strings.Repeat("x", int(64*charge))
	stored := tr.StoreAttemptLocked("next", a)
	lifecycle := tr.AttemptLifecycle()
	if stored || tr.config.Attempts.Len() != 65 || lifecycle.GraceReclaimed != 0 || lifecycle.BudgetRefused != 1 {
		t.Fatal("bounded refusal did not preserve all evidence and count refusal")
	}
}

func TestCacheAttemptPressureTerminalReplacementReordersBothHeaps(t *testing.T) {
	tr := newReceiptKernelFixture(time.Minute, 100)
	a := budgetTestAttempt()
	for _, nonce := range []string{"first", "later"} {
		if !tr.StoreAttemptLocked(nonce, a) {
			t.Fatal("setup")
		}
		tr.MarkAttemptTerminal(nonce, a.CreatedAt.Add(time.Second))
	}
	replacement := tr.config.Attempts.Lookup("first")
	replacement.Plan.CacheScope += "larger"
	replacement.ExpiresAt = replacement.ExpiresAt.Add(time.Minute)
	if !tr.StoreAttemptLocked("first", replacement) {
		t.Fatal("replacement refused")
	}
	if head := tr.config.TerminalOrder.Head(); head == nil || head.Key().Nonce != "later" {
		t.Fatal("terminal heap not reordered")
	}
	if _, _, err := budgetLifecycleInvariant(tr.config); err != nil {
		t.Fatal(err)
	}
	tr.RemoveAttemptLocked("first")
	tr.RemoveAttemptLocked("later")
	if _, _, err := budgetLifecycleInvariant(tr.config); err != nil {
		t.Fatal(err)
	}
}

// The victim selector peeks through Order.Earliest: it must yield the earliest
// entries in expiry order, stop at its limit and move nothing.
func TestCacheAttemptPressureOrderPeeksEarliestWithoutMoving(t *testing.T) {
	order := cacheindex.NewAttemptOrder()
	base := time.Unix(1_800_000_000, 0)
	for index, offset := range rand.New(rand.NewSource(1)).Perm(200) {
		nonce := fmt.Sprintf("n%03d", index)
		order.Track(nonce, cacheindex.AttemptRef{Nonce: nonce}, base.Add(time.Duration(offset)*time.Second))
	}
	before := budgetOrderHeap(order)
	var peeked []time.Time
	for entry := range order.Earliest(64) {
		peeked = append(peeked, entry.ExpiresAt())
	}
	if len(peeked) != 64 {
		t.Fatalf("peeked %d entries, want the limit of 64", len(peeked))
	}
	for index, expiresAt := range peeked {
		if !expiresAt.Equal(base.Add(time.Duration(index) * time.Second)) {
			t.Fatalf("peeked entry %d expires at %s, want base+%ds", index, expiresAt, index)
		}
	}
	if !slices.Equal(before, budgetOrderHeap(order)) {
		t.Fatal("peeking moved heap entries")
	}
}
