package billing

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/env"
)

func clearBillingEnv(t *testing.T) {
	t.Helper()

	keys := []string{
		"MNEMONIC",
		env.EnvPrefix + "_MNEMONIC",
		env.EnvPrefix + "_SOLANA_MNEMONIC",
		env.EnvPrefix + "_STRIPE_SECRET_KEY",
		env.EnvPrefix + "_STRIPE_WEBHOOK_SECRET",
		env.EnvPrefix + "_STRIPE_SUCCESS_URL",
		env.EnvPrefix + "_STRIPE_CANCEL_URL",
		env.EnvPrefix + "_STRIPE_CONNECT_WEBHOOK_SECRET",
		env.EnvPrefix + "_STRIPE_CONNECT_COUNTRY",
		env.EnvPrefix + "_STRIPE_CONNECT_RETURN_URL",
		env.EnvPrefix + "_STRIPE_CONNECT_REFRESH_URL",
		env.EnvPrefix + "_BILLING_MOCK",
		env.EnvPrefix + "_REFERRAL_SHARE_PCT",
	}
	for _, key := range keys {
		t.Setenv(key, "")
	}
}

func TestReadConfigDefaults(t *testing.T) {
	clearBillingEnv(t)

	cfg := ReadConfig()

	if cfg.EncryptionMnemonic != "" {
		t.Fatalf("EncryptionMnemonic = %q, want empty", cfg.EncryptionMnemonic)
	}
	if cfg.StripeSecretKey != "" {
		t.Fatalf("StripeSecretKey = %q, want empty", cfg.StripeSecretKey)
	}
	if cfg.StripeWebhookSecret != "" {
		t.Fatalf("StripeWebhookSecret = %q, want empty", cfg.StripeWebhookSecret)
	}
	if cfg.StripeSuccessURL != "" {
		t.Fatalf("StripeSuccessURL = %q, want empty", cfg.StripeSuccessURL)
	}
	if cfg.StripeCancelURL != "" {
		t.Fatalf("StripeCancelURL = %q, want empty", cfg.StripeCancelURL)
	}
	if cfg.StripeConnectWebhookSecret != "" {
		t.Fatalf("StripeConnectWebhookSecret = %q, want empty", cfg.StripeConnectWebhookSecret)
	}
	if cfg.StripeConnectPlatformCountry != "US" {
		t.Fatalf("StripeConnectPlatformCountry = %q, want US", cfg.StripeConnectPlatformCountry)
	}
	if cfg.StripeConnectReturnURL != "" {
		t.Fatalf("StripeConnectReturnURL = %q, want empty", cfg.StripeConnectReturnURL)
	}
	if cfg.StripeConnectRefreshURL != "" {
		t.Fatalf("StripeConnectRefreshURL = %q, want empty", cfg.StripeConnectRefreshURL)
	}
	if cfg.MockMode {
		t.Fatal("MockMode = true, want false")
	}
	if cfg.ReferralSharePercent != 20 {
		t.Fatalf("ReferralSharePercent = %d, want 20", cfg.ReferralSharePercent)
	}
}

func TestReadConfigEnvOverrides(t *testing.T) {
	clearBillingEnv(t)

	t.Setenv("MNEMONIC", "global-mnemonic")
	t.Setenv(env.EnvPrefix+"_MNEMONIC", "prefixed-mnemonic")
	t.Setenv(env.EnvPrefix+"_SOLANA_MNEMONIC", "solana-mnemonic")
	t.Setenv(env.EnvPrefix+"_STRIPE_SECRET_KEY", "sk_test_123")
	t.Setenv(env.EnvPrefix+"_STRIPE_WEBHOOK_SECRET", "whsec_123")
	t.Setenv(env.EnvPrefix+"_STRIPE_SUCCESS_URL", "https://example.test/success")
	t.Setenv(env.EnvPrefix+"_STRIPE_CANCEL_URL", "https://example.test/cancel")
	t.Setenv(env.EnvPrefix+"_STRIPE_CONNECT_WEBHOOK_SECRET", "whsec_connect_123")
	t.Setenv(env.EnvPrefix+"_STRIPE_CONNECT_COUNTRY", "CA")
	t.Setenv(env.EnvPrefix+"_STRIPE_CONNECT_RETURN_URL", "https://example.test/return")
	t.Setenv(env.EnvPrefix+"_STRIPE_CONNECT_REFRESH_URL", "https://example.test/refresh")
	t.Setenv(env.EnvPrefix+"_BILLING_MOCK", "true")
	t.Setenv(env.EnvPrefix+"_REFERRAL_SHARE_PCT", "33")

	cfg := ReadConfig()

	if cfg.EncryptionMnemonic != "global-mnemonic" {
		t.Fatalf("EncryptionMnemonic = %q, want global-mnemonic", cfg.EncryptionMnemonic)
	}
	if cfg.StripeSecretKey != "sk_test_123" {
		t.Fatalf("StripeSecretKey = %q, want sk_test_123", cfg.StripeSecretKey)
	}
	if cfg.StripeWebhookSecret != "whsec_123" {
		t.Fatalf("StripeWebhookSecret = %q, want whsec_123", cfg.StripeWebhookSecret)
	}
	if cfg.StripeSuccessURL != "https://example.test/success" {
		t.Fatalf("StripeSuccessURL = %q, want success URL", cfg.StripeSuccessURL)
	}
	if cfg.StripeCancelURL != "https://example.test/cancel" {
		t.Fatalf("StripeCancelURL = %q, want cancel URL", cfg.StripeCancelURL)
	}
	if cfg.StripeConnectWebhookSecret != "whsec_connect_123" {
		t.Fatalf("StripeConnectWebhookSecret = %q, want whsec_connect_123", cfg.StripeConnectWebhookSecret)
	}
	if cfg.StripeConnectPlatformCountry != "CA" {
		t.Fatalf("StripeConnectPlatformCountry = %q, want CA", cfg.StripeConnectPlatformCountry)
	}
	if cfg.StripeConnectReturnURL != "https://example.test/return" {
		t.Fatalf("StripeConnectReturnURL = %q, want return URL", cfg.StripeConnectReturnURL)
	}
	if cfg.StripeConnectRefreshURL != "https://example.test/refresh" {
		t.Fatalf("StripeConnectRefreshURL = %q, want refresh URL", cfg.StripeConnectRefreshURL)
	}
	if !cfg.MockMode {
		t.Fatal("MockMode = false, want true")
	}
	if cfg.ReferralSharePercent != 33 {
		t.Fatalf("ReferralSharePercent = %d, want 33", cfg.ReferralSharePercent)
	}
}

func TestReadConfigMnemonicPrecedence(t *testing.T) {
	tests := []struct {
		name             string
		mnemonic         string
		prefixedMnemonic string
		solanaMnemonic   string
		want             string
	}{
		{name: "global wins", mnemonic: "global", prefixedMnemonic: "prefixed", solanaMnemonic: "solana", want: "global"},
		{name: "prefixed wins without global", prefixedMnemonic: "prefixed", solanaMnemonic: "solana", want: "prefixed"},
		{name: "solana fallback", solanaMnemonic: "solana", want: "solana"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearBillingEnv(t)
			t.Setenv("MNEMONIC", tt.mnemonic)
			t.Setenv(env.EnvPrefix+"_MNEMONIC", tt.prefixedMnemonic)
			t.Setenv(env.EnvPrefix+"_SOLANA_MNEMONIC", tt.solanaMnemonic)

			cfg := ReadConfig()
			if cfg.EncryptionMnemonic != tt.want {
				t.Fatalf("EncryptionMnemonic = %q, want %q", cfg.EncryptionMnemonic, tt.want)
			}
		})
	}
}

func TestReadConfigReferralShareInvalidFallsBackToDefault(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want int64
	}{
		{name: "empty", raw: "", want: 20},
		{name: "invalid", raw: "not-a-number", want: 20},
		{name: "zero", raw: "0", want: 0},
		{name: "negative", raw: "-5", want: -5},
		{name: "positive", raw: "45", want: 45},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			clearBillingEnv(t)
			t.Setenv(env.EnvPrefix+"_REFERRAL_SHARE_PCT", tt.raw)

			cfg := ReadConfig()
			if cfg.ReferralSharePercent != tt.want {
				t.Fatalf("ReferralSharePercent = %d, want %d", cfg.ReferralSharePercent, tt.want)
			}
		})
	}
}

func TestConfigCheckRejectsMockModeWithStripeSecret(t *testing.T) {
	tests := []struct {
		name    string
		cfg     Config
		wantErr bool
	}{
		{name: "mock with stripe secret", cfg: Config{MockMode: true, StripeSecretKey: "sk_live_x"}, wantErr: true},
		{name: "mock without stripe secret", cfg: Config{MockMode: true}},
		{name: "stripe secret without mock", cfg: Config{StripeSecretKey: "sk_live_x"}},
		{name: "zero config", cfg: Config{}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.cfg.Check()
			if tt.wantErr {
				if err == nil {
					t.Fatal("Check() error = nil, want error")
				}
				if !strings.Contains(err.Error(), "mock mode") {
					t.Fatalf("Check() error = %q, want mock mode context", err.Error())
				}
				if !strings.Contains(err.Error(), env.EnvPrefix+"_STRIPE_SECRET_KEY") {
					t.Fatalf("Check() error = %q, want Stripe secret env var context", err.Error())
				}
				return
			}
			if err != nil {
				t.Fatalf("Check() error = %v, want nil", err)
			}
		})
	}
}
