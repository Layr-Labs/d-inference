package billing

import (
	"fmt"
	"os"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/env"
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
	//
	// TODO(linear): audit MockMode code paths — accidental enablement in a real
	// deployment could silently skip payment verification. Tracked as DAR-59.
	MockMode bool
}

// ReadConfig reads billing configuration from environment variables.
func ReadConfig() Config {
	cfg := Config{
		EncryptionMnemonic: env.FirstNonEmpty(
			os.Getenv("MNEMONIC"),
			os.Getenv(env.EnvPrefix+"_MNEMONIC"),
			os.Getenv(env.EnvPrefix+"_SOLANA_MNEMONIC"),
		),
		StripeSecretKey:              os.Getenv(env.EnvPrefix + "_STRIPE_SECRET_KEY"),
		StripeWebhookSecret:          os.Getenv(env.EnvPrefix + "_STRIPE_WEBHOOK_SECRET"),
		StripeSuccessURL:             os.Getenv(env.EnvPrefix + "_STRIPE_SUCCESS_URL"),
		StripeCancelURL:              os.Getenv(env.EnvPrefix + "_STRIPE_CANCEL_URL"),
		StripeConnectWebhookSecret:   os.Getenv(env.EnvPrefix + "_STRIPE_CONNECT_WEBHOOK_SECRET"),
		StripeConnectPlatformCountry: env.EnvOr(env.EnvPrefix+"_STRIPE_CONNECT_COUNTRY", "US"),
		StripeConnectReturnURL:       os.Getenv(env.EnvPrefix + "_STRIPE_CONNECT_RETURN_URL"),
		StripeConnectRefreshURL:      os.Getenv(env.EnvPrefix + "_STRIPE_CONNECT_REFRESH_URL"),
		MockMode:                     os.Getenv(env.EnvPrefix+"_BILLING_MOCK") == "true",
		ReferralSharePercent:         20,
	}
	if refShareStr := os.Getenv(env.EnvPrefix + "_REFERRAL_SHARE_PCT"); refShareStr != "" {
		if v, err := strconv.ParseInt(refShareStr, 10, 64); err == nil {
			cfg.ReferralSharePercent = v
		}
	}
	return cfg
}

// Check validates billing configuration invariants. At minimum it prevents
// MockMode from coexisting with real Stripe credentials — accidental mock
// enablement in a production deployment with live keys would silently skip
// payment verification.
func (c Config) Check() error {
	if c.MockMode && c.StripeSecretKey != "" {
		return fmt.Errorf("billing mock mode is enabled but a real Stripe secret key is configured — these are mutually exclusive; unset %s_STRIPE_SECRET_KEY or disable %s_BILLING_MOCK", env.EnvPrefix, env.EnvPrefix)
	}
	return nil
}
