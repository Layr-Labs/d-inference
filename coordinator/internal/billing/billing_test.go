package billing

import (
	"log/slog"
	"os"
	"testing"

	"github.com/dginf/coordinator/internal/payments"
	"github.com/dginf/coordinator/internal/store"
)

func newTestService(t *testing.T) (*Service, store.Store) {
	t.Helper()
	st := store.NewMemory("")
	ledger := payments.NewLedger(st)
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))

	cfg := Config{
		ReferralSharePercent: 20,
	}
	svc := NewService(st, ledger, logger, cfg)
	return svc, st
}

// --- Referral System Tests ---

func TestReferralRegister(t *testing.T) {
	svc, _ := newTestService(t)

	referrer, err := svc.Referral().Register("consumer-123")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if referrer.Code == "" {
		t.Fatal("expected non-empty referral code")
	}
	if referrer.AccountID != "consumer-123" {
		t.Fatalf("expected account consumer-123, got %s", referrer.AccountID)
	}

	// Registering again should return the same code
	again, err := svc.Referral().Register("consumer-123")
	if err != nil {
		t.Fatalf("re-register: %v", err)
	}
	if again.Code != referrer.Code {
		t.Fatalf("expected same code %s, got %s", referrer.Code, again.Code)
	}
}

func TestReferralApply(t *testing.T) {
	svc, st := newTestService(t)

	// Create referrer
	referrer, err := svc.Referral().Register("referrer-account")
	if err != nil {
		t.Fatalf("register: %v", err)
	}

	// Apply referral code
	err = svc.Referral().Apply("consumer-account", referrer.Code)
	if err != nil {
		t.Fatalf("apply: %v", err)
	}

	// Verify the referral was recorded
	code, err := st.GetReferrerForAccount("consumer-account")
	if err != nil {
		t.Fatalf("get referrer: %v", err)
	}
	if code != referrer.Code {
		t.Fatalf("expected referrer code %s, got %s", referrer.Code, code)
	}
}

func TestReferralSelfReferralBlocked(t *testing.T) {
	svc, _ := newTestService(t)

	referrer, _ := svc.Referral().Register("same-account")

	err := svc.Referral().Apply("same-account", referrer.Code)
	if err == nil {
		t.Fatal("expected self-referral to be blocked")
	}
}

func TestReferralDoubleApplyBlocked(t *testing.T) {
	svc, _ := newTestService(t)

	ref1, _ := svc.Referral().Register("referrer-1")
	ref2, _ := svc.Referral().Register("referrer-2")

	_ = svc.Referral().Apply("consumer", ref1.Code)
	err := svc.Referral().Apply("consumer", ref2.Code)
	if err == nil {
		t.Fatal("expected double-apply to be blocked")
	}
}

func TestReferralInvalidCode(t *testing.T) {
	svc, _ := newTestService(t)

	err := svc.Referral().Apply("consumer", "INVALID-CODE")
	if err == nil {
		t.Fatal("expected error for invalid code")
	}
}

func TestReferralRewardDistribution(t *testing.T) {
	svc, st := newTestService(t)

	// Setup: referrer refers a consumer
	referrer, _ := svc.Referral().Register("referrer-wallet")
	_ = svc.Referral().Apply("consumer-key", referrer.Code)

	// Simulate inference billing: platform fee of 100 micro-USD
	platformFee := int64(100)
	adjustedFee := svc.Referral().DistributeReferralReward("consumer-key", platformFee, "job-001")

	// Referrer should get 20% of platform fee = 20 micro-USD
	expectedReferralReward := int64(20)
	expectedPlatformFee := platformFee - expectedReferralReward

	if adjustedFee != expectedPlatformFee {
		t.Fatalf("expected adjusted platform fee %d, got %d", expectedPlatformFee, adjustedFee)
	}

	// Check referrer's balance was credited
	referrerBalance := st.GetBalance("referrer-wallet")
	if referrerBalance != expectedReferralReward {
		t.Fatalf("expected referrer balance %d, got %d", expectedReferralReward, referrerBalance)
	}
}

func TestReferralRewardNoReferrer(t *testing.T) {
	svc, _ := newTestService(t)

	// Consumer without referrer — platform fee should be unchanged
	platformFee := int64(100)
	adjustedFee := svc.Referral().DistributeReferralReward("consumer-no-ref", platformFee, "job-002")

	if adjustedFee != platformFee {
		t.Fatalf("expected unchanged platform fee %d, got %d", platformFee, adjustedFee)
	}
}

func TestReferralStats(t *testing.T) {
	svc, _ := newTestService(t)

	referrer, _ := svc.Referral().Register("referrer-account")
	_ = svc.Referral().Apply("consumer-1", referrer.Code)
	_ = svc.Referral().Apply("consumer-2", referrer.Code)

	// Simulate some rewards
	_ = svc.Referral().DistributeReferralReward("consumer-1", 100, "job-1")
	_ = svc.Referral().DistributeReferralReward("consumer-2", 200, "job-2")

	stats, err := svc.Referral().Stats("referrer-account")
	if err != nil {
		t.Fatalf("stats: %v", err)
	}

	if stats.TotalReferred != 2 {
		t.Fatalf("expected 2 referred, got %d", stats.TotalReferred)
	}
	if stats.Code != referrer.Code {
		t.Fatalf("expected code %s, got %s", referrer.Code, stats.Code)
	}
	// Rewards: 20% of 100 + 20% of 200 = 20 + 40 = 60
	if stats.TotalRewardsMicroUSD != 60 {
		t.Fatalf("expected 60 micro-USD in rewards, got %d", stats.TotalRewardsMicroUSD)
	}
}

// --- Billing Service Tests ---

func TestSupportedMethodsEmpty(t *testing.T) {
	svc, _ := newTestService(t)

	methods := svc.SupportedMethods()
	// No payment methods configured, should be empty
	if len(methods) != 0 {
		t.Fatalf("expected 0 methods, got %d", len(methods))
	}
}

func TestProcessedTxTracking(t *testing.T) {
	svc, _ := newTestService(t)

	txHash := "0xabc123"
	if svc.CheckProcessedTx(txHash) {
		t.Fatal("expected tx not processed yet")
	}

	svc.MarkProcessedTx(txHash)
	if !svc.CheckProcessedTx(txHash) {
		t.Fatal("expected tx to be marked as processed")
	}
}

func TestCreditDeposit(t *testing.T) {
	svc, st := newTestService(t)

	err := svc.CreditDeposit("consumer-1", 1_000_000, store.LedgerDeposit, "test-deposit")
	if err != nil {
		t.Fatalf("credit: %v", err)
	}

	balance := st.GetBalance("consumer-1")
	if balance != 1_000_000 {
		t.Fatalf("expected balance 1000000, got %d", balance)
	}
}

func TestDepositAddressesEmpty(t *testing.T) {
	svc, _ := newTestService(t)

	addrs := svc.DepositAddresses()
	if addrs.Solana != "" {
		t.Fatalf("expected empty Solana address, got %s", addrs.Solana)
	}
}

// --- Store Integration Tests ---

func TestBillingSessionLifecycle(t *testing.T) {
	st := store.NewMemory("")

	session := &store.BillingSession{
		ID:             "session-1",
		AccountID:      "consumer-1",
		PaymentMethod:  "stripe",
		AmountMicroUSD: 5_000_000,
		ExternalID:     "cs_test_123",
		Status:         "pending",
	}

	// Create
	if err := st.CreateBillingSession(session); err != nil {
		t.Fatalf("create: %v", err)
	}

	// Get
	got, err := st.GetBillingSession("session-1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.AccountID != "consumer-1" {
		t.Fatalf("expected consumer-1, got %s", got.AccountID)
	}
	if got.Status != "pending" {
		t.Fatalf("expected pending, got %s", got.Status)
	}

	// Complete
	if err := st.CompleteBillingSession("session-1"); err != nil {
		t.Fatalf("complete: %v", err)
	}

	got, _ = st.GetBillingSession("session-1")
	if got.Status != "completed" {
		t.Fatalf("expected completed, got %s", got.Status)
	}
	if got.CompletedAt == nil {
		t.Fatal("expected non-nil CompletedAt")
	}

	// Double-complete should error
	if err := st.CompleteBillingSession("session-1"); err == nil {
		t.Fatal("expected error on double-complete")
	}
}

func TestReferrerStoreLifecycle(t *testing.T) {
	st := store.NewMemory("")

	// Create referrer
	if err := st.CreateReferrer("account-1", "DGINF-ABC123"); err != nil {
		t.Fatalf("create: %v", err)
	}

	// Get by code
	ref, err := st.GetReferrerByCode("DGINF-ABC123")
	if err != nil {
		t.Fatalf("get by code: %v", err)
	}
	if ref.AccountID != "account-1" {
		t.Fatalf("expected account-1, got %s", ref.AccountID)
	}

	// Get by account
	ref, err = st.GetReferrerByAccount("account-1")
	if err != nil {
		t.Fatalf("get by account: %v", err)
	}
	if ref.Code != "DGINF-ABC123" {
		t.Fatalf("expected DGINF-ABC123, got %s", ref.Code)
	}

	// Duplicate code should error
	if err := st.CreateReferrer("account-2", "DGINF-ABC123"); err == nil {
		t.Fatal("expected error on duplicate code")
	}

	// Duplicate account should error
	if err := st.CreateReferrer("account-1", "DGINF-XYZ789"); err == nil {
		t.Fatal("expected error on duplicate account")
	}
}

func TestReferralRecording(t *testing.T) {
	st := store.NewMemory("")

	_ = st.CreateReferrer("referrer-1", "CODE1")

	// Record referral
	if err := st.RecordReferral("CODE1", "consumer-1"); err != nil {
		t.Fatalf("record: %v", err)
	}

	// Get referrer for consumer
	code, err := st.GetReferrerForAccount("consumer-1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if code != "CODE1" {
		t.Fatalf("expected CODE1, got %s", code)
	}

	// Non-referred account
	code, _ = st.GetReferrerForAccount("consumer-2")
	if code != "" {
		t.Fatalf("expected empty, got %s", code)
	}

	// Duplicate referral should error
	if err := st.RecordReferral("CODE1", "consumer-1"); err == nil {
		t.Fatal("expected error on duplicate referral")
	}

	// Invalid code should error
	if err := st.RecordReferral("INVALID", "consumer-2"); err == nil {
		t.Fatal("expected error on invalid code")
	}
}

func TestReferralStatsStore(t *testing.T) {
	st := store.NewMemory("")

	_ = st.CreateReferrer("referrer-1", "CODE1")
	_ = st.RecordReferral("CODE1", "consumer-1")
	_ = st.RecordReferral("CODE1", "consumer-2")

	// Credit some referral rewards
	_ = st.Credit("referrer-1", 100, store.LedgerReferralReward, "job-1")
	_ = st.Credit("referrer-1", 200, store.LedgerReferralReward, "job-2")

	stats, err := st.GetReferralStats("CODE1")
	if err != nil {
		t.Fatalf("stats: %v", err)
	}
	if stats.TotalReferred != 2 {
		t.Fatalf("expected 2, got %d", stats.TotalReferred)
	}
	if stats.TotalRewardsMicroUSD != 300 {
		t.Fatalf("expected 300, got %d", stats.TotalRewardsMicroUSD)
	}
}

// --- Stripe Webhook Signature Tests ---

func TestStripeWebhookNoSecret(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	proc := NewStripeProcessor("sk_test_123", "", "http://success", "http://cancel", logger)

	payload := []byte(`{"type":"checkout.session.completed","data":{"object":{"id":"cs_123","payment_status":"paid","amount_total":1000}}}`)

	event, err := proc.VerifyWebhookSignature(payload, "")
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if event.Type != "checkout.session.completed" {
		t.Fatalf("expected checkout.session.completed, got %s", event.Type)
	}
}

func TestStripeWebhookInvalidSignature(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	proc := NewStripeProcessor("sk_test_123", "whsec_test", "http://success", "http://cancel", logger)

	payload := []byte(`{"type":"test"}`)

	_, err := proc.VerifyWebhookSignature(payload, "t=1234,v1=invalid")
	if err == nil {
		t.Fatal("expected error for invalid signature")
	}
}

