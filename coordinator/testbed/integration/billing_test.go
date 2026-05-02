package integration

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/eigeninference/coordinator/testbed/assert"
	"github.com/eigeninference/coordinator/testbed/deps"
	"github.com/jackc/pgx/v5/pgxpool"
)

func shouldRunBilling() bool {
	return os.Getenv("LIVE_BILLING_INTEGRATION") == "1"
}

func setupBillingTest(t *testing.T) (*deps.PostgresLifecycle, store.Store, *pgxpool.Pool) {
	t.Helper()
	if !shouldRunBilling() {
		t.Skip("skipping: set LIVE_BILLING_INTEGRATION=1 to run Postgres billing tests (requires Docker)")
	}

	logger := slog.Default()
	pg := deps.NewPostgresLifecycle(logger, 5434)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if err := pg.Start(ctx); err != nil {
		t.Fatalf("start postgres: %v", err)
	}
	t.Cleanup(func() { pg.Stop() })

	pgStore, err := store.NewPostgres(context.Background(), pg.DatabaseURL)
	if err != nil {
		t.Fatalf("connect to postgres: %v", err)
	}
	t.Cleanup(func() { pgStore.Close() })

	var st store.Store = pgStore

	pool, err := pgxpool.New(context.Background(), pg.DatabaseURL)
	if err != nil {
		t.Fatalf("create pgxpool: %v", err)
	}
	t.Cleanup(func() { pool.Close() })

	return pg, st, pool
}

func TestBilling_DepositCreditsBalance(t *testing.T) {
	_, st, pool := setupBillingTest(t)
	ctx := context.Background()

	accountID := "test-consumer-deposit"
	amount := int64(10_000_000) // $10.00

	err := st.Credit(accountID, amount, store.LedgerStripeDeposit, "stripe:cs_test_123")
	if err != nil {
		t.Fatalf("credit deposit: %v", err)
	}

	balance := st.GetBalance(accountID)
	if balance != amount {
		t.Fatalf("expected balance %d, got %d", amount, balance)
	}

	asserter := assert.NewPostgresAccountingAsserter(pool)
	report := asserter.EvaluateAll(ctx)
	if !report.Passed {
		for _, r := range report.Results {
			t.Errorf("assertion %q: %s (passed=%v)", r.Name, r.Message, r.Passed)
		}
	}
}

func TestBilling_DepositThenDebit(t *testing.T) {
	_, st, pool := setupBillingTest(t)
	ctx := context.Background()

	accountID := "test-consumer-debit"
	deposit := int64(10_000_000)
	charge := int64(1_500_000)

	st.Credit(accountID, deposit, store.LedgerStripeDeposit, "stripe:cs_test_200")
	err := st.Debit(accountID, charge, store.LedgerCharge, "req-001")
	if err != nil {
		t.Fatalf("debit: %v", err)
	}

	balance := st.GetBalance(accountID)
	expected := deposit - charge
	if balance != expected {
		t.Fatalf("expected balance %d, got %d", expected, balance)
	}

	asserter := assert.NewPostgresAccountingAsserter(pool)
	report := asserter.EvaluateAll(ctx)
	if !report.Passed {
		for _, r := range report.Results {
			t.Errorf("assertion %q: %s (passed=%v)", r.Name, r.Message, r.Passed)
		}
	}
}

func TestBilling_DebitInsufficientFunds(t *testing.T) {
	_, st, _ := setupBillingTest(t)

	accountID := "test-consumer-insufficient"
	deposit := int64(1_000_000) // $1.00
	charge := int64(5_000_000)  // $5.00

	st.Credit(accountID, deposit, store.LedgerStripeDeposit, "stripe:cs_test_300")

	err := st.Debit(accountID, charge, store.LedgerCharge, "req-002")
	if err == nil {
		t.Fatal("expected insufficient funds error")
	}

	balance := st.GetBalance(accountID)
	if balance != deposit {
		t.Fatalf("balance should remain %d after failed debit, got %d", deposit, balance)
	}
}

func TestBilling_FullInferenceCycle(t *testing.T) {
	_, st, pool := setupBillingTest(t)
	ctx := context.Background()

	consumer := "test-consumer-inference"
	provider := "test-provider-inference"
	platform := "platform"

	deposit := int64(10_000_000)
	st.Credit(consumer, deposit, store.LedgerStripeDeposit, "stripe:cs_inf_1")

	promptTokens := 100
	completionTokens := 50
	totalCost := payments.CalculateCost("default", promptTokens, completionTokens)
	providerPayout := payments.ProviderPayout(totalCost)
	platformFee := payments.PlatformFee(totalCost)

	err := st.Debit(consumer, totalCost, store.LedgerCharge, "req-inf-001")
	if err != nil {
		t.Fatalf("debit consumer: %v", err)
	}

	err = st.CreditWithdrawable(provider, providerPayout, store.LedgerPayout, "req-inf-001")
	if err != nil {
		t.Fatalf("credit provider: %v", err)
	}

	err = st.Credit(platform, platformFee, store.LedgerPlatformFee, "req-inf-001")
	if err != nil {
		t.Fatalf("credit platform: %v", err)
	}

	consumerBalance := st.GetBalance(consumer)
	if consumerBalance != deposit-totalCost {
		t.Fatalf("consumer balance: expected %d, got %d", deposit-totalCost, consumerBalance)
	}

	providerBalance := st.GetBalance(provider)
	if providerBalance != providerPayout {
		t.Fatalf("provider balance: expected %d, got %d", providerPayout, providerBalance)
	}

	providerWithdrawable := st.GetWithdrawableBalance(provider)
	if providerWithdrawable != providerPayout {
		t.Fatalf("provider withdrawable: expected %d, got %d", providerPayout, providerWithdrawable)
	}

	platformBalance := st.GetBalance(platform)
	if platformBalance != platformFee {
		t.Fatalf("platform balance: expected %d, got %d", platformFee, platformBalance)
	}

	if totalCost != providerPayout+platformFee {
		t.Fatalf("cost split invariant: totalCost(%d) != payout(%d) + fee(%d)", totalCost, providerPayout, platformFee)
	}

	asserter := assert.NewPostgresAccountingAsserter(pool)
	report := asserter.EvaluateAll(ctx)
	if !report.Passed {
		for _, r := range report.Results {
			t.Errorf("assertion %q: %s (passed=%v)", r.Name, r.Message, r.Passed)
		}
	}
}

func TestBilling_InferenceWithReferral(t *testing.T) {
	_, st, pool := setupBillingTest(t)
	ctx := context.Background()

	consumer := "test-consumer-referral"
	provider := "test-provider-referral"
	referrer := "test-referrer"
	platform := "platform"
	referralCode := "TESTCODE"

	deposit := int64(10_000_000)
	st.Credit(consumer, deposit, store.LedgerStripeDeposit, "stripe:cs_ref_1")
	st.Credit(referrer, 0, store.LedgerStripeDeposit, "stripe:cs_ref_setup")

	st.CreateReferrer(referrer, referralCode)
	st.RecordReferral(referralCode, consumer)

	totalCost := payments.CalculateCost("default", 200, 100)
	providerPayout := payments.ProviderPayout(totalCost)
	platformFee := payments.PlatformFee(totalCost)

	st.Debit(consumer, totalCost, store.LedgerCharge, "req-ref-001")
	st.CreditWithdrawable(provider, providerPayout, store.LedgerPayout, "req-ref-001")

	referralReward := platformFee * 20 / 100
	adjustedPlatformFee := platformFee - referralReward

	st.CreditWithdrawable(referrer, referralReward, store.LedgerReferralReward, "req-ref-001")
	st.Credit(platform, adjustedPlatformFee, store.LedgerPlatformFee, "req-ref-001")

	if providerPayout+referralReward+adjustedPlatformFee != totalCost {
		t.Fatalf("cost split: payout(%d) + reward(%d) + fee(%d) = %d, want %d",
			providerPayout, referralReward, adjustedPlatformFee,
			providerPayout+referralReward+adjustedPlatformFee, totalCost)
	}

	referrerWithdrawable := st.GetWithdrawableBalance(referrer)
	if referrerWithdrawable != referralReward {
		t.Fatalf("referrer withdrawable: expected %d, got %d", referralReward, referrerWithdrawable)
	}

	asserter := assert.NewPostgresAccountingAsserter(pool)
	report := asserter.EvaluateAll(ctx)
	if !report.Passed {
		for _, r := range report.Results {
			t.Errorf("assertion %q: %s (passed=%v)", r.Name, r.Message, r.Passed)
		}
	}
}

func TestBilling_MultipleInferenceRequests(t *testing.T) {
	_, st, pool := setupBillingTest(t)
	ctx := context.Background()

	consumer := "test-consumer-multi"
	provider := "test-provider-multi"
	platform := "platform"

	deposit := int64(50_000_000) // $50.00
	st.Credit(consumer, deposit, store.LedgerStripeDeposit, "stripe:cs_multi_1")

	totalCharged := int64(0)
	for i := 0; i < 10; i++ {
		cost := payments.CalculateCost("default", 100+i*10, 50+i*5)
		payout := payments.ProviderPayout(cost)
		fee := payments.PlatformFee(cost)

		err := st.Debit(consumer, cost, store.LedgerCharge, fmt.Sprintf("req-multi-%03d", i))
		if err != nil {
			t.Fatalf("debit request %d: %v", i, err)
		}
		st.CreditWithdrawable(provider, payout, store.LedgerPayout, fmt.Sprintf("req-multi-%03d", i))
		st.Credit(platform, fee, store.LedgerPlatformFee, fmt.Sprintf("req-multi-%03d", i))

		totalCharged += cost
	}

	consumerBalance := st.GetBalance(consumer)
	if consumerBalance != deposit-totalCharged {
		t.Fatalf("consumer balance: expected %d, got %d", deposit-totalCharged, consumerBalance)
	}

	providerBalance := st.GetBalance(provider)
	if providerBalance <= 0 {
		t.Fatalf("provider should have earnings, got %d", providerBalance)
	}

	asserter := assert.NewPostgresAccountingAsserter(pool)
	report := asserter.EvaluateAll(ctx)
	if !report.Passed {
		for _, r := range report.Results {
			t.Errorf("assertion %q: %s (passed=%v)", r.Name, r.Message, r.Passed)
		}
	}
}

func TestBilling_ReservationAndRefund(t *testing.T) {
	_, st, pool := setupBillingTest(t)
	ctx := context.Background()

	consumer := "test-consumer-reserve"
	provider := "test-provider-reserve"
	platform := "platform"

	deposit := int64(10_000_000)
	st.Credit(consumer, deposit, store.LedgerStripeDeposit, "stripe:cs_res_1")

	reserved := int64(3_000_000)
	actual := int64(1_200_000)
	refund := reserved - actual

	st.Debit(consumer, reserved, store.LedgerCharge, "req-res-001")

	payout := payments.ProviderPayout(actual)
	fee := payments.PlatformFee(actual)

	st.Credit(consumer, refund, store.LedgerDeposit, "refund:req-res-001")
	st.CreditWithdrawable(provider, payout, store.LedgerPayout, "req-res-001")
	st.Credit(platform, fee, store.LedgerPlatformFee, "req-res-001")

	consumerBalance := st.GetBalance(consumer)
	expectedConsumer := deposit - reserved + refund
	if consumerBalance != expectedConsumer {
		t.Fatalf("consumer balance: expected %d, got %d", expectedConsumer, consumerBalance)
	}

	asserter := assert.NewPostgresAccountingAsserter(pool)
	report := asserter.EvaluateAll(ctx)
	if !report.Passed {
		for _, r := range report.Results {
			t.Errorf("assertion %q: %s (passed=%v)", r.Name, r.Message, r.Passed)
		}
	}
}

func TestBilling_WithdrawalDebitsWithdrawable(t *testing.T) {
	_, st, pool := setupBillingTest(t)
	ctx := context.Background()

	provider := "test-provider-withdraw"

	earning := int64(5_000_000)
	st.CreditWithdrawable(provider, earning, store.LedgerPayout, "req-wd-001")

	withdrawable := st.GetWithdrawableBalance(provider)
	if withdrawable != earning {
		t.Fatalf("withdrawable: expected %d, got %d", earning, withdrawable)
	}

	withdrawAmount := int64(3_000_000)
	err := st.DebitWithdrawable(provider, withdrawAmount, store.LedgerStripePayout, "withdrawal-wd-001")
	if err != nil {
		t.Fatalf("debit withdrawable: %v", err)
	}

	balance := st.GetBalance(provider)
	if balance != earning-withdrawAmount {
		t.Fatalf("balance after withdrawal: expected %d, got %d", earning-withdrawAmount, balance)
	}

	remainingWithdrawable := st.GetWithdrawableBalance(provider)
	if remainingWithdrawable != earning-withdrawAmount {
		t.Fatalf("withdrawable after withdrawal: expected %d, got %d", earning-withdrawAmount, remainingWithdrawable)
	}

	asserter := assert.NewPostgresAccountingAsserter(pool)
	report := asserter.EvaluateAll(ctx)
	if !report.Passed {
		for _, r := range report.Results {
			t.Errorf("assertion %q: %s (passed=%v)", r.Name, r.Message, r.Passed)
		}
	}
}

func TestBilling_WithdrawalExceedsWithdrawable(t *testing.T) {
	_, st, _ := setupBillingTest(t)

	provider := "test-provider-overdraw"

	earning := int64(2_000_000)
	st.CreditWithdrawable(provider, earning, store.LedgerPayout, "req-od-001")
	st.Credit(provider, 5_000_000, store.LedgerInviteCredit, "invite-od-001")

	withdrawAttempt := int64(4_000_000)
	err := st.DebitWithdrawable(provider, withdrawAttempt, store.LedgerStripePayout, "withdrawal-od-001")
	if err == nil {
		t.Fatal("expected withdrawal to fail — withdrawable should not include invite credits")
	}

	withdrawable := st.GetWithdrawableBalance(provider)
	if withdrawable != earning {
		t.Fatalf("withdrawable should be unchanged at %d, got %d", earning, withdrawable)
	}
}

func TestBilling_DuplicateDepositIdempotent(t *testing.T) {
	_, st, pool := setupBillingTest(t)
	ctx := context.Background()

	accountID := "test-consumer-idempotent"
	amount := int64(5_000_000)
	reference := "stripe:cs_idempotent_1"

	st.Credit(accountID, amount, store.LedgerStripeDeposit, reference)
	balanceAfterFirst := st.GetBalance(accountID)

	st.Credit(accountID, amount, store.LedgerStripeDeposit, reference)
	balanceAfterSecond := st.GetBalance(accountID)

	if balanceAfterFirst != balanceAfterSecond {
		t.Fatalf("duplicate credit changed balance: first=%d second=%d", balanceAfterFirst, balanceAfterSecond)
	}

	asserter := assert.NewPostgresAccountingAsserter(pool)
	report := asserter.EvaluateAll(ctx)
	if !report.Passed {
		for _, r := range report.Results {
			t.Errorf("assertion %q: %s (passed=%v)", r.Name, r.Message, r.Passed)
		}
	}
}

func TestBilling_LedgerContinuity(t *testing.T) {
	_, st, pool := setupBillingTest(t)
	ctx := context.Background()

	accountID := "test-consumer-continuity"

	st.Credit(accountID, 10_000_000, store.LedgerStripeDeposit, "stripe:cs_cont_1")
	st.Debit(accountID, 1_000_000, store.LedgerCharge, "req-cont-001")
	st.Debit(accountID, 2_000_000, store.LedgerCharge, "req-cont-002")
	st.Credit(accountID, 500_000, store.LedgerDeposit, "refund:req-cont-002")

	asserter := assert.NewPostgresAccountingAsserter(pool)
	report := asserter.EvaluateAll(ctx)
	if !report.Passed {
		for _, r := range report.Results {
			t.Errorf("assertion %q: %s (passed=%v)", r.Name, r.Message, r.Passed)
		}
	}

	finalBalance := st.GetBalance(accountID)
	expected := int64(10_000_000 - 1_000_000 - 2_000_000 + 500_000)
	if finalBalance != expected {
		t.Fatalf("final balance: expected %d, got %d", expected, finalBalance)
	}
}
