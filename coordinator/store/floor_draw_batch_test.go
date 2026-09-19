package store

import (
	"context"
	"errors"
	"fmt"
	"testing"
	"time"
)

func floorBatchFixture(epoch string) []FloorDrawBatchItem {
	return []FloorDrawBatchItem{
		{SessionID: "first", Draw: ProviderFloorDraw{ProviderKey: "first-key", AccountID: "first", EpochID: epoch, AmountMicroUSD: 5, FloorMicroUSD: 10}},
		{SessionID: "second", Draw: ProviderFloorDraw{ProviderKey: "second-key", AccountID: "second", EpochID: epoch, AmountMicroUSD: 5, FloorMicroUSD: 10}},
		{SessionID: "waitlisted", Draw: ProviderFloorDraw{ProviderKey: "waitlisted-key", AccountID: "waitlisted", EpochID: epoch, AmountMicroUSD: 0, FloorMicroUSD: 10}},
	}
}

func assertFloorBatchEmpty(t *testing.T, backend Store, epoch string) {
	t.Helper()
	draws, err := backend.ListFloorDrawsForEpoch(context.Background(), epoch)
	if err != nil || len(draws) != 0 {
		t.Fatalf("rejected batch left floor rows: %+v %v", draws, err)
	}
	for _, account := range []string{"first", "second", "waitlisted"} {
		if backend.GetBalance(account) != 0 || backend.GetWithdrawableBalance(account) != 0 || len(backend.LedgerHistory(account)) != 0 {
			t.Fatalf("rejected batch credited %s", account)
		}
		earnings, err := backend.GetAccountEarnings(account, 100)
		if err != nil || len(earnings) != 0 {
			t.Fatalf("rejected batch left earnings for %s: %+v %v", account, earnings, err)
		}
	}
}

func TestFloorDrawBatchLateAuthorizationAndCancellationRollBack(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			batch, ok := As[FloorDrawBatchStore](NewCached(backend, DefaultCacheConfig()))
			if !ok {
				t.Fatal("cached store hides atomic settlement")
			}
			for _, phase := range []string{"after-first-insert", "before-commit", "cancel-after-first-insert", "cancel-before-commit"} {
				t.Run(phase, func(t *testing.T) {
					ctx, cancel := context.WithCancel(context.Background())
					defer cancel()
					calls := make(map[int]int)
					result, err := batch.SettleProviderFloorDrawBatch(ctx, floorBatchFixture(phase), func(i int) bool {
						calls[i]++
						switch phase {
						case "after-first-insert":
							return i != 1
						case "before-commit":
							return i != 0 || calls[i] == 1
						case "cancel-after-first-insert":
							if i == 1 {
								cancel()
							}
						case "cancel-before-commit":
							if i == 0 && calls[i] == 2 {
								cancel()
							}
						}
						return true
					})
					if result.Committed {
						t.Fatal("invalid batch committed")
					}
					if phase == "after-first-insert" || phase == "before-commit" {
						if err != nil || len(result.Rejections) != 1 || result.Rejections[0].Reason != FloorDrawUnauthorized {
							t.Fatalf("authorization rejection: %+v %v", result, err)
						}
					} else if !errors.Is(err, context.Canceled) {
						t.Fatalf("cancelled batch returned %v", err)
					}
					assertFloorBatchEmpty(t, backend, phase)
				})
			}
			// Reallocated partial grants can commit after the failed plan. The
			// original partial/zero rows were never frozen or credited.
			items := floorBatchFixture("retry")
			items[0].Draw.AmountMicroUSD = 8
			items[2].Draw.AmountMicroUSD = 2
			items = []FloorDrawBatchItem{items[0], items[2]}
			result, err := batch.SettleProviderFloorDrawBatch(context.Background(), items, func(int) bool { return true })
			if err != nil || !result.Committed || backend.GetBalance("first") != 8 || backend.GetBalance("waitlisted") != 2 {
				t.Fatalf("reallocated batch: %+v %v", result, err)
			}
			result, err = batch.SettleProviderFloorDrawBatch(context.Background(), items, func(int) bool { return true })
			if err != nil || result.Committed || len(result.Rejections) != 1 || result.Rejections[0].Reason != FloorDrawAlreadyPaid || backend.GetBalance("first") != 8 {
				t.Fatalf("retry duplicated money: %+v %v", result, err)
			}
		})
	}
}

func TestFloorDrawBatchRejectsRawAndCanonicalAliasesInEitherOrder(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			inventory, _ := As[MachineInventoryStore](backend)
			batch, _ := As[FloorDrawBatchStore](backend)
			machine, err := inventory.ObserveMachine(ctx, MachineObservation{SessionID: "known", AccountID: "owner", VerifiedAppAttestKey: "apple-key", At: time.Now()})
			if err != nil {
				t.Fatal(err)
			}
			if err := backend.OpenProviderSession(ctx, "known", "", "owner"); err != nil {
				t.Fatal(err)
			}
			if err := backend.TouchProviderSession(ctx, "known", "", "owner", "endpoint", time.Now()); err != nil {
				t.Fatal(err)
			}
			for _, reverse := range []bool{false, true} {
				epoch := fmt.Sprintf("alias-%v", reverse)
				canonical := FloorDrawBatchItem{SessionID: "known", MachineID: machine.ID, Draw: ProviderFloorDraw{ProviderKey: MachineFloorKey(machine.ID), AccountID: "owner", EpochID: epoch, AmountMicroUSD: 10}}
				// This reconnect has no inventory row yet, but its same-account
				// endpoint key was already bound by the prior session.
				raw := FloorDrawBatchItem{SessionID: "new-pending-inventory", Draw: ProviderFloorDraw{ProviderKey: "endpoint", AccountID: "owner", EpochID: epoch, AmountMicroUSD: 10}}
				items := []FloorDrawBatchItem{canonical, raw}
				if reverse {
					items[0], items[1] = items[1], items[0]
				}
				result, err := batch.SettleProviderFloorDrawBatch(ctx, items, func(int) bool { return true })
				if err != nil || result.Committed || len(result.Rejections) != 1 || result.Rejections[0].Reason != FloorDrawDuplicate {
					t.Fatalf("duplicate alias %v: %+v %v", reverse, result, err)
				}
				draws, err := backend.ListFloorDrawsForEpoch(ctx, epoch)
				if err != nil || len(draws) != 0 || backend.GetBalance("owner") != 0 {
					t.Fatal("alias batch credited twice")
				}
			}
		})
	}
}

func TestFloorDrawBatchOversizeIsExplicitAndCommitsNothing(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			batch, _ := As[FloorDrawBatchStore](backend)
			items := make([]FloorDrawBatchItem, FloorDrawBatchLimit+1)
			for i := range items {
				items[i] = FloorDrawBatchItem{SessionID: fmt.Sprint(i), Draw: ProviderFloorDraw{ProviderKey: fmt.Sprint(i), AccountID: "first", EpochID: "oversize", AmountMicroUSD: 1}}
			}
			checks := 0
			result, err := batch.SettleProviderFloorDrawBatch(context.Background(), items, func(int) bool { checks++; return true })
			if err == nil || result.Committed || checks != 0 {
				t.Fatalf("oversized plan was truncated: %+v %v", result, err)
			}
			assertFloorBatchEmpty(t, backend, "oversize")
		})
	}
}

func TestFloorDrawBatchLateIdempotencyConflictPreservesOnlyPriorCredit(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			batch, _ := As[FloorDrawBatchStore](backend)
			items := floorBatchFixture("late-conflict")
			prior := items[1].Draw
			prior.AmountMicroUSD = 7
			if paid, err := backend.SettleProviderFloorDraw(ctx, &prior); err != nil || !paid {
				t.Fatal("prior setup", err)
			}
			result, err := batch.SettleProviderFloorDrawBatch(ctx, items, func(int) bool { return true })
			if err != nil || result.Committed || len(result.Rejections) != 1 || result.Rejections[0].Index != 1 || result.Rejections[0].Reason != FloorDrawAlreadyPaid {
				t.Fatalf("late conflict: %+v %v", result, err)
			}
			draws, err := backend.ListFloorDrawsForEpoch(ctx, "late-conflict")
			if err != nil || len(draws) != 1 || draws[0].ProviderKey != "second-key" || draws[0].AmountMicroUSD != 7 || backend.GetBalance("first") != 0 || backend.GetBalance("second") != 7 {
				t.Fatalf("late conflict changed money: %+v %v", draws, err)
			}
		})
	}
}
