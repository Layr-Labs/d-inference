package billing

import (
	"fmt"
	"os"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Config holds billing service configuration, typically from environment variables.
type Config struct {
	globalPayoutsOnlyRaw string
	// Stripe — primary payment rail for deposits.
	StripeSecretKey     string
	StripeWebhookSecret string
	StripeSuccessURL    string
	StripeCancelURL     string
	// Previous Checkout account: verification only, never creates new sessions.
	StripeLegacyWebhookSecret string

	// Stripe Connect — Express accounts for paying users out to bank/card.
	// Reuses StripeSecretKey for API auth; Connect events have a separate
	// webhook signing secret because they're posted to a different endpoint.
	StripeConnectWebhookSecret         string
	StripeConnectSecretKey             string
	StripeConnectAccountsWebhookSecret string
	StripeConnectPlatformCountry       string // ISO 3166-1 alpha-2; defaults to "US"
	StripeConnectReturnURL             string // where Stripe redirects after onboarding completes
	StripeConnectRefreshURL            string // where Stripe redirects if the link expires

	// Global Payouts is enabled only when its funding account is configured.
	StripeGlobalPayoutsEnabled          bool
	StripeGlobalPayoutsFinancialAccount string
	StripeGlobalPayoutsSecretKey        string
	StripeGlobalPayoutsWebhookSecret    string
	// Explicit cutover. Pausing Global Payouts must never re-enable Connect.
	StripeGlobalPayoutsOnly bool

	// EncryptionMnemonic is a BIP39 mnemonic phrase used to derive the
	// coordinator's X25519 encryption key (via HKDF) for sender→coordinator
	// E2E request encryption (e2e.DeriveCoordinatorKey).
	EncryptionMnemonic string

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
		globalPayoutsOnlyRaw: os.Getenv(env.EnvPrefix + "_STRIPE_GLOBAL_PAYOUTS_ONLY"),
		EncryptionMnemonic: env.FirstNonEmpty(
			os.Getenv("MNEMONIC"),
			os.Getenv(env.EnvPrefix+"_MNEMONIC"),
		),
		StripeSecretKey:                     os.Getenv(env.EnvPrefix + "_STRIPE_SECRET_KEY"),
		StripeWebhookSecret:                 os.Getenv(env.EnvPrefix + "_STRIPE_WEBHOOK_SECRET"),
		StripeSuccessURL:                    os.Getenv(env.EnvPrefix + "_STRIPE_SUCCESS_URL"),
		StripeCancelURL:                     os.Getenv(env.EnvPrefix + "_STRIPE_CANCEL_URL"),
		StripeLegacyWebhookSecret:           os.Getenv(env.EnvPrefix + "_STRIPE_LEGACY_WEBHOOK_SECRET"),
		StripeConnectSecretKey:              os.Getenv(env.EnvPrefix + "_STRIPE_CONNECT_SECRET_KEY"),
		StripeConnectWebhookSecret:          os.Getenv(env.EnvPrefix + "_STRIPE_CONNECT_WEBHOOK_SECRET"),
		StripeConnectAccountsWebhookSecret:  os.Getenv(env.EnvPrefix + "_STRIPE_CONNECT_ACCOUNTS_WEBHOOK_SECRET"),
		StripeConnectPlatformCountry:        env.EnvOr(env.EnvPrefix+"_STRIPE_CONNECT_COUNTRY", "US"),
		StripeConnectReturnURL:              os.Getenv(env.EnvPrefix + "_STRIPE_CONNECT_RETURN_URL"),
		StripeConnectRefreshURL:             os.Getenv(env.EnvPrefix + "_STRIPE_CONNECT_REFRESH_URL"),
		StripeGlobalPayoutsEnabled:          os.Getenv(env.EnvPrefix+"_STRIPE_GLOBAL_PAYOUTS_ENABLED") == "true",
		StripeGlobalPayoutsFinancialAccount: os.Getenv(env.EnvPrefix + "_STRIPE_GLOBAL_PAYOUTS_FINANCIAL_ACCOUNT"),
		StripeGlobalPayoutsSecretKey:        env.FirstNonEmpty(os.Getenv(env.EnvPrefix+"_STRIPE_GLOBAL_PAYOUTS_SECRET_KEY"), os.Getenv(env.EnvPrefix+"_STRIPE_SECRET_KEY")),
		StripeGlobalPayoutsWebhookSecret:    os.Getenv(env.EnvPrefix + "_STRIPE_GLOBAL_PAYOUTS_WEBHOOK_SECRET"),
		StripeGlobalPayoutsOnly:             os.Getenv(env.EnvPrefix+"_STRIPE_GLOBAL_PAYOUTS_ONLY") == "true",
		MockMode:                            os.Getenv(env.EnvPrefix+"_BILLING_MOCK") == "true",
	}
	if cfg.StripeGlobalPayoutsOnly {
		// No cross-account authentication fallback during the cutover.
		cfg.StripeGlobalPayoutsSecretKey = os.Getenv(env.EnvPrefix + "_STRIPE_GLOBAL_PAYOUTS_SECRET_KEY")
	}
	return cfg
}

// Check validates billing configuration invariants. At minimum it prevents
// MockMode from coexisting with real Stripe credentials — accidental mock
// enablement in a production deployment with live keys would silently skip
// payment verification.
func (c Config) Check() error {
	if c.globalPayoutsOnlyRaw != "" && c.globalPayoutsOnlyRaw != "true" && c.globalPayoutsOnlyRaw != "false" {
		return fmt.Errorf("STRIPE_GLOBAL_PAYOUTS_ONLY must be true or false")
	}
	if c.StripeGlobalPayoutsEnabled && (c.StripeGlobalPayoutsFinancialAccount == "" || c.StripeGlobalPayoutsSecretKey == "") {
		return fmt.Errorf("Global Payouts requires a financial account and restricted API key")
	}
	if c.StripeGlobalPayoutsOnly && (c.StripeGlobalPayoutsFinancialAccount == "" || c.StripeGlobalPayoutsSecretKey == "" || c.StripeGlobalPayoutsWebhookSecret == "") {
		return fmt.Errorf("Global Payouts cutover requires its financial account, API key and webhook secret, including while paused")
	}
	if c.StripeGlobalPayoutsOnly && c.StripeConnectSecretKey == "" && (c.StripeConnectWebhookSecret != "" || c.StripeConnectAccountsWebhookSecret != "") {
		return fmt.Errorf("retained Connect webhooks require an explicit STRIPE_CONNECT_SECRET_KEY during cutover")
	}
	if c.MockMode && (c.StripeSecretKey != "" || c.StripeConnectSecretKey != "" || c.StripeGlobalPayoutsSecretKey != "") {
		return fmt.Errorf("billing mock mode is enabled but a real Stripe secret key is configured — these are mutually exclusive; unset %s_STRIPE_SECRET_KEY or disable %s_BILLING_MOCK", env.EnvPrefix, env.EnvPrefix)
	}
	return nil
}
