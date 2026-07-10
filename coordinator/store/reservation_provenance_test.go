package store

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestInferenceReservationPreservesMixedProvenance(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			accountID := uniqueID("reservation-mixed")
			if err := backend.Credit(accountID, 100_000, LedgerStripeDeposit, "deposit"); err != nil {
				t.Fatal(err)
			}
			if err := backend.CreditWithdrawable(accountID, 70_000, LedgerPayout, "earnings"); err != nil {
				t.Fatal(err)
			}
			reservationID := uniqueID("reserve")
			reservedWithdrawable, applied, err := backend.ReserveInferenceBalance(accountID, 120_000, reservationID)
			if err != nil {
				t.Fatal(err)
			}
			if !applied || reservedWithdrawable != 20_000 {
				t.Fatalf("reserve = withdrawable:%d applied:%t, want 20000/true", reservedWithdrawable, applied)
			}
			replayedWithdrawable, replayApplied, err := backend.ReserveInferenceBalance(accountID, 120_000, reservationID)
			if err != nil {
				t.Fatal(err)
			}
			if replayApplied || replayedWithdrawable != reservedWithdrawable {
				t.Fatalf("reserve replay = withdrawable:%d applied:%t, want %d/false",
					replayedWithdrawable, replayApplied, reservedWithdrawable)
			}
			if balance, withdrawable := backend.GetBalanceWithWithdrawable(accountID); balance != 50_000 || withdrawable != 50_000 {
				t.Fatalf("held balance = %d/%d, want 50000/50000", balance, withdrawable)
			}

			refund := int64(30_000)
			refundWithdrawable := min(refund, reservedWithdrawable)
			released, err := backend.ReleaseInferenceReservation(
				accountID, refund, refundWithdrawable, "finalize:"+reservationID, "settlement",
			)
			if err != nil {
				t.Fatal(err)
			}
			if !released {
				t.Fatal("first release was not applied")
			}
			if balance, withdrawable := backend.GetBalanceWithWithdrawable(accountID); balance != 80_000 || withdrawable != 70_000 {
				t.Fatalf("settled balance = %d/%d, want 80000/70000", balance, withdrawable)
			}
			released, err = backend.ReleaseInferenceReservation(
				accountID, refund, refundWithdrawable, "finalize:"+reservationID, "settlement",
			)
			if err != nil {
				t.Fatal(err)
			}
			if released {
				t.Fatal("duplicate release applied twice")
			}
			if balance, withdrawable := backend.GetBalanceWithWithdrawable(accountID); balance != 80_000 || withdrawable != 70_000 {
				t.Fatalf("replay changed balance = %d/%d", balance, withdrawable)
			}
		})
	}
}

func TestInferenceReservationAllWithdrawableAndFullRelease(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			accountID := uniqueID("reservation-withdrawable")
			if err := backend.CreditWithdrawable(accountID, 100_000, LedgerPayout, "earnings"); err != nil {
				t.Fatal(err)
			}
			reservationID := uniqueID("reserve")
			reservedWithdrawable, _, err := backend.ReserveInferenceBalance(accountID, 40_000, reservationID)
			if err != nil {
				t.Fatal(err)
			}
			if reservedWithdrawable != 40_000 {
				t.Fatalf("reserved withdrawable = %d, want 40000", reservedWithdrawable)
			}
			if _, err := backend.ReleaseInferenceReservation(
				accountID, 40_000, 40_000, "finalize:"+reservationID, "failed",
			); err != nil {
				t.Fatal(err)
			}
			if balance, withdrawable := backend.GetBalanceWithWithdrawable(accountID); balance != 100_000 || withdrawable != 100_000 {
				t.Fatalf("released balance = %d/%d, want 100000/100000", balance, withdrawable)
			}
		})
	}
}

func TestInferenceReservationOperationKeysAreAtomic(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			accountID := uniqueID("reservation-concurrent")
			if err := backend.Credit(accountID, 100_000, LedgerStripeDeposit, "deposit"); err != nil {
				t.Fatal(err)
			}
			operationKey := uniqueID("reserve")
			var applied atomic.Int32
			errs := make(chan error, 16)
			var workers sync.WaitGroup
			for range 16 {
				workers.Add(1)
				go func() {
					defer workers.Done()
					_, didApply, err := backend.ReserveInferenceBalance(accountID, 40_000, operationKey)
					if didApply {
						applied.Add(1)
					}
					errs <- err
				}()
			}
			workers.Wait()
			close(errs)
			for err := range errs {
				if err != nil {
					t.Errorf("reserve replay: %v", err)
				}
			}
			if applied.Load() != 1 {
				t.Fatalf("applied reserves = %d, want 1", applied.Load())
			}
			if balance := backend.GetBalance(accountID); balance != 60_000 {
				t.Fatalf("balance = %d, want 60000", balance)
			}
			if _, _, err := backend.ReserveInferenceBalance(accountID, 50_000, operationKey); !errors.Is(err, ErrFinancialOperationConflict) {
				t.Fatalf("operation-key conflict error = %v", err)
			}

			releaseKey := "finalize:" + operationKey
			applied.Store(0)
			errs = make(chan error, 16)
			workers = sync.WaitGroup{}
			for range 16 {
				workers.Add(1)
				go func() {
					defer workers.Done()
					didApply, err := backend.ReleaseInferenceReservation(
						accountID, 40_000, 0, releaseKey, "refund",
					)
					if didApply {
						applied.Add(1)
					}
					errs <- err
				}()
			}
			workers.Wait()
			close(errs)
			for err := range errs {
				if err != nil {
					t.Errorf("release replay: %v", err)
				}
			}
			if applied.Load() != 1 {
				t.Fatalf("applied releases = %d, want 1", applied.Load())
			}
			if balance := backend.GetBalance(accountID); balance != 100_000 {
				t.Fatalf("released balance = %d, want 100000", balance)
			}
			if _, err := backend.ReleaseInferenceReservation(
				accountID, 30_000, 0, releaseKey, "refund",
			); !errors.Is(err, ErrFinancialOperationConflict) {
				t.Fatalf("release-key conflict error = %v", err)
			}
		})
	}
}

func TestRejectedReservationOperationCanRetryAfterFunding(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			accountID := uniqueID("reservation-retry")
			operationKey := uniqueID("reserve")
			if _, _, err := backend.ReserveInferenceBalance(accountID, 40_000, operationKey); !errors.Is(err, ErrInsufficientBalance) {
				t.Fatalf("unfunded reserve error = %v", err)
			}
			if err := backend.Credit(accountID, 50_000, LedgerStripeDeposit, "deposit"); err != nil {
				t.Fatal(err)
			}
			_, applied, err := backend.ReserveInferenceBalance(accountID, 40_000, operationKey)
			if err != nil {
				t.Fatal(err)
			}
			if !applied {
				t.Fatal("funded retry did not apply")
			}
			if balance := backend.GetBalance(accountID); balance != 10_000 {
				t.Fatalf("balance = %d, want 10000", balance)
			}
		})
	}
}

func TestPostgresRecoversStaleBaseAndTopUpReservations(t *testing.T) {
	backend := testPostgresStore(t)
	const accountID = "stale-reservation-account"
	if err := backend.Credit(accountID, 100_000, LedgerStripeDeposit, "deposit"); err != nil {
		t.Fatal(err)
	}
	if err := backend.CreditWithdrawable(accountID, 50_000, LedgerPayout, "earning"); err != nil {
		t.Fatal(err)
	}
	const reservationID = "stale-reservation"
	if _, _, err := backend.ReserveInferenceBalance(accountID, 100_000, reservationID); err != nil {
		t.Fatal(err)
	}
	const topupKey = "topup:stale-reservation:attempt:provider"
	if _, _, err := backend.ReserveInferenceBalance(accountID, 20_000, topupKey); err != nil {
		t.Fatal(err)
	}
	if _, err := backend.pool.Exec(
		t.Context(),
		`UPDATE balance_reservation_operations
		 SET created_at = NOW() - INTERVAL '1 hour'
		 WHERE operation_key IN ($1, $2)`,
		reservationID, topupKey,
	); err != nil {
		t.Fatal(err)
	}
	recovered, err := backend.RecoverStaleInferenceReservations(time.Now().Add(-20 * time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if recovered != 1 {
		t.Fatalf("recovered = %d, want 1", recovered)
	}
	if balance, withdrawable := backend.GetBalanceWithWithdrawable(accountID); balance != 150_000 || withdrawable != 50_000 {
		t.Fatalf("recovered balance = %d/%d, want 150000/50000", balance, withdrawable)
	}
	recovered, err = backend.RecoverStaleInferenceReservations(time.Now().Add(-20 * time.Minute))
	if err != nil || recovered != 0 {
		t.Fatalf("recovery replay = %d, %v; want 0", recovered, err)
	}
}

func TestPostgresStaleRecoveryPreservesReviewPendingReservation(t *testing.T) {
	backend := testPostgresStore(t)
	const (
		accountID     = "review-reservation-account"
		reservationID = "review-reservation"
	)
	if err := backend.Credit(accountID, 100_000, LedgerStripeDeposit, "deposit"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := backend.ReserveInferenceBalance(accountID, 50_000, reservationID); err != nil {
		t.Fatal(err)
	}
	if _, err := backend.pool.Exec(
		t.Context(),
		`UPDATE balance_reservation_operations
		 SET created_at = NOW() - INTERVAL '1 hour'
		 WHERE operation_key = $1`,
		reservationID,
	); err != nil {
		t.Fatal(err)
	}
	if err := backend.RecordInferenceSettlementReview(&InferenceSettlement{
		ReservationID: reservationID, RequestID: "review-request",
		ConsumerAccountID: accountID, ReservedMicroUSD: 50_000,
		ReservationPreDebited: true,
	}, "invalid provider terminal"); err != nil {
		t.Fatal(err)
	}
	recovered, err := backend.RecoverStaleInferenceReservations(time.Now().Add(-20 * time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if recovered != 0 {
		t.Fatalf("review-pending reservation recovered automatically: %d", recovered)
	}
	if balance := backend.GetBalance(accountID); balance != 50_000 {
		t.Fatalf("review-pending balance = %d, want held 50000", balance)
	}
}
