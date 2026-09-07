package billing

import (
	"strings"
	"testing"
)

func TestGlobalPayoutConfigRequiresBaseStripeKey(t *testing.T) {
	cfg := Config{StripeGlobalPayoutsEnabled: true, StripeGlobalPayoutsFinancialAccount: "fa_test", StripeGlobalPayoutsSecretKey: "rk_test_global"}
	if err := cfg.Check(); err == nil || !strings.Contains(err.Error(), "STRIPE_SECRET_KEY") {
		t.Fatalf("dedicated-only configuration was accepted: %v", err)
	}
	cfg.StripeSecretKey = "rk_test_connect"
	if err := cfg.Check(); err != nil {
		t.Fatal(err)
	}
	cfg.StripeGlobalPayoutsFinancialAccount = ""
	if err := cfg.Check(); err == nil {
		t.Fatal("missing funding account accepted")
	}
	cfg.StripeGlobalPayoutsEnabled = false
	if err := cfg.Check(); err != nil {
		t.Fatal("staging disabled configuration should be allowed:", err)
	}
}
