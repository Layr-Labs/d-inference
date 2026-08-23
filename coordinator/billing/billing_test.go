package billing

import (
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func newTestService(t *testing.T) *Service {
	t.Helper()
	st := store.NewMemory(store.Config{})
	ledger := payments.NewLedger(st)
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))

	cfg := Config{
		ReferralSharePercent: 20,
	}
	return NewService(st, ledger, logger, cfg)
}

// --- Referral System Tests ---

func TestReferralRegister(t *testing.T) {
	svc := newTestService(t)

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
	svc := newTestService(t)

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
	svc := newTestService(t)

	referrer, err := svc.Referral().Register("referrer-account", "REF1")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if err := svc.Referral().Apply("consumer-account", referrer.Code); err != nil {
		t.Fatalf("apply: %v", err)
	}
	if err := svc.Referral().Apply("consumer-account", referrer.Code); err == nil {
		t.Fatal("expected applying a second referral to fail")
	}
}

func TestReferralSelfReferralBlocked(t *testing.T) {
	svc := newTestService(t)
	referrer, err := svc.Referral().Register("same-account", "SELF")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if err := svc.Referral().Apply("same-account", referrer.Code); err == nil {
		t.Fatal("expected self-referral to be blocked")
	}
}

func TestReferralDoubleApplyBlocked(t *testing.T) {
	svc := newTestService(t)
	ref1, err := svc.Referral().Register("referrer-1", "CODE-A")
	if err != nil {
		t.Fatalf("register first referrer: %v", err)
	}
	ref2, err := svc.Referral().Register("referrer-2", "CODE-B")
	if err != nil {
		t.Fatalf("register second referrer: %v", err)
	}
	if err := svc.Referral().Apply("consumer", ref1.Code); err != nil {
		t.Fatalf("apply first referral: %v", err)
	}
	if err := svc.Referral().Apply("consumer", ref2.Code); err == nil {
		t.Fatal("expected double-apply to be blocked")
	}
}

func TestReferralInvalidCode(t *testing.T) {
	svc := newTestService(t)
	err := svc.Referral().Apply("consumer", "INVALID-CODE")
	if err == nil {
		t.Fatal("expected error for invalid code")
	}
}

func TestReferralRewardDistribution(t *testing.T) {
	svc := newTestService(t)

	referrer, err := svc.Referral().Register("referrer-wallet", "EARN")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if err := svc.Referral().Apply("consumer-key", referrer.Code); err != nil {
		t.Fatalf("apply: %v", err)
	}

	const platformFee = int64(100)
	if got := svc.Referral().DistributeReferralReward("consumer-key", platformFee, "job-001"); got != 80 {
		t.Fatalf("expected adjusted platform fee 80, got %d", got)
	}
	stats, err := svc.Referral().Stats("referrer-wallet")
	if err != nil {
		t.Fatalf("stats: %v", err)
	}
	if stats.TotalRewardsMicroUSD != 20 {
		t.Fatalf("expected referral rewards 20, got %d", stats.TotalRewardsMicroUSD)
	}
}

func TestReferralRewardNoReferrer(t *testing.T) {
	svc := newTestService(t)
	platformFee := int64(100)
	adjustedFee := svc.Referral().DistributeReferralReward("consumer-no-ref", platformFee, "job-002")
	if adjustedFee != platformFee {
		t.Fatalf("expected unchanged platform fee %d, got %d", platformFee, adjustedFee)
	}
}

func TestReferralStats(t *testing.T) {
	svc := newTestService(t)

	referrer, err := svc.Referral().Register("referrer-account", "STATS")
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	for _, consumer := range []string{"consumer-1", "consumer-2"} {
		if err := svc.Referral().Apply(consumer, referrer.Code); err != nil {
			t.Fatalf("apply %s: %v", consumer, err)
		}
	}
	svc.Referral().DistributeReferralReward("consumer-1", 100, "job-1")
	svc.Referral().DistributeReferralReward("consumer-2", 200, "job-2")

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
	svc := newTestService(t)
	methods := svc.SupportedMethods()
	if len(methods) != 0 {
		t.Fatalf("expected 0 methods, got %d", len(methods))
	}
}

func TestCreditDeposit(t *testing.T) {
	svc := newTestService(t)
	if err := svc.CreditDeposit("consumer-1", 1_000_000, store.LedgerDeposit, "test-deposit"); err != nil {
		t.Fatalf("credit: %v", err)
	}
	if balance := svc.Ledger().Balance("consumer-1"); balance != 1_000_000 {
		t.Fatalf("expected balance 1000000, got %d", balance)
	}
}

func TestIsExternalIDProcessed(t *testing.T) {
	svc := newTestService(t)
	if svc.IsExternalIDProcessed("tx-abc") {
		t.Fatal("expected unknown external ID to be unprocessed")
	}
	if err := svc.Store().CreateBillingSession(&store.BillingSession{
		ID:            "session-1",
		AccountID:     "consumer-1",
		PaymentMethod: string(MethodStripe),
		ExternalID:    "tx-abc",
		Status:        "pending",
	}); err != nil {
		t.Fatalf("create billing session fixture: %v", err)
	}
	if svc.IsExternalIDProcessed("tx-abc") {
		t.Fatal("pending session should not count as processed")
	}
	if err := svc.Store().CompleteBillingSession("session-1"); err != nil {
		t.Fatalf("complete billing session fixture: %v", err)
	}
	if !svc.IsExternalIDProcessed("tx-abc") {
		t.Fatal("completed session should count as processed")
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
