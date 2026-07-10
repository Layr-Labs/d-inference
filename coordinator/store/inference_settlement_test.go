package store

import (
	"errors"
	"testing"
)

func TestSettleInferenceAtomicallyMovesEveryProjection(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			settlement := fundedSettlementFixture(t, backend, uniqueID("settlement"))
			disposition, err := backend.SettleInference(settlement)
			if err != nil {
				t.Fatal(err)
			}
			if disposition != InferenceSettlementApplied {
				t.Fatalf("first settlement disposition = %q", disposition)
			}
			if balance, withdrawable := backend.GetBalanceWithWithdrawable(settlement.ConsumerAccountID); balance != 80_000 || withdrawable != 70_000 {
				t.Fatalf("consumer balance = %d/%d, want 80000/70000", balance, withdrawable)
			}
			if balance, withdrawable := backend.GetBalanceWithWithdrawable(settlement.ProviderEarning.AccountID); balance != 80_000 || withdrawable != 80_000 {
				t.Fatalf("provider balance = %d/%d, want 80000/80000", balance, withdrawable)
			}
			if balance, withdrawable := backend.GetBalanceWithWithdrawable("platform"); balance != 5_000 || withdrawable != 0 {
				t.Fatalf("platform balance = %d/%d, want 5000/0", balance, withdrawable)
			}
			if balance, withdrawable := backend.GetBalanceWithWithdrawable(settlement.ReferrerAccountID); balance != 5_000 || withdrawable != 5_000 {
				t.Fatalf("referrer balance = %d/%d, want 5000/5000", balance, withdrawable)
			}
			usage := backend.UsageByConsumer(settlement.ConsumerAccountID)
			if len(usage) != 1 || usage[0].RequestID != settlement.RequestID {
				t.Fatalf("usage = %+v, want one canonical row", usage)
			}
			earnings, err := backend.GetAccountEarnings(settlement.ProviderEarning.AccountID, 10)
			if err != nil || len(earnings) != 1 || earnings[0].JobID != settlement.RequestID {
				t.Fatalf("earnings = %+v, %v", earnings, err)
			}

			disposition, err = backend.SettleInference(settlement)
			if err != nil {
				t.Fatal(err)
			}
			if disposition != InferenceSettlementReplayed {
				t.Fatalf("settlement replay disposition = %q", disposition)
			}
			if balance := backend.GetBalance(settlement.ProviderEarning.AccountID); balance != 80_000 {
				t.Fatalf("replay changed provider balance to %d", balance)
			}

			conflict := cloneInferenceSettlement(settlement)
			conflict.CostMicroUSD--
			conflict.Usage.CostMicroUSD--
			if _, err := backend.SettleInference(conflict); !errors.Is(err, ErrFinancialOperationConflict) {
				t.Fatalf("conflicting terminal error = %v", err)
			}
		})
	}
}

func TestSettleInferenceDoesNotOverridePriorRelease(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			settlement := fundedSettlementFixture(t, backend, uniqueID("late-settlement"))
			if _, err := backend.ReleaseInferenceReservation(
				settlement.ConsumerAccountID,
				settlement.ReservedMicroUSD,
				settlement.ReservedWithdrawableMicroUSD,
				"finalize:"+settlement.ReservationID,
				"failed",
			); err != nil {
				t.Fatal(err)
			}
			disposition, err := backend.SettleInference(settlement)
			if err != nil {
				t.Fatal(err)
			}
			if disposition != InferenceSettlementAlreadyReleased {
				t.Fatalf("late terminal disposition = %q", disposition)
			}
			if balance := backend.GetBalance(settlement.ProviderEarning.AccountID); balance != 0 {
				t.Fatalf("late terminal paid provider %d", balance)
			}
		})
	}
}

func TestSettleInferenceRollsBackEveryProjectionOnConflict(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			settlement := fundedSettlementFixture(t, backend, uniqueID("rollback-settlement"))
			if err := backend.RecordProviderEarning(&ProviderEarning{
				AccountID: "existing-provider", ProviderID: "existing",
				ProviderKey: "existing-key", JobID: settlement.RequestID,
				Model: settlement.ProviderEarning.Model, AmountMicroUSD: 1,
			}); err != nil {
				t.Fatal(err)
			}
			if _, err := backend.SettleInference(settlement); err == nil {
				t.Fatal("duplicate provider earning did not fail settlement")
			}
			if balance, withdrawable := backend.GetBalanceWithWithdrawable(settlement.ConsumerAccountID); balance != 50_000 || withdrawable != 50_000 {
				t.Fatalf("failed settlement mutated consumer = %d/%d, want held 50000/50000", balance, withdrawable)
			}
			if balance := backend.GetBalance(settlement.ProviderEarning.AccountID); balance != 0 {
				t.Fatalf("failed settlement credited provider %d", balance)
			}
			if balance := backend.GetBalance("platform"); balance != 0 {
				t.Fatalf("failed settlement credited platform %d", balance)
			}
		})
	}
}

func TestSettleInferenceAtomicallyDebitsServiceHold(t *testing.T) {
	for name, backend := range storeBackends(t) {
		t.Run(name, func(t *testing.T) {
			consumer := uniqueID("service-consumer")
			provider := uniqueID("service-provider")
			if err := backend.Credit(consumer, 1_000, LedgerStripeDeposit, "deposit"); err != nil {
				t.Fatal(err)
			}
			requestID := uniqueID("service-request")
			settlement := &InferenceSettlement{
				ReservationID: uniqueID("service-reservation"), RequestID: requestID,
				ConsumerAccountID: consumer, ReservedMicroUSD: 500,
				ReservationPreDebited: false, CostMicroUSD: 250,
				ProviderEarning: &ProviderEarning{
					AccountID: provider, ProviderID: "provider-id", ProviderKey: "provider-key",
					JobID: requestID, Model: "model", AmountMicroUSD: 200,
				},
				PlatformFeeMicroUSD: 50,
			}
			disposition, err := backend.SettleInference(settlement)
			if err != nil {
				t.Fatal(err)
			}
			if disposition != InferenceSettlementApplied {
				t.Fatalf("service settlement disposition = %q", disposition)
			}
			if balance := backend.GetBalance(consumer); balance != 750 {
				t.Fatalf("service consumer balance = %d, want 750", balance)
			}
			if balance, withdrawable := backend.GetBalanceWithWithdrawable(provider); balance != 200 || withdrawable != 200 {
				t.Fatalf("service provider balance = %d/%d, want 200/200", balance, withdrawable)
			}
			if balance := backend.GetBalance("platform"); balance != 50 {
				t.Fatalf("platform balance = %d, want 50", balance)
			}
		})
	}
}

func fundedSettlementFixture(t *testing.T, backend Store, reservationID string) *InferenceSettlement {
	t.Helper()
	consumer := uniqueID("settlement-consumer")
	provider := uniqueID("settlement-provider")
	referrer := uniqueID("settlement-referrer")
	if err := backend.Credit(consumer, 100_000, LedgerStripeDeposit, "deposit"); err != nil {
		t.Fatal(err)
	}
	if err := backend.CreditWithdrawable(consumer, 70_000, LedgerPayout, "earnings"); err != nil {
		t.Fatal(err)
	}
	reservedWithdrawable, _, err := backend.ReserveInferenceBalance(consumer, 120_000, reservationID)
	if err != nil {
		t.Fatal(err)
	}
	requestID := uniqueID("settlement-request")
	return &InferenceSettlement{
		ReservationID: reservationID, RequestID: requestID,
		ConsumerAccountID: consumer, ReservedMicroUSD: 120_000,
		ReservedWithdrawableMicroUSD: reservedWithdrawable,
		ReservationPreDebited:        true, CostMicroUSD: 90_000,
		ProviderEarning: &ProviderEarning{
			AccountID: provider, ProviderID: "provider-id", ProviderKey: "provider-key",
			JobID: requestID, Model: "model", AmountMicroUSD: 80_000,
			PromptTokens: 10, CompletionTokens: 20,
		},
		PlatformFeeMicroUSD: 5_000, ReferrerAccountID: referrer,
		ReferralRewardMicroUSD: 5_000,
		Usage: &UsageRecord{
			ProviderID: "provider-id", ConsumerKey: consumer, KeyID: "key-id",
			Model: "model", PublicModel: "public-model", PromptTokens: 10,
			CompletionTokens: 20, RequestID: requestID, CostMicroUSD: 90_000,
		},
	}
}
