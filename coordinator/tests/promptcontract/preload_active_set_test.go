package promptcontract_test

import (
	"fmt"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
	"unsafe"
	"weak"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/preload"
)

func activeSetContract(index int) string { return fmt.Sprintf("%064x", index) }

func activeSetInput(count, capacity int) preload.PreloadSelectionInput {
	input := preload.PreloadSelectionInput{CatalogGeneration: 1, ChildGeneration: 1, Capacity: capacity}
	for i := 1; i <= count; i++ {
		input.Verified = append(input.Verified, preload.VerifiedPreloadArtifact{
			CatalogGeneration: 1, ModelID: fmt.Sprintf("model-%03d", i),
			ModelAggregateSHA256: activeSetContract(1000 + i), PromptContractID: activeSetContract(i),
		})
	}
	input.Admissible = slices.Clone(input.Verified)
	return input
}

func activeSetReconcile(t *testing.T, policy *preload.PreloadActiveSet, now time.Duration, input preload.PreloadSelectionInput) preload.PreloadSelectionSnapshot {
	t.Helper()
	snapshot, err := policy.Reconcile(now, input)
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func activeSetDemand(t *testing.T, policy *preload.PreloadActiveSet, now time.Duration, identities ...preload.PreloadDemandIdentity) {
	t.Helper()
	for _, identity := range identities {
		if !policy.NoteDemand(now, identity) {
			t.Fatalf("current eligible tuple refused: %s", identity.ModelID)
		}
	}
}

func activeSetLoadAll(t *testing.T, policy *preload.PreloadActiveSet, now time.Duration) preload.PreloadSelectionLease {
	t.Helper()
	lease, ok := policy.BeginAttempt(now)
	if !ok || !policy.CompleteAttempt(now, lease, lease.Key.Desired, 0) {
		t.Fatal("pure acknowledged-success transition refused")
	}
	return lease
}

func activeSetContracts(indices ...int) []string {
	var contracts []string
	for _, index := range indices {
		contracts = append(contracts, activeSetContract(index))
	}
	slices.Sort(contracts)
	return contracts
}

func activeSetWant(t *testing.T, policy *preload.PreloadActiveSet, indices ...int) {
	t.Helper()
	want := activeSetContracts(indices...)
	if got := policy.Snapshot().Desired; !slices.Equal(got, want) {
		t.Fatalf("desired=%v want=%v", got, want)
	}
}

func TestPreloadActiveSetFullVerifiedSetUsesConfiguredCapacity(t *testing.T) {
	for _, capacity := range []int{1, 3, 8, 128, 256} {
		t.Run(fmt.Sprint(capacity), func(t *testing.T) {
			count := min(capacity, 9)
			input := activeSetInput(count, capacity)
			policy := preload.NewPreloadActiveSet()
			snapshot := activeSetReconcile(t, policy, 0, input)
			if len(snapshot.Desired) != count || snapshot.Capacity != capacity {
				t.Fatal("full-set path introduced a hidden eight-contract limit")
			}
			activeSetLoadAll(t, policy, 0)
			if len(policy.Successes()) != count {
				t.Fatal("success membership differs from acknowledgement")
			}
		})
	}
	input := activeSetInput(9, 8)
	input.Verified[8].PromptContractID = input.Verified[0].PromptContractID
	input.Admissible = slices.Clone(input.Verified)
	policy := preload.NewPreloadActiveSet()
	if got := activeSetReconcile(t, policy, 0, input); len(got.Verified) != 9 || len(got.Desired) != 8 {
		t.Fatal("nine tuples sharing eight contracts incorrectly overflowed")
	}
}

func TestPreloadActiveSetOverflowDoesNotChooseCatalogPrefix(t *testing.T) {
	input := activeSetInput(9, 8)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetWant(t, policy)
	if _, ok := policy.BeginAttempt(0); ok || policy.Reason() != "capacity_deferred" {
		t.Fatal("empty overflow issued preload or lost bounded reason")
	}
	input.Published = &preload.PreloadPublishedArtifacts{CatalogGeneration: 1, ChildGeneration: 1,
		Successful: []preload.VerifiedPreloadArtifact{input.Verified[8], input.Verified[4]}}
	seeded := preload.NewPreloadActiveSet()
	activeSetReconcile(t, seeded, 0, input)
	activeSetWant(t, seeded, 5, 9)
	if len(seeded.Successes()) != 0 {
		t.Fatal("old published identities became new-key successes without acknowledgement")
	}
	activeSetLoadAll(t, seeded, 0)
	input.Published.ChildGeneration = 2
	stale := preload.NewPreloadActiveSet()
	activeSetReconcile(t, stale, 0, input)
	activeSetWant(t, stale)
}

func TestPreloadActiveSetWaitAgePrecedesAvailabilityAndContractTieBreak(t *testing.T) {
	input := activeSetInput(3, 1)
	input.PubliclyAvailable = []string{input.Verified[0].ModelID}
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, time.Second, input.Verified[2])
	activeSetDemand(t, policy, 2*time.Second, input.Verified[0])
	activeSetReconcile(t, policy, 2*time.Second, input)
	activeSetWant(t, policy, 3) // Older private/unavailable demand remains eligible.
	tied := preload.NewPreloadActiveSet()
	activeSetReconcile(t, tied, 0, input)
	activeSetDemand(t, tied, 0, input.Verified[2], input.Verified[0], input.Verified[1])
	activeSetReconcile(t, tied, 0, input)
	activeSetWant(t, tied, 1)
	input.PubliclyAvailable = nil
	bytesOnly := preload.NewPreloadActiveSet()
	activeSetReconcile(t, bytesOnly, 0, input)
	activeSetDemand(t, bytesOnly, 0, input.Verified[2], input.Verified[1])
	activeSetReconcile(t, bytesOnly, 0, input)
	activeSetWant(t, bytesOnly, 2)
}

func TestPreloadActiveSetObservationsAndAvailabilityDoNotReload(t *testing.T) {
	input := activeSetInput(3, 1)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0])
	key := activeSetReconcile(t, policy, 0, input)
	activeSetLoadAll(t, policy, 0)
	for tick := time.Second; tick <= 10*time.Second; tick += time.Second {
		activeSetDemand(t, policy, tick, input.Verified[0])
		input.PubliclyAvailable = []string{input.Verified[1].ModelID}
		if next := activeSetReconcile(t, policy, tick, input); !next.Equal(key) {
			t.Fatal("repeated demand or advisory visibility changed the key")
		}
		if _, ok := policy.BeginAttempt(tick); ok {
			t.Fatal("unchanged fully acknowledged set reloaded")
		}
	}
	// Residence age shows only in replacement. The incumbent was admitted at
	// zero, so a waiter takes its slot at exactly the thirty-second minimum
	// residence; an age refreshed by any of the hits would still protect it.
	activeSetDemand(t, policy, 10*time.Second, input.Verified[1])
	activeSetReconcile(t, policy, 30*time.Second, input)
	if !slices.Equal(policy.Snapshot().Desired, activeSetContracts(2)) {
		t.Fatal("hits refreshed residence age")
	}
}

func TestPreloadActiveSetResidenceAndReplacementIntervals(t *testing.T) {
	input := activeSetInput(4, 2)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified...)
	activeSetReconcile(t, policy, 0, input)
	activeSetLoadAll(t, policy, time.Second)
	activeSetReconcile(t, policy, 30*time.Second, input)
	activeSetWant(t, policy, 1, 2)
	activeSetReconcile(t, policy, 31*time.Second, input)
	activeSetWant(t, policy, 2, 3)
	activeSetLoadAll(t, policy, 31*time.Second)
	activeSetReconcile(t, policy, 60*time.Second, input)
	activeSetWant(t, policy, 2, 3)
	activeSetReconcile(t, policy, 61*time.Second, input)
	activeSetWant(t, policy, 3, 4)
	// An incumbent's admission age shows only in which member the next
	// replacement evicts, and equal ages evict the lower contract. Rotate until
	// the surviving incumbent is the higher contract: it is evicted only if
	// reloading it beside each newcomer left its own, older age in place.
	activeSetLoadAll(t, policy, 61*time.Second)
	activeSetReconcile(t, policy, 91*time.Second, input)
	activeSetWant(t, policy, 1, 4)
	activeSetLoadAll(t, policy, 91*time.Second)
	activeSetReconcile(t, policy, 121*time.Second, input)
	if !slices.Equal(policy.Snapshot().Desired, activeSetContracts(1, 2)) {
		t.Fatal("unchanged successful incumbent gained a new admission age")
	}
}

func TestPreloadActiveSetContinuousDemandRotatesTenAnd128Fairly(t *testing.T) {
	for _, count := range []int{10, 128} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			input := activeSetInput(count, 8)
			policy := preload.NewPreloadActiveSet()
			activeSetReconcile(t, policy, 0, input)
			activeSetDemand(t, policy, 0, input.Verified...)
			activeSetReconcile(t, policy, 0, input)
			activeSetLoadAll(t, policy, 0)
			seen := make(map[string]bool)
			for _, id := range policy.Successes() {
				seen[id] = true
			}
			for turn := 1; turn <= count-8; turn++ {
				now := time.Duration(turn) * preload.PreloadReplacementInterval
				previous := policy.Snapshot()
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
				for _, id := range policy.Successes() {
					seen[id] = true
				}
				// Every collection a caller can read stays within its bound; the
				// sizes of the demand and retry bookkeeping are not readable.
				bounded := policy.Snapshot()
				if len(bounded.Verified) > 128 || len(bounded.Admissible) > 128 ||
					len(bounded.Desired) > 8 || len(policy.Successes()) > 8 {
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
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0])
	activeSetReconcile(t, policy, 0, input)
	activeSetLoadAll(t, policy, 0)
	activeSetDemand(t, policy, time.Second, input.Verified[1])
	activeSetDemand(t, policy, 299*time.Second, input.Verified[2])
	activeSetDemand(t, policy, 301*time.Second, input.Verified[1])
	activeSetReconcile(t, policy, 301*time.Second, input)
	// The second contract's wait age shows in who takes the slot: restarted at
	// 301 seconds it queues behind the third, kept at one second it wins.
	if slices.Equal(policy.Snapshot().Desired, activeSetContracts(2)) {
		t.Fatal("expired first demand retained old FIFO priority")
	}
	activeSetWant(t, policy, 3)
}

func TestPreloadActiveSetFailedWaiterMovesBehindOthersAndKeepsBackoff(t *testing.T) {
	input := activeSetInput(3, 1)
	input.PubliclyAvailable = []string{input.Verified[0].ModelID}
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified...)
	activeSetReconcile(t, policy, 0, input)
	lease, ok := policy.BeginAttempt(0)
	if !ok || !policy.CompleteAttempt(0, lease, nil, time.Minute) || len(policy.Successes()) != 0 {
		t.Fatal("all-failed lease did not remain closed")
	}
	if _, ok := policy.BeginAttempt(time.Second); ok {
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
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified...)
	activeSetReconcile(t, policy, 0, input)
	lease, _ := policy.BeginAttempt(0)
	if !policy.CompleteAttempt(0, lease, []string{activeSetContract(2)}, time.Minute) {
		t.Fatal("validated partial acknowledgement refused")
	}
	if !slices.Equal(policy.Successes(), []string{activeSetContract(2)}) || policy.Reason() != "preload_failed" {
		t.Fatal("partial S or bounded failure reason was lost")
	}
	activeSetReconcile(t, policy, 0, input)
	activeSetWant(t, policy, 2, 3)
	activeSetLoadAll(t, policy, 0)
	if slices.Contains(policy.Successes(), activeSetContract(1)) {
		t.Fatal("failed member reappeared in acknowledged set")
	}
}

func TestPreloadActiveSetTupleIdentityAndContractDeduplication(t *testing.T) {
	input := activeSetInput(3, 1)
	input.Verified[1].PromptContractID = input.Verified[0].PromptContractID
	input.Admissible = slices.Clone(input.Verified)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0], input.Verified[1])
	selected := activeSetReconcile(t, policy, 0, input)
	activeSetWant(t, policy, 1)
	for _, mutation := range []func(*preload.PreloadDemandIdentity){
		func(v *preload.PreloadDemandIdentity) { v.CatalogGeneration++ },
		func(v *preload.PreloadDemandIdentity) { v.ModelID = "caller-alias" },
		func(v *preload.PreloadDemandIdentity) { v.ModelAggregateSHA256 = activeSetContract(9000) },
		func(v *preload.PreloadDemandIdentity) { v.PromptContractID = activeSetContract(9001) },
	} {
		identity := input.Verified[0]
		mutation(&identity)
		if policy.NoteDemand(time.Second, identity) {
			t.Fatal("non-current exact tuple created interest")
		}
	}
	// Tick zero is accepted only while the refused calls left the clock alone,
	// and the unloaded contract stays selected only while its interest remains.
	// An added tuple is dropped before any selection, so it cannot show here.
	if again, err := policy.Reconcile(0, input); err != nil || !again.Equal(selected) {
		t.Fatal("invalid demand mutated retained state")
	}
	wantFields := []string{"CatalogGeneration", "ModelID", "ModelAggregateSHA256", "PromptContractID"}
	typ := reflect.TypeOf(preload.PreloadDemandIdentity{})
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
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0])
	activeSetReconcile(t, policy, 0, input)
	old, _ := policy.BeginAttempt(0)
	input.Admissible = slices.Clone(input.Verified[1:])
	activeSetReconcile(t, policy, time.Second, input)
	activeSetWant(t, policy)
	if _, ok := policy.BeginAttempt(time.Second); ok {
		t.Fatal("safety invalidation manufactured an overlapping lease")
	}
	if policy.CompleteAttempt(time.Second, old, old.Key.Desired, 0) || len(policy.Successes()) != 0 {
		t.Fatal("revoked completion restored old membership")
	}
	activeSetDemand(t, policy, time.Second, input.Verified[1])
	activeSetReconcile(t, policy, time.Second, input)
	current, ok := policy.BeginAttempt(time.Second)
	if !ok || policy.CompleteAttempt(time.Second, old, old.Key.Desired, 0) {
		t.Fatal("old callback consumed a replacement operation")
	}
	if !policy.CompleteAttempt(time.Second, current, current.Key.Desired, 0) {
		t.Fatal("replacement operation was lost")
	}
}

func TestPreloadActiveSetSameGenerationVerifiedGrowthFencesCompletion(t *testing.T) {
	input := activeSetInput(2, 1)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0])
	before := activeSetReconcile(t, policy, 0, input)
	lease, _ := policy.BeginAttempt(0)
	input = activeSetInput(3, 1)
	after := activeSetReconcile(t, policy, time.Second, input)
	if after.SelectionGeneration != before.SelectionGeneration || !slices.Equal(after.Desired, before.Desired) {
		t.Fatal("unchanged D spuriously changed selection generation")
	}
	if after.Equal(before) || policy.CompleteAttempt(time.Second, lease, lease.Key.Desired, 0) {
		t.Fatal("same-generation V growth accepted stale completion")
	}
	activeSetLoadAll(t, policy, time.Second)
}

func TestPreloadActiveSetWithinCapacityDoesNotPruneVerificationForAllowlist(t *testing.T) {
	input := activeSetInput(2, 2)
	policy := preload.NewPreloadActiveSet()
	first := activeSetReconcile(t, policy, 0, input)
	lease, _ := policy.BeginAttempt(0)
	input.Admissible = nil // Caller resolves explicitly empty allowlist to no eligible identities.
	next := activeSetReconcile(t, policy, time.Second, input)
	activeSetWant(t, policy, 1, 2)
	if next.SelectionGeneration != first.SelectionGeneration || next.Equal(first) {
		t.Fatal("admissibility fence changed D or failed to change K")
	}
	if policy.NoteDemand(time.Second, input.Verified[0]) || policy.CompleteAttempt(time.Second, lease, lease.Key.Desired, 0) {
		t.Fatal("revoked routing eligibility retained demand or stale publication")
	}
	activeSetLoadAll(t, policy, time.Second)
	// These successes are tokenizer facts only; they cannot authorize routing.
	if len(policy.Successes()) != 2 || len(policy.Snapshot().Verified) != 2 {
		t.Fatal("full verified catalog was pruned")
	}
}

func TestPreloadActiveSetChildRestartRetriesExactSelectedSet(t *testing.T) {
	input := activeSetInput(2, 1)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified[0])
	before := activeSetReconcile(t, policy, 0, input)
	activeSetLoadAll(t, policy, 0)
	input.ChildGeneration++
	after := activeSetReconcile(t, policy, 6*time.Minute, input)
	activeSetWant(t, policy, 1)
	if len(policy.Successes()) != 0 || after.SelectionGeneration != before.SelectionGeneration || after.Equal(before) {
		t.Fatal("child restart retained S or changed otherwise identical D")
	}
	activeSetLoadAll(t, policy, 6*time.Minute)
	// The admission age shows in when a waiter may take the slot: thirty
	// seconds after the new child's success, not after the old child's.
	activeSetDemand(t, policy, 6*time.Minute, input.Verified[1])
	activeSetReconcile(t, policy, 6*time.Minute+29*time.Second, input)
	residing := slices.Equal(policy.Snapshot().Desired, activeSetContracts(1))
	activeSetReconcile(t, policy, 6*time.Minute+30*time.Second, input)
	if !residing || !slices.Equal(policy.Snapshot().Desired, activeSetContracts(2)) {
		t.Fatal("new child inherited old admission age without new success")
	}
}

func TestPreloadActiveSetCatalogReplacementAndCapacityShrinkAreImmediate(t *testing.T) {
	input := activeSetInput(4, 3)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	activeSetDemand(t, policy, 0, input.Verified...)
	activeSetReconcile(t, policy, 0, input)
	activeSetLoadAll(t, policy, 0)
	input.Capacity = 1
	activeSetReconcile(t, policy, time.Second, input)
	if len(policy.Snapshot().Desired) != 1 || len(policy.Successes()) != 0 {
		t.Fatal("capacity safety closure waited for ordinary minimum residence")
	}
	input.CatalogGeneration++
	for i := range input.Verified {
		input.Verified[i].CatalogGeneration = input.CatalogGeneration
	}
	input.Admissible = slices.Clone(input.Verified)
	replaced := activeSetReconcile(t, policy, 2*time.Second, input)
	// Only demand can fill an overflowing set, and none has been noted for the
	// new catalog: interest carried over from the old one would be selected.
	if len(replaced.Desired) != 0 {
		t.Fatal("new catalog inherited old-generation interest")
	}
	activeSetWant(t, policy)
}

func TestPreloadActiveSetInvalidInputsCloseAndRemainBounded(t *testing.T) {
	for _, mutate := range []func(*preload.PreloadSelectionInput){
		func(v *preload.PreloadSelectionInput) { *v = activeSetInput(129, 8) },
		func(v *preload.PreloadSelectionInput) { v.Verified = append(v.Verified, v.Verified[0]) },
		func(v *preload.PreloadSelectionInput) { v.Verified[0].ModelID = strings.Repeat("m", 513) },
		func(v *preload.PreloadSelectionInput) { v.Verified[0].ModelAggregateSHA256 = strings.Repeat("A", 64) },
		func(v *preload.PreloadSelectionInput) { v.Verified[0].CatalogGeneration++ },
		func(v *preload.PreloadSelectionInput) { v.Admissible[0].ModelID = "not-current" },
		func(v *preload.PreloadSelectionInput) { v.Admissible = append(v.Admissible, v.Admissible[0]) },
		func(v *preload.PreloadSelectionInput) { v.Capacity = 0 },
		func(v *preload.PreloadSelectionInput) { v.CatalogGeneration = 0 },
		func(v *preload.PreloadSelectionInput) { v.PubliclyAvailable = []string{"not-current"} },
	} {
		input := activeSetInput(2, 2)
		policy := preload.NewPreloadActiveSet()
		activeSetReconcile(t, policy, 0, input)
		activeSetLoadAll(t, policy, 0)
		eligible := input.Verified[0]
		mutate(&input)
		if _, err := policy.Reconcile(time.Second, input); err == nil {
			t.Fatal("malformed/over-bound input accepted")
		}
		activeSetWant(t, policy)
		// No demand is held to be read back; a closed policy must also take none
		// for the tuple that was eligible until the invalid input.
		if len(policy.Successes()) != 0 || policy.NoteDemand(time.Second, eligible) {
			t.Fatal("invalid input retained participation")
		}
	}
}

func TestPreloadActiveSetDetachesIdentityAndReturnedSnapshots(t *testing.T) {
	policy := preload.NewPreloadActiveSet()
	// The caller's input and returned keys live only inside this call.
	callerBacking := func() weak.Pointer[byte] {
		input := activeSetInput(2, 1)
		backing := strings.Repeat("x", 1<<20) + input.Verified[0].ModelID
		input.Verified[0].ModelID = backing[len(backing)-len(input.Verified[0].ModelID):]
		input.Admissible = slices.Clone(input.Verified)
		key := activeSetReconcile(t, policy, 0, input)
		if unsafe.StringData(key.Verified[0].ModelID) == unsafe.StringData(input.Verified[0].ModelID) {
			t.Fatal("retained caller's large model-ID backing allocation")
		}
		activeSetDemand(t, policy, 0, input.Verified[0])
		activeSetReconcile(t, policy, 0, input)
		key = policy.Snapshot()
		key.Verified[0].ModelID, key.Admissible[0].ModelID, key.Desired[0] = "changed", "changed", "changed"
		input.Verified[0].PromptContractID = activeSetContract(999)
		activeSetWant(t, policy, 1)
		if policy.Snapshot().Verified[0].ModelID == "changed" {
			t.Fatal("caller mutated owned input or returned key")
		}
		return weak.Make(unsafe.StringData(backing))
	}()
	// The tuple retained for the demand is not readable. Observe instead that
	// the caller's megabyte allocation is collected while the policy holding
	// that demand is still live.
	runtime.GC()
	if callerBacking.Value() != nil {
		t.Fatal("demand insertion reintroduced caller string backing")
	}
	runtime.KeepAlive(policy)
}

func TestPreloadActiveSetLeaseIsDetachedAndAcknowledgementIsExactlyOnce(t *testing.T) {
	input := activeSetInput(2, 2)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, 0, input)
	lease, _ := policy.BeginAttempt(0)
	mutated := preload.PreloadSelectionLease{Operation: lease.Operation, Key: policy.Snapshot()}
	mutated.Key.Desired[0] = activeSetContract(99)
	if policy.CompleteAttempt(0, mutated, nil, time.Second) {
		t.Fatal("mutated lease accepted")
	}
	if !policy.CompleteAttempt(0, lease, lease.Key.Desired, 0) || policy.CompleteAttempt(0, lease, lease.Key.Desired, 0) {
		t.Fatal("valid lease was lost or completed twice")
	}
	for _, invalid := range [][]string{{activeSetContract(1), activeSetContract(1)}, {activeSetContract(99)}, make([]string, 129)} {
		candidate := preload.NewPreloadActiveSet()
		activeSetReconcile(t, candidate, 0, input)
		attempt, _ := candidate.BeginAttempt(0)
		if candidate.CompleteAttempt(0, attempt, invalid, time.Second) || len(candidate.Successes()) != 0 {
			t.Fatal("invalid success report published members")
		}
	}
}

// Exhaustion of the selection generation and of the operation counter is not
// covered here. Both advance only by one per change or lease and nothing seeds
// them, so their limits are not reachable through the policy's operations.
func TestPreloadActiveSetMonotonicClockAndGenerationExhaustion(t *testing.T) {
	input := activeSetInput(2, 1)
	policy := preload.NewPreloadActiveSet()
	activeSetReconcile(t, policy, time.Second, input)
	if policy.NoteDemand(0, input.Verified[0]) {
		t.Fatal("backward demand clock accepted")
	}
	// A closed selection has dropped its key and takes no interest, even at a
	// tick it would otherwise accept.
	if closed, err := policy.Reconcile(0, input); err == nil || closed.CatalogGeneration != 0 || policy.NoteDemand(time.Second, input.Verified[0]) {
		t.Fatal("backward authoritative clock did not close selection")
	}
}
