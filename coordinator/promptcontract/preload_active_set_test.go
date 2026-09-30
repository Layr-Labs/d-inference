package promptcontract

import (
	"fmt"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
	"unsafe"
)

func activeSetContract(index int) string { return fmt.Sprintf("%064x", index) }

func activeSetInput(count, capacity int) PreloadSelectionInput {
	input := PreloadSelectionInput{CatalogGeneration: 1, ChildGeneration: 1, Capacity: capacity}
	for i := 1; i <= count; i++ {
		input.Verified = append(input.Verified, VerifiedPreloadArtifact{
			CatalogGeneration: 1, ModelID: fmt.Sprintf("model-%03d", i),
			ModelAggregateSHA256: activeSetContract(1000 + i), PromptContractID: activeSetContract(i),
		})
	}
	input.Admissible = slices.Clone(input.Verified)
	return input
}

func activeSetReconcile(t *testing.T, policy *preloadActiveSet, now time.Duration, input PreloadSelectionInput) PreloadSelectionSnapshot {
	t.Helper()
	snapshot, err := policy.reconcile(now, input)
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func activeSetDemand(t *testing.T, policy *preloadActiveSet, now time.Duration, identities ...PreloadDemandIdentity) {
	t.Helper()
	for _, identity := range identities {
		if !policy.noteDemand(now, identity) {
			t.Fatalf("current eligible tuple refused: %s", identity.ModelID)
		}
	}
}

func activeSetLoadAll(t *testing.T, policy *preloadActiveSet, now time.Duration) preloadSelectionLease {
	t.Helper()
	lease, ok := policy.beginAttempt(now)
	if !ok || !policy.completeAttempt(now, lease, lease.key.Desired, 0) {
		t.Fatal("pure acknowledged-success transition refused")
	}
	return lease
}

func activeSetWant(t *testing.T, policy *preloadActiveSet, indices ...int) {
	t.Helper()
	var want []string
	for _, index := range indices {
		want = append(want, activeSetContract(index))
	}
	slices.Sort(want)
	if got := policy.snapshot().Desired; !slices.Equal(got, want) {
		t.Fatalf("desired=%v want=%v", got, want)
	}
}

func TestPreloadActiveSetFullVerifiedSetUsesConfiguredCapacity(t *testing.T) {
	for _, capacity := range []int{1, 3, 8, 128, 256} {
		t.Run(fmt.Sprint(capacity), func(t *testing.T) {
			count := min(capacity, 9)
			input := activeSetInput(count, capacity)
			policy := newPreloadActiveSet()
			snapshot := activeSetReconcile(t, policy, 0, input)
			if len(snapshot.Desired) != count || snapshot.Capacity != capacity {
				t.Fatal("full-set path introduced a hidden eight-contract limit")
			}
			activeSetLoadAll(t, policy, 0)
			if len(policy.successes()) != count {
				t.Fatal("success membership differs from acknowledgement")
			}
		})
	}
	input := activeSetInput(9, 8)
	input.Verified[8].PromptContractID = input.Verified[0].PromptContractID
	input.Admissible = slices.Clone(input.Verified)
	policy := newPreloadActiveSet()
	if got := activeSetReconcile(t, policy, 0, input); len(got.Verified) != 9 || len(got.Desired) != 8 {
		t.Fatal("nine tuples sharing eight contracts incorrectly overflowed")
	}
}

func TestPreloadActiveSetOverflowDoesNotChooseCatalogPrefix(t *testing.T) {
	input := activeSetInput(9, 8)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetWant(t, policy)
	if _, ok := policy.beginAttempt(0); ok || policy.reason() != "capacity_deferred" {
		t.Fatal("empty overflow issued preload or lost bounded reason")
	}
	input.Published = &PreloadPublishedArtifacts{1, 1, []VerifiedPreloadArtifact{input.Verified[8], input.Verified[4]}}
	seeded := newPreloadActiveSet()
	activeSetReconcile(t, seeded, 0, input)
	activeSetWant(t, seeded, 5, 9)
	if len(seeded.successes()) != 0 {
		t.Fatal("old published identities became new-key successes without acknowledgement")
	}
	activeSetLoadAll(t, seeded, 0)
	input.Published.ChildGeneration = 2
	stale := newPreloadActiveSet()
	activeSetReconcile(t, stale, 0, input)
	activeSetWant(t, stale)
}

func TestPreloadActiveSetWaitAgePrecedesAvailabilityAndContractTieBreak(t *testing.T) {
	input := activeSetInput(3, 1)
	input.PubliclyAvailable = []string{input.Verified[0].ModelID}
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, time.Second, input.Verified[2])
	activeSetDemand(t, policy, 2*time.Second, input.Verified[0])
	activeSetReconcile(t, policy, 2*time.Second, input)
	activeSetWant(t, policy, 3) // Older private/unavailable demand remains eligible.
	tied := newPreloadActiveSet()
	activeSetReconcile(t, tied, 0, input)
	activeSetDemand(t, tied, 0, input.Verified[2], input.Verified[0], input.Verified[1])
	activeSetReconcile(t, tied, 0, input)
	activeSetWant(t, tied, 1)
	input.PubliclyAvailable = nil
	bytesOnly := newPreloadActiveSet()
	activeSetReconcile(t, bytesOnly, 0, input)
	activeSetDemand(t, bytesOnly, 0, input.Verified[2], input.Verified[1])
	activeSetReconcile(t, bytesOnly, 0, input)
	activeSetWant(t, bytesOnly, 2)
}

func TestPreloadActiveSetObservationsAndAvailabilityDoNotReload(t *testing.T) {
	input := activeSetInput(3, 1)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0])
	key := activeSetReconcile(t, policy, 0, input)
	activeSetLoadAll(t, policy, 0)
	for tick := time.Second; tick <= 10*time.Second; tick += time.Second {
		activeSetDemand(t, policy, tick, input.Verified[0])
		input.PubliclyAvailable = []string{input.Verified[1].ModelID}
		if next := activeSetReconcile(t, policy, tick, input); !next.equal(key) {
			t.Fatal("repeated demand or advisory visibility changed the key")
		}
		if _, ok := policy.beginAttempt(tick); ok {
			t.Fatal("unchanged fully acknowledged set reloaded")
		}
	}
	if policy.members[activeSetContract(1)].admittedAt != 0 {
		t.Fatal("hits refreshed residence age")
	}
}

func TestPreloadActiveSetResidenceAndReplacementIntervals(t *testing.T) {
	input := activeSetInput(4, 2)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified...)
	activeSetReconcile(t, policy, 0, input)
	activeSetLoadAll(t, policy, time.Second)
	activeSetReconcile(t, policy, 30*time.Second, input)
	activeSetWant(t, policy, 1, 2)
	activeSetReconcile(t, policy, 31*time.Second, input)
	activeSetWant(t, policy, 2, 3)
	activeSetLoadAll(t, policy, 31*time.Second)
	if policy.members[activeSetContract(2)].admittedAt != time.Second {
		t.Fatal("unchanged successful incumbent gained a new admission age")
	}
	activeSetReconcile(t, policy, 60*time.Second, input)
	activeSetWant(t, policy, 2, 3)
	activeSetReconcile(t, policy, 61*time.Second, input)
	activeSetWant(t, policy, 3, 4)
}

func TestPreloadActiveSetContinuousDemandRotatesTenAnd128Fairly(t *testing.T) {
	for _, count := range []int{10, 128} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			input := activeSetInput(count, 8)
			policy := newPreloadActiveSet()
			activeSetReconcile(t, policy, 0, input)
			activeSetDemand(t, policy, 0, input.Verified...)
			activeSetReconcile(t, policy, 0, input)
			activeSetLoadAll(t, policy, 0)
			seen := make(map[string]bool)
			for _, id := range policy.successes() {
				seen[id] = true
			}
			for turn := 1; turn <= count-8; turn++ {
				now := time.Duration(turn) * preloadReplacementInterval
				previous := policy.snapshot()
				activeSetDemand(t, policy, now, input.Verified...)
				for repeat := 0; repeat < 32; repeat++ {
					activeSetDemand(t, policy, now, input.Verified[0])
				}
				next := activeSetReconcile(t, policy, now, input)
				added := 0
				for _, id := range next.Desired {
					if !slices.Contains(previous.Desired, id) {
						added++
					}
				}
				if added != 1 || next.SelectionGeneration != previous.SelectionGeneration+1 {
					t.Fatal("rotation was not exactly one effective replacement")
				}
				activeSetLoadAll(t, policy, now)
				for _, id := range policy.successes() {
					seen[id] = true
				}
				if len(policy.demand) > 128 || len(policy.members) > 8 || len(policy.retryAt) > 128 {
					t.Fatal("bounded state exceeded")
				}
			}
			if len(seen) != count {
				t.Fatalf("only %d/%d continuously demanded contracts acknowledged", len(seen), count)
			}
		})
	}
}

func TestPreloadActiveSetExpiryRestartsOnlyExpiredWaitAge(t *testing.T) {
	input := activeSetInput(3, 1)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0])
	activeSetReconcile(t, policy, 0, input)
	activeSetLoadAll(t, policy, 0)
	activeSetDemand(t, policy, time.Second, input.Verified[1])
	activeSetDemand(t, policy, 299*time.Second, input.Verified[2])
	activeSetDemand(t, policy, 301*time.Second, input.Verified[1])
	if policy.demand[input.Verified[1]].waitingSince != 301*time.Second {
		t.Fatal("expired first demand retained old FIFO priority")
	}
	activeSetReconcile(t, policy, 301*time.Second, input)
	activeSetWant(t, policy, 3)
}

func TestPreloadActiveSetFailedWaiterMovesBehindOthersAndKeepsBackoff(t *testing.T) {
	input := activeSetInput(3, 1)
	input.PubliclyAvailable = []string{input.Verified[0].ModelID}
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified...)
	activeSetReconcile(t, policy, 0, input)
	lease, ok := policy.beginAttempt(0)
	if !ok || !policy.completeAttempt(0, lease, nil, time.Minute) || len(policy.successes()) != 0 {
		t.Fatal("all-failed lease did not remain closed")
	}
	if _, ok := policy.beginAttempt(time.Second); ok {
		t.Fatal("unchanged failed batch ignored existing backoff")
	}
	activeSetReconcile(t, policy, time.Second, input)
	activeSetWant(t, policy, 2)
	activeSetLoadAll(t, policy, time.Second)
	activeSetReconcile(t, policy, 31*time.Second, input)
	activeSetWant(t, policy, 3)
	activeSetLoadAll(t, policy, 31*time.Second)
	activeSetReconcile(t, policy, 61*time.Second, input)
	activeSetWant(t, policy, 1)
	activeSetLoadAll(t, policy, 61*time.Second)
}

func TestPreloadActiveSetPartialSuccessHasNoFailedMembership(t *testing.T) {
	input := activeSetInput(3, 2)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified...)
	activeSetReconcile(t, policy, 0, input)
	lease, _ := policy.beginAttempt(0)
	if !policy.completeAttempt(0, lease, []string{activeSetContract(2)}, time.Minute) {
		t.Fatal("validated partial acknowledgement refused")
	}
	if !slices.Equal(policy.successes(), []string{activeSetContract(2)}) || policy.reason() != "preload_failed" {
		t.Fatal("partial S or bounded failure reason was lost")
	}
	activeSetReconcile(t, policy, 0, input)
	activeSetWant(t, policy, 2, 3)
	activeSetLoadAll(t, policy, 0)
	if slices.Contains(policy.successes(), activeSetContract(1)) {
		t.Fatal("failed member reappeared in acknowledged set")
	}
}

func TestPreloadActiveSetTupleIdentityAndContractDeduplication(t *testing.T) {
	input := activeSetInput(3, 1)
	input.Verified[1].PromptContractID = input.Verified[0].PromptContractID
	input.Admissible = slices.Clone(input.Verified)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0], input.Verified[1])
	activeSetReconcile(t, policy, 0, input)
	activeSetWant(t, policy, 1)
	for _, mutation := range []func(*PreloadDemandIdentity){
		func(v *PreloadDemandIdentity) { v.CatalogGeneration++ },
		func(v *PreloadDemandIdentity) { v.ModelID = "caller-alias" },
		func(v *PreloadDemandIdentity) { v.ModelAggregateSHA256 = activeSetContract(9000) },
		func(v *PreloadDemandIdentity) { v.PromptContractID = activeSetContract(9001) },
	} {
		identity := input.Verified[0]
		mutation(&identity)
		if policy.noteDemand(time.Second, identity) {
			t.Fatal("non-current exact tuple created interest")
		}
	}
	if len(policy.demand) != 2 || policy.lastTick != 0 {
		t.Fatal("invalid demand mutated retained state")
	}
	wantFields := []string{"CatalogGeneration", "ModelID", "ModelAggregateSHA256", "PromptContractID"}
	typ := reflect.TypeOf(PreloadDemandIdentity{})
	if typ.NumField() != len(wantFields) {
		t.Fatal("demand identity retained unexpected request/auth fields")
	}
	for i, name := range wantFields {
		if typ.Field(i).Name != name {
			t.Fatal("demand identity field contract changed")
		}
	}
}

func TestPreloadActiveSetRevocationFencesInflightWithoutOverlap(t *testing.T) {
	input := activeSetInput(3, 1)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0])
	activeSetReconcile(t, policy, 0, input)
	old, _ := policy.beginAttempt(0)
	input.Admissible = slices.Clone(input.Verified[1:])
	activeSetReconcile(t, policy, time.Second, input)
	activeSetWant(t, policy)
	if _, ok := policy.beginAttempt(time.Second); ok {
		t.Fatal("safety invalidation manufactured an overlapping lease")
	}
	if policy.completeAttempt(time.Second, old, old.key.Desired, 0) || len(policy.successes()) != 0 {
		t.Fatal("revoked completion restored old membership")
	}
	activeSetDemand(t, policy, time.Second, input.Verified[1])
	activeSetReconcile(t, policy, time.Second, input)
	current, ok := policy.beginAttempt(time.Second)
	if !ok || policy.completeAttempt(time.Second, old, old.key.Desired, 0) {
		t.Fatal("old callback consumed a replacement operation")
	}
	if !policy.completeAttempt(time.Second, current, current.key.Desired, 0) {
		t.Fatal("replacement operation was lost")
	}
}

func TestPreloadActiveSetSameGenerationVerifiedGrowthFencesCompletion(t *testing.T) {
	input := activeSetInput(2, 1)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0])
	before := activeSetReconcile(t, policy, 0, input)
	lease, _ := policy.beginAttempt(0)
	input = activeSetInput(3, 1)
	after := activeSetReconcile(t, policy, time.Second, input)
	if after.SelectionGeneration != before.SelectionGeneration || !slices.Equal(after.Desired, before.Desired) {
		t.Fatal("unchanged D spuriously changed selection generation")
	}
	if after.equal(before) || policy.completeAttempt(time.Second, lease, lease.key.Desired, 0) {
		t.Fatal("same-generation V growth accepted stale completion")
	}
	activeSetLoadAll(t, policy, time.Second)
}

func TestPreloadActiveSetWithinCapacityDoesNotPruneVerificationForAllowlist(t *testing.T) {
	input := activeSetInput(2, 2)
	policy := newPreloadActiveSet()
	first := activeSetReconcile(t, policy, 0, input)
	lease, _ := policy.beginAttempt(0)
	input.Admissible = nil // Caller resolves explicitly empty allowlist to no eligible identities.
	next := activeSetReconcile(t, policy, time.Second, input)
	activeSetWant(t, policy, 1, 2)
	if next.SelectionGeneration != first.SelectionGeneration || next.equal(first) {
		t.Fatal("admissibility fence changed D or failed to change K")
	}
	if policy.noteDemand(time.Second, input.Verified[0]) || policy.completeAttempt(time.Second, lease, lease.key.Desired, 0) {
		t.Fatal("revoked routing eligibility retained demand or stale publication")
	}
	activeSetLoadAll(t, policy, time.Second)
	// These successes are tokenizer facts only; they cannot authorize routing.
	if len(policy.successes()) != 2 || len(policy.snapshot().Verified) != 2 {
		t.Fatal("full verified catalog was pruned")
	}
}

func TestPreloadActiveSetChildRestartRetriesExactSelectedSet(t *testing.T) {
	input := activeSetInput(2, 1)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0])
	before := activeSetReconcile(t, policy, 0, input)
	activeSetLoadAll(t, policy, 0)
	input.ChildGeneration++
	after := activeSetReconcile(t, policy, 6*time.Minute, input)
	activeSetWant(t, policy, 1)
	if len(policy.successes()) != 0 || after.SelectionGeneration != before.SelectionGeneration || after.equal(before) {
		t.Fatal("child restart retained S or changed otherwise identical D")
	}
	activeSetLoadAll(t, policy, 6*time.Minute)
	if policy.members[activeSetContract(1)].admittedAt != 6*time.Minute {
		t.Fatal("new child inherited old admission age without new success")
	}
}

func TestPreloadActiveSetCatalogReplacementAndCapacityShrinkAreImmediate(t *testing.T) {
	input := activeSetInput(4, 3)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified...)
	activeSetReconcile(t, policy, 0, input)
	activeSetLoadAll(t, policy, 0)
	input.Capacity = 1
	activeSetReconcile(t, policy, time.Second, input)
	if len(policy.snapshot().Desired) != 1 || len(policy.successes()) != 0 {
		t.Fatal("capacity safety closure waited for ordinary minimum residence")
	}
	input.CatalogGeneration++
	for i := range input.Verified {
		input.Verified[i].CatalogGeneration = input.CatalogGeneration
	}
	input.Admissible = slices.Clone(input.Verified)
	activeSetReconcile(t, policy, 2*time.Second, input)
	activeSetWant(t, policy)
	if len(policy.demand) != 0 {
		t.Fatal("new catalog inherited old-generation interest")
	}
}

func TestPreloadActiveSetInvalidInputsCloseAndRemainBounded(t *testing.T) {
	for _, mutate := range []func(*PreloadSelectionInput){
		func(v *PreloadSelectionInput) { *v = activeSetInput(129, 8) },
		func(v *PreloadSelectionInput) { v.Verified = append(v.Verified, v.Verified[0]) },
		func(v *PreloadSelectionInput) { v.Verified[0].ModelID = strings.Repeat("m", 513) },
		func(v *PreloadSelectionInput) { v.Verified[0].ModelAggregateSHA256 = strings.Repeat("A", 64) },
		func(v *PreloadSelectionInput) { v.Verified[0].CatalogGeneration++ },
		func(v *PreloadSelectionInput) { v.Admissible[0].ModelID = "not-current" },
		func(v *PreloadSelectionInput) { v.Admissible = append(v.Admissible, v.Admissible[0]) },
		func(v *PreloadSelectionInput) { v.Capacity = 0 },
		func(v *PreloadSelectionInput) { v.CatalogGeneration = 0 },
		func(v *PreloadSelectionInput) { v.PubliclyAvailable = []string{"not-current"} },
	} {
		input := activeSetInput(2, 2)
		policy := newPreloadActiveSet()
		activeSetReconcile(t, policy, 0, input)
		activeSetLoadAll(t, policy, 0)
		mutate(&input)
		if _, err := policy.reconcile(time.Second, input); err == nil {
			t.Fatal("malformed/over-bound input accepted")
		}
		activeSetWant(t, policy)
		if len(policy.successes()) != 0 || len(policy.demand) != 0 {
			t.Fatal("invalid input retained participation")
		}
	}
}

func TestPreloadActiveSetDetachesIdentityAndReturnedSnapshots(t *testing.T) {
	input := activeSetInput(2, 1)
	backing := strings.Repeat("x", 1<<20) + input.Verified[0].ModelID
	input.Verified[0].ModelID = backing[len(backing)-len(input.Verified[0].ModelID):]
	input.Admissible = slices.Clone(input.Verified)
	policy := newPreloadActiveSet()
	key := activeSetReconcile(t, policy, 0, input)
	if unsafe.StringData(key.Verified[0].ModelID) == unsafe.StringData(input.Verified[0].ModelID) {
		t.Fatal("retained caller's large model-ID backing allocation")
	}
	activeSetDemand(t, policy, 0, input.Verified[0])
	for identity := range policy.demand {
		if unsafe.StringData(identity.ModelID) == unsafe.StringData(input.Verified[0].ModelID) {
			t.Fatal("demand insertion reintroduced caller string backing")
		}
	}
	activeSetReconcile(t, policy, 0, input)
	key = policy.snapshot()
	key.Verified[0].ModelID, key.Admissible[0].ModelID, key.Desired[0] = "changed", "changed", "changed"
	input.Verified[0].PromptContractID = activeSetContract(999)
	activeSetWant(t, policy, 1)
	if policy.snapshot().Verified[0].ModelID == "changed" {
		t.Fatal("caller mutated owned input or returned key")
	}
}

func TestPreloadActiveSetLeaseIsDetachedAndAcknowledgementIsExactlyOnce(t *testing.T) {
	input := activeSetInput(2, 2)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	lease, _ := policy.beginAttempt(0)
	mutated := preloadSelectionLease{lease.operation, policy.snapshot()}
	mutated.key.Desired[0] = activeSetContract(99)
	if policy.completeAttempt(0, mutated, nil, time.Second) {
		t.Fatal("mutated lease accepted")
	}
	if !policy.completeAttempt(0, lease, lease.key.Desired, 0) || policy.completeAttempt(0, lease, lease.key.Desired, 0) {
		t.Fatal("valid lease was lost or completed twice")
	}
	for _, invalid := range [][]string{{activeSetContract(1), activeSetContract(1)}, {activeSetContract(99)}, make([]string, 129)} {
		candidate := newPreloadActiveSet()
		activeSetReconcile(t, candidate, 0, input)
		attempt, _ := candidate.beginAttempt(0)
		if candidate.completeAttempt(0, attempt, invalid, time.Second) || len(candidate.successes()) != 0 {
			t.Fatal("invalid success report published members")
		}
	}
}

func TestPreloadActiveSetMonotonicClockAndGenerationExhaustion(t *testing.T) {
	input := activeSetInput(2, 1)
	policy := newPreloadActiveSet()
	activeSetReconcile(t, policy, time.Second, input)
	if policy.noteDemand(0, input.Verified[0]) {
		t.Fatal("backward demand clock accepted")
	}
	if _, err := policy.reconcile(0, input); err == nil || policy.valid {
		t.Fatal("backward authoritative clock did not close selection")
	}
	exhausted := newPreloadActiveSet()
	activeSetReconcile(t, exhausted, 0, input)
	exhausted.key.SelectionGeneration = ^uint64(0)
	activeSetDemand(t, exhausted, 0, input.Verified[0])
	if _, err := exhausted.reconcile(0, input); err == nil || !exhausted.closed || len(exhausted.snapshot().Desired) != 0 {
		t.Fatal("selection generation wrapped or remained usable")
	}
	operation := newPreloadActiveSet()
	activeSetReconcile(t, operation, 0, activeSetInput(1, 1))
	operation.operation = ^uint64(0)
	if _, ok := operation.beginAttempt(0); ok || !operation.closed {
		t.Fatal("operation generation wrapped")
	}
}
