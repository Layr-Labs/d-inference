package billing

import (
	"os"
	"strconv"
)

// ReadConfig reads billing configuration from environment variables.
// The Config type is defined in billing.go.
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
