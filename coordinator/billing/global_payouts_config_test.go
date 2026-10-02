package billing

import (
	"testing"
)

func TestGlobalPayoutConfigDoesNotRequireConnect(t *testing.T) {
	cfg := Config{StripeGlobalPayoutsEnabled: true, StripeGlobalPayoutsFinancialAccount: "fa_test", StripeGlobalPayoutsSecretKey: "rk_test_global"}
	if err := cfg.Check(); err != nil {
		t.Fatalf("dedicated-only configuration rejected: %v", err)
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

func TestGlobalOnlyConfigRequiresDedicatedKeysAndRetainedWebhookAccess(t *testing.T) {
	t.Setenv("EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ONLY", "true")
	t.Setenv("EIGENINFERENCE_STRIPE_SECRET_KEY", "rk_checkout")
	t.Setenv("EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_SECRET_KEY", "")
	t.Setenv("EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_FINANCIAL_ACCOUNT", "fa_gp")
	t.Setenv("EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_WEBHOOK_SECRET", "whsec_gp")
	if err := ReadConfig().Check(); err == nil {
		t.Fatal("cutover fell back to the Checkout key")
	}
	t.Setenv("EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_SECRET_KEY", "rk_gp")
	t.Setenv("EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET", "whsec_old")
	t.Setenv("EIGENINFERENCE_STRIPE_CONNECT_SECRET_KEY", "")
	if err := ReadConfig().Check(); err == nil {
		t.Fatal("retained webhook lost its legacy API key")
	}
	t.Setenv("EIGENINFERENCE_STRIPE_CONNECT_SECRET_KEY", "rk_old")
	if err := ReadConfig().Check(); err != nil {
		t.Fatal(err)
	}
	t.Setenv("EIGENINFERENCE_STRIPE_GLOBAL_PAYOUTS_ONLY", "tru")
	if err := ReadConfig().Check(); err == nil {
		t.Fatal("malformed cutover silently enabled Connect")
	}
}
