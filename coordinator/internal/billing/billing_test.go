package billing

import (
	"log/slog"
	"os"
	"testing"

	"github.com/darkbloom/coordinator/internal/payments"
	"github.com/darkbloom/coordinator/internal/store"
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

	referrer, err := svc.Referral().Register("consumer-123", "ALPHA")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if referrer.Code != "ALPHA" {
		t.Fatalf("expected ALPHA, got %s", referrer.Code)
	}
	if referrer.AccountID != "consumer-123" {
		t.Fatalf("expected account consumer-123, got %s", referrer.AccountID)
	}

	// Registering again should return the existing code (ignores new code)
	again, err := svc.Referral().Register("consumer-123", "BETA")
	if err != nil {
		t.Fatalf("re-register: %v", err)
	}
	if again.Code != "ALPHA" {
		t.Fatalf("expected same code ALPHA, got %s", again.Code)
	}
}

func TestReferralCodeValidation(t *testing.T) {
	svc, _ := newTestService(t)

	// Too short
	if _, err := svc.Referral().Register("a1", "AB"); err == nil {
		t.Fatal("expected error for 2-char code")
	}
	// Too long
	if _, err := svc.Referral().Register("a2", "ABCDEFGHIJKLMNOPQRSTU"); err == nil {
		t.Fatal("expected error for 21-char code")
	}
	// Invalid chars
	if _, err := svc.Referral().Register("a3", "NO SPACES"); err == nil {
		t.Fatal("expected error for spaces")
	}
	// Leading hyphen
	if _, err := svc.Referral().Register("a4", "-BAD"); err == nil {
		t.Fatal("expected error for leading hyphen")
	}
	// Valid with hyphen
	ref, err := svc.Referral().Register("a5", "my-code")
	if err != nil {
		t.Fatalf("valid code with hyphen: %v", err)
	}
	if ref.Code != "MY-CODE" {
		t.Fatalf("expected MY-CODE, got %s", ref.Code)
	}
	// Duplicate code
	if _, err := svc.Referral().Register("a6", "MY-CODE"); err == nil {
		t.Fatal("expected error for duplicate code")
	}
}

func TestReferralApply(t *testing.T) {
	svc, st := newTestService(t)

	referrer, err := svc.Referral().Register("referrer-account", "REF1")
	if err != nil {
		t.Fatalf("register: %v", err)
	}

	err = svc.Referral().Apply("consumer-account", referrer.Code)
	if err != nil {
		t.Fatalf("apply: %v", err)
	}

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
	referrer, _ := svc.Referral().Register("same-account", "SELF")
	err := svc.Referral().Apply("same-account", referrer.Code)
	if err == nil {
		t.Fatal("expected self-referral to be blocked")
	}
}

func TestReferralDoubleApplyBlocked(t *testing.T) {
	svc, _ := newTestService(t)
	ref1, _ := svc.Referral().Register("referrer-1", "CODE-A")
	ref2, _ := svc.Referral().Register("referrer-2", "CODE-B")
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

	referrer, _ := svc.Referral().Register("referrer-wallet", "EARN")
	_ = svc.Referral().Apply("consumer-key", referrer.Code)

	platformFee := int64(100)
	adjustedFee := svc.Referral().DistributeReferralReward("consumer-key", platformFee, "job-001")

	expectedReferralReward := int64(20)
	expectedPlatformFee := platformFee - expectedReferralReward

	if adjustedFee != expectedPlatformFee {
		t.Fatalf("expected adjusted platform fee %d, got %d", expectedPlatformFee, adjustedFee)
	}

	referrerBalance := st.GetBalance("referrer-wallet")
	if referrerBalance != expectedReferralReward {
		t.Fatalf("expected referrer balance %d, got %d", expectedReferralReward, referrerBalance)
	}
}

func TestReferralRewardNoReferrer(t *testing.T) {
	svc, _ := newTestService(t)
	platformFee := int64(100)
	adjustedFee := svc.Referral().DistributeReferralReward("consumer-no-ref", platformFee, "job-002")
	if adjustedFee != platformFee {
		t.Fatalf("expected unchanged platform fee %d, got %d", platformFee, adjustedFee)
	}
}

func TestReferralStats(t *testing.T) {
	svc, _ := newTestService(t)

	referrer, _ := svc.Referral().Register("referrer-account", "STATS")
	_ = svc.Referral().Apply("consumer-1", referrer.Code)
	_ = svc.Referral().Apply("consumer-2", referrer.Code)
	_ = svc.Referral().DistributeReferralReward("consumer-1", 100, "job-1")
	_ = svc.Referral().DistributeReferralReward("consumer-2", 200, "job-2")

	stats, err := svc.Referral().Stats("referrer-account")
	if err != nil {
		t.Fatalf("stats: %v", err)
	}
	if stats.TotalReferred != 2 {
		t.Fatalf("expected 2 referred, got %d", stats.TotalReferred)
	}
	if stats.TotalRewardsMicroUSD != 60 {
		t.Fatalf("expected 60 micro-USD in rewards, got %d", stats.TotalRewardsMicroUSD)
	}
}

// --- Billing Service Tests ---

func TestSupportedMethodsEmpty(t *testing.T) {
	svc, _ := newTestService(t)
	methods := svc.SupportedMethods()
	if len(methods) != 0 {
		t.Fatalf("expected 0 methods, got %d", len(methods))
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

func TestIsExternalIDProcessed(t *testing.T) {
	svc, st := newTestService(t)

	if svc.IsExternalIDProcessed("tx-abc") {
		t.Fatal("expected not processed")
	}

	_ = st.CreateBillingSession(&store.BillingSession{
		ID:            "session-1",
		AccountID:     "consumer-1",
		PaymentMethod: "solana",
		ExternalID:    "tx-abc",
		Status:        "pending",
	})

	if svc.IsExternalIDProcessed("tx-abc") {
		t.Fatal("pending session should not count as processed")
	}

	_ = st.CompleteBillingSession("session-1")

	if !svc.IsExternalIDProcessed("tx-abc") {
		t.Fatal("completed session should be processed")
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

	if err := st.CreateBillingSession(session); err != nil {
		t.Fatalf("create: %v", err)
	}

	got, err := st.GetBillingSession("session-1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.AccountID != "consumer-1" || got.Status != "pending" {
		t.Fatalf("unexpected: %+v", got)
	}

	if err := st.CompleteBillingSession("session-1"); err != nil {
		t.Fatalf("complete: %v", err)
	}

	got, _ = st.GetBillingSession("session-1")
	if got.Status != "completed" || got.CompletedAt == nil {
		t.Fatalf("expected completed with timestamp, got %+v", got)
	}

	if err := st.CompleteBillingSession("session-1"); err == nil {
		t.Fatal("expected error on double-complete")
	}
}

func TestReferrerStoreLifecycle(t *testing.T) {
	st := store.NewMemory("")

	if err := st.CreateReferrer("account-1", "EIGEN-ABC123"); err != nil {
		t.Fatalf("create: %v", err)
	}

	ref, err := st.GetReferrerByCode("EIGEN-ABC123")
	if err != nil {
		t.Fatalf("get by code: %v", err)
	}
	if ref.AccountID != "account-1" {
		t.Fatalf("expected account-1, got %s", ref.AccountID)
	}

	if err := st.CreateReferrer("account-2", "EIGEN-ABC123"); err == nil {
		t.Fatal("expected error on duplicate code")
	}
	if err := st.CreateReferrer("account-1", "EIGEN-XYZ789"); err == nil {
		t.Fatal("expected error on duplicate account")
	}
}

func TestReferralRecording(t *testing.T) {
	st := store.NewMemory("")
	_ = st.CreateReferrer("referrer-1", "CODE1")

	if err := st.RecordReferral("CODE1", "consumer-1"); err != nil {
		t.Fatalf("record: %v", err)
	}

	code, err := st.GetReferrerForAccount("consumer-1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if code != "CODE1" {
		t.Fatalf("expected CODE1, got %s", code)
	}

	if err := st.RecordReferral("CODE1", "consumer-1"); err == nil {
		t.Fatal("expected error on duplicate referral")
	}
	if err := st.RecordReferral("INVALID", "consumer-2"); err == nil {
		t.Fatal("expected error on invalid code")
	}
}

func TestReferralStatsStore(t *testing.T) {
	st := store.NewMemory("")
	_ = st.CreateReferrer("referrer-1", "CODE1")
	_ = st.RecordReferral("CODE1", "consumer-1")
	_ = st.RecordReferral("CODE1", "consumer-2")
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
	_, err := proc.VerifyWebhookSignature(payload, "")
	if err == nil {
		t.Fatal("expected error when webhook secret is empty")
	}
}

func TestStripeWebhookInvalidSignature(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	proc := NewStripeProcessor("sk_test_123", "whsec_test", "http://success", "http://cancel", logger)

	_, err := proc.VerifyWebhookSignature([]byte(`{"type":"test"}`), "t=1234,v1=invalid")
	if err == nil {
		t.Fatal("expected error for invalid signature")
	}
}

// --- User Store Tests ---

func TestUserLifecycle(t *testing.T) {
	st := store.NewMemory("")

	user := &store.User{
		AccountID:           "acct-123",
		PrivyUserID:         "did:privy:abc",
		SolanaWalletAddress: "SoLaNaAdDr123",
		SolanaWalletID:      "wallet-xyz",
	}

	if err := st.CreateUser(user); err != nil {
		t.Fatalf("create: %v", err)
	}

	got, err := st.GetUserByPrivyID("did:privy:abc")
	if err != nil {
		t.Fatalf("get by privy: %v", err)
	}
	if got.AccountID != "acct-123" || got.SolanaWalletAddress != "SoLaNaAdDr123" {
		t.Fatalf("unexpected: %+v", got)
	}

	got, err = st.GetUserByAccountID("acct-123")
	if err != nil {
		t.Fatalf("get by account: %v", err)
	}
	if got.PrivyUserID != "did:privy:abc" {
		t.Fatalf("expected did:privy:abc, got %s", got.PrivyUserID)
	}

	// Duplicate Privy ID
	if err := st.CreateUser(&store.User{AccountID: "acct-456", PrivyUserID: "did:privy:abc"}); err == nil {
		t.Fatal("expected error on duplicate Privy ID")
	}

	// Not found
	if _, err := st.GetUserByPrivyID("did:privy:nonexistent"); err == nil {
		t.Fatal("expected error for nonexistent user")
	}
}
