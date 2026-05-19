package billing

import (
	"os"
	"strconv"
)

// Config holds billing service configuration, typically from environment variables.
type Config struct {
	// Stripe — primary payment rail for deposits.
	StripeSecretKey     string
	StripeWebhookSecret string
	StripeSuccessURL    string
	StripeCancelURL     string

	// Stripe Connect — Express accounts for paying users out to bank/card.
	// Reuses StripeSecretKey for API auth; Connect events have a separate
	// webhook signing secret because they're posted to a different endpoint.
	StripeConnectWebhookSecret   string
	StripeConnectPlatformCountry string // ISO 3166-1 alpha-2; defaults to "US"
	StripeConnectReturnURL       string // where Stripe redirects after onboarding completes
	StripeConnectRefreshURL      string // where Stripe redirects if the link expires

	// EncryptionMnemonic is a BIP39 mnemonic phrase used to derive the
	// coordinator's X25519 encryption key (via HKDF) for sender→coordinator
	// E2E request encryption (e2e.DeriveCoordinatorKey).
	EncryptionMnemonic string

	// Referral
	ReferralSharePercent int64 // percentage of platform fee going to referrer (default 20)

	// MockMode skips on-chain verification and auto-credits test balances.
	// Set EIGENINFERENCE_BILLING_MOCK=true for testing without real payments.
	MockMode bool
}

// ReadConfig reads billing configuration from environment variables.
func ReadConfig() Config {
	cfg := Config{
		EncryptionMnemonic: firstNonEmpty(
			os.Getenv("MNEMONIC"),
			os.Getenv("EIGENINFERENCE_MNEMONIC"),
			os.Getenv("EIGENINFERENCE_SOLANA_MNEMONIC"),
		),
		StripeSecretKey:              os.Getenv("EIGENINFERENCE_STRIPE_SECRET_KEY"),
		StripeWebhookSecret:          os.Getenv("EIGENINFERENCE_STRIPE_WEBHOOK_SECRET"),
		StripeSuccessURL:             os.Getenv("EIGENINFERENCE_STRIPE_SUCCESS_URL"),
		StripeCancelURL:              os.Getenv("EIGENINFERENCE_STRIPE_CANCEL_URL"),
		StripeConnectWebhookSecret:   os.Getenv("EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET"),
		StripeConnectPlatformCountry: envOr("EIGENINFERENCE_STRIPE_CONNECT_COUNTRY", "US"),
		StripeConnectReturnURL:       os.Getenv("EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL"),
		StripeConnectRefreshURL:      os.Getenv("EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL"),
		MockMode:                     os.Getenv("EIGENINFERENCE_BILLING_MOCK") == "true",
		ReferralSharePercent:         20,
	}
	if refShareStr := os.Getenv("EIGENINFERENCE_REFERRAL_SHARE_PCT"); refShareStr != "" {
		if v, err := strconv.ParseInt(refShareStr, 10, 64); err == nil {
			cfg.ReferralSharePercent = v
		}
	}
	return cfg
}

// Check validates the billing configuration.
func (c Config) Check() error { return nil }

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
