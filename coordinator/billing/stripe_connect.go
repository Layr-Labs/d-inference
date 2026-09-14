package billing

import (
	"log/slog"
	"net/http"
	"time"
)

// Stripe Connect client operations are grouped by responsibility:
//
//   - stripe_connect_accounts.go creates accounts, configures their automatic
//     payout schedule and projects current account state.
//   - stripe_connect_links.go creates hosted onboarding and dashboard links.
//   - stripe_connect_transfers.go moves platform funds to connected accounts;
//     stripe_connect_payouts.go creates and reads individual payouts.
//   - stripe_connect_webhooks.go verifies signatures and projects event payloads.
//   - stripe_connect_transport.go sends authenticated HTTP requests with supplied idempotency keys;
//     stripe_connect_errors.go classifies definitive and uncertain failures.
//   - stripe_connect_fees.go calculates the platform's withdrawal fees.
//
// The API billing controller owns ledger debits, reconciliation and refunds.
// Stripe amounts use integer USD cents; callers round the micro-USD ledger
// amounts before invoking this client. All files share this client's state.

// StripeConnect wraps the Stripe Connect Express endpoints. It piggybacks on
// the same secret key + HTTP client as StripeProcessor.
type StripeConnect struct {
	secretKey            string
	connectWebhookSecret string
	platformCountry      string // ISO 3166-1 alpha-2 — defaults to "US"
	mockMode             bool   // skips real Stripe API calls; returns deterministic stub responses
	httpClient           *http.Client
	logger               *slog.Logger
}

// NewStripeConnect builds a Stripe Connect client. If secretKey is empty the
// client returns errors from every method; the higher-level service treats
// that as "Stripe Payouts not configured".
func NewStripeConnect(secretKey, connectWebhookSecret, platformCountry string, mockMode bool, logger *slog.Logger) *StripeConnect {
	if platformCountry == "" {
		platformCountry = "US"
	}
	return &StripeConnect{
		secretKey:            secretKey,
		connectWebhookSecret: connectWebhookSecret,
		platformCountry:      platformCountry,
		mockMode:             mockMode,
		httpClient:           &http.Client{Timeout: 30 * time.Second},
		logger:               logger,
	}
}

// MockMode reports whether the client is short-circuiting Stripe API calls.
func (c *StripeConnect) MockMode() bool { return c.mockMode }

// PlatformCountry returns the ISO 3166-1 alpha-2 platform default country
// used when the user doesn't provide one.
func (c *StripeConnect) PlatformCountry() string { return c.platformCountry }
