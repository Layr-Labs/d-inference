package store_test

import (
	"context"
	"errors"
	"reflect"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMachineRewardBindingsAndAccountScopedEarnings(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			inventory, _ := store.As[store.MachineInventoryStore](backend)
			rewards, ok := store.As[store.MachineRewardStore](store.NewCached(backend, store.DefaultCacheConfig()))
			if !ok {
				t.Fatal("machine rewards hidden")
			}
			now := time.Now().UTC()
			first, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: "old", AccountID: "owner", SEKey: "old-se", At: now})
			if err != nil {
				t.Fatal(err)
			}
			other, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: "new", AccountID: "owner", SEKey: "new-se", At: now})
			if err != nil {
				t.Fatal(err)
			}
			for _, o := range []store.MachineObservation{{SessionID: "old", AccountID: "owner", SEKey: "old-se", VerifiedAppAttestKey: "apple", At: now}, {SessionID: "new", AccountID: "owner", SEKey: "new-se", VerifiedAppAttestKey: "apple", At: now}} {
				if _, err := inventory.ObserveMachine(ctx, o); err != nil {
					t.Fatal(err)
				}
			}
			bindings, err := rewards.GetMachineRewardBindings(ctx, []string{"old", "new", "unknown", "old"})
			if err != nil || len(bindings) != 2 || bindings["new"].MachineID != first.ID || bindings["new"].AccountID != "owner" || !slices.Contains(bindings["new"].MachineAliases, other.ID) {
				t.Fatalf("merged reward bindings: %+v %v", bindings, err)
			}
			for _, earning := range []store.ProviderEarning{
				{AccountID: "owner", ProviderKey: "old-key", JobID: "a", Model: "model", AmountMicroUSD: 40, CreatedAt: now},
				{AccountID: "owner", ProviderKey: "new-key", JobID: "b", Model: "model", AmountMicroUSD: 60, CreatedAt: now},
				{AccountID: "other", ProviderKey: "old-key", JobID: "c", Model: "model", AmountMicroUSD: 500, CreatedAt: now},
				{AccountID: "owner", ProviderKey: "old-key", JobID: "d", Model: "base_reward", AmountMicroUSD: 500, CreatedAt: now},
			} {
				if err := backend.RecordProviderEarning(&earning); err != nil {
					t.Fatal(err)
				}
			}
			sum, err := rewards.SumProviderEarningsByKeysForAccount(ctx, "owner", []string{"old-key", "new-key", "old-key"}, now.Add(-time.Second), now.Add(time.Second))
			if err != nil || sum != 100 {
				t.Fatalf("rotated earning sum: %d %v", sum, err)
			}
		})
	}
}

func TestMachineFloorSettlementPreservesOldKeysAndMergeIdempotency(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			inventory, _ := store.As[store.MachineInventoryStore](backend)
			rewards, _ := store.As[store.MachineRewardStore](backend)
			now := time.Now()
			// The legacy floor was paid under the raw endpoint key before any
			// machine inventory bound that key.
			legacy := &store.ProviderFloorDraw{ProviderKey: "original-encryption-key", AccountID: "owner", EpochID: "legacy-epoch", AmountMicroUSD: 123}
			if !settleFloorDraw(t, backend, legacy) {
				t.Fatal("legacy setup was not credited")
			}
			first, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: "old", AccountID: "owner", SEKey: "se", VerifiedAppAttestKey: "apple", At: now})
			if err != nil {
				t.Fatal(err)
			}
			if err := backend.OpenProviderSession(ctx, "old", "", "owner"); err != nil {
				t.Fatal(err)
			}
			if err := backend.TouchProviderSession(ctx, "old", "", "owner", "original-encryption-key", now); err != nil {
				t.Fatal(err)
			}
			before := backend.LedgerHistory("owner")
			if paid, err := rewards.SettleMachineFloorDraw(ctx, first.ID, legacy); err != nil || paid {
				t.Fatalf("migration paid a second floor %v %v", paid, err)
			}
			if after := backend.LedgerHistory("owner"); !reflect.DeepEqual(before, after) {
				t.Fatal("migration rewrote the ledger")
			}
			canonicalFirst := &store.ProviderFloorDraw{ProviderKey: "original-encryption-key", AccountID: "owner", EpochID: "canonical-first", AmountMicroUSD: 234}
			if paid, err := rewards.SettleMachineFloorDraw(ctx, first.ID, canonicalFirst); err != nil || !paid {
				t.Fatalf("canonical-first setup: %v %v", paid, err)
			}
			batch, _ := store.As[store.FloorDrawBatchStore](backend)
			stale, err := batch.SettleProviderFloorDrawBatch(ctx, []store.FloorDrawBatchItem{{SessionID: "old", Draw: *canonicalFirst}}, func(int) bool { return true })
			if err != nil || stale.Committed || len(stale.Rejections) != 1 || stale.Rejections[0].Reason != store.FloorDrawAlreadyPaid {
				t.Fatalf("stale raw key paid after canonical floor: %+v %v", stale, err)
			}
			second, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: "new", AccountID: "owner", SEKey: "new-se", At: now})
			if err != nil {
				t.Fatal(err)
			}
			draw := &store.ProviderFloorDraw{AccountID: "owner", EpochID: "merge-epoch", AmountMicroUSD: 321}
			if paid, err := rewards.SettleMachineFloorDraw(ctx, second.ID, draw); err != nil || !paid {
				t.Fatalf("new canonical floor %v %v", paid, err)
			}
			if _, err := inventory.ObserveMachine(ctx, store.MachineObservation{SessionID: "new", AccountID: "owner", SEKey: "new-se", VerifiedAppAttestKey: "apple", At: now}); err != nil {
				t.Fatal(err)
			}
			if paid, err := rewards.SettleMachineFloorDraw(ctx, first.ID, draw); err != nil || paid {
				t.Fatalf("merged source paid again %v %v", paid, err)
			}
			draw.EpochID = "concurrent-epoch"
			var paidCount atomic.Int32
			var wg sync.WaitGroup
			for i := 0; i < 12; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					paid, err := rewards.SettleMachineFloorDraw(ctx, second.ID, draw)
					if err != nil {
						t.Error(err)
					} else if paid {
						paidCount.Add(1)
					}
				}()
			}
			wg.Wait()
			if paidCount.Load() != 1 {
				t.Fatalf("concurrent canonical credits = %d", paidCount.Load())
			}
			if backend.GetBalance("owner") != 123+234+321+321 {
				t.Fatal("unexpected balance after canonical credits")
			}
			wrongOwner := *draw
			wrongOwner.AccountID = "other"
			if _, err := rewards.SettleMachineFloorDraw(ctx, first.ID, &wrongOwner); !errors.Is(err, store.ErrMachineContinuityUnverified) {
				t.Fatalf("unassociated account received floor: %v", err)
			}
		})
	}
}
