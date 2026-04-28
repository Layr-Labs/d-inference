// Package billing provides unified payment processing for the Darkbloom coordinator.
//
// Payment flow (Stripe):
//  1. User authenticates via Privy
//  2. User creates a Stripe Checkout session via POST /v1/billing/stripe/create-session
//  3. Stripe webhook confirms payment and credits internal balance
//
// Payouts to providers use Stripe Connect Express (bank/card withdrawals).
// A referral system allows accounts to earn a share of platform fees.
package billing

import (
	"log/slog"

	"github.com/darkbloom/coordinator/internal/payments"
	"github.com/darkbloom/coordinator/internal/store"
)

// PaymentMethod identifies the payment rail used for a transaction.
type PaymentMethod string

const (
	MethodStripe PaymentMethod = "stripe"
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

	// SolanaMnemonic is a BIP39 mnemonic phrase used to derive the coordinator's
	// X25519 encryption key (via HKDF). Kept for backward compatibility with
	// the e2e.DeriveCoordinatorKey() call path.
	SolanaMnemonic string

	// Referral
	ReferralSharePercent int64 // percentage of platform fee going to referrer (default 20)

	// MockMode skips on-chain verification and auto-credits test balances.
	// Set EIGENINFERENCE_BILLING_MOCK=true for testing without real payments.
	MockMode bool
}

// Service is the unified billing orchestrator. It delegates to chain-specific
// processors and manages the referral reward flow.
type Service struct {
	store  store.Store
	ledger *payments.Ledger
	logger *slog.Logger
	config Config

	stripe        *StripeProcessor
	stripeConnect *StripeConnect
	referral      *ReferralService
}

// NewService creates a new billing service from the given configuration.
func NewService(st store.Store, ledger *payments.Ledger, logger *slog.Logger, cfg Config) *Service {
	if cfg.ReferralSharePercent == 0 {
		cfg.ReferralSharePercent = 20
	}

	svc := &Service{
		store:    st,
		ledger:   ledger,
		logger:   logger,
		config:   cfg,
		referral: NewReferralService(st, ledger, logger, cfg.ReferralSharePercent),
	}

	// Initialize Stripe if configured
	if cfg.StripeSecretKey != "" {
		svc.stripe = NewStripeProcessor(cfg.StripeSecretKey, cfg.StripeWebhookSecret,
			cfg.StripeSuccessURL, cfg.StripeCancelURL, logger)
		logger.Info("billing: Stripe processor enabled")

		// Stripe Connect rides on the same secret key. We always create the
		// client when Stripe is configured so callers can decide whether to
		// surface the bank-payout option based on connect-specific config
		// (return URL, etc.) being present.
		svc.stripeConnect = NewStripeConnect(
			cfg.StripeSecretKey,
			cfg.StripeConnectWebhookSecret,
			cfg.StripeConnectPlatformCountry,
			cfg.MockMode,
			logger,
		)
		logger.Info("billing: Stripe Connect (Express) enabled",
			"platform_country", cfg.StripeConnectPlatformCountry,
			"connect_webhook_configured", cfg.StripeConnectWebhookSecret != "",
		)
	} else if cfg.MockMode {
		// In mock mode, surface a stub Connect client so dev console can
		// exercise the full payout flow without real Stripe credentials.
		svc.stripeConnect = NewStripeConnect("", "", cfg.StripeConnectPlatformCountry, true, logger)
		logger.Info("billing: Stripe Connect mock-mode enabled")
	}

	return svc
}

// Stripe returns the Stripe processor, or nil if not configured.
func (s *Service) Stripe() *StripeProcessor { return s.stripe }

// StripeConnect returns the Stripe Connect Express client, or nil if Stripe
// payouts are not configured.
func (s *Service) StripeConnect() *StripeConnect { return s.stripeConnect }

// StripeConnectReturnURL returns the configured return URL the frontend
// should hand to Stripe in onboarding links.
func (s *Service) StripeConnectReturnURL() string { return s.config.StripeConnectReturnURL }

// StripeConnectRefreshURL returns the configured link-refresh URL.
func (s *Service) StripeConnectRefreshURL() string { return s.config.StripeConnectRefreshURL }

// Referral returns the referral service.
func (s *Service) Referral() *ReferralService { return s.referral }

// MockMode returns true if billing is in mock mode (no on-chain verification).
func (s *Service) MockMode() bool { return s.config.MockMode }

// Store returns the underlying store for direct access.
func (s *Service) Store() store.Store { return s.store }

// Ledger returns the underlying ledger for direct access.
func (s *Service) Ledger() *payments.Ledger { return s.ledger }

// SupportedMethods returns which payment methods are configured and available.
func (s *Service) SupportedMethods() []PaymentMethodInfo {
	var methods []PaymentMethodInfo

	if s.stripe != nil {
		methods = append(methods, PaymentMethodInfo{
			Method:      MethodStripe,
			DisplayName: "Credit/Debit Card (Stripe)",
			Currencies:  []string{"USD"},
		})
	}

	return methods
}

// IsExternalIDProcessed checks the database for whether a tx signature has
// already been credited. Survives coordinator restarts.
func (s *Service) IsExternalIDProcessed(externalID string) bool {
	return s.store.IsExternalIDProcessed(externalID)
}

// CreditDeposit credits a consumer's balance after a verified deposit.
func (s *Service) CreditDeposit(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error {
	return s.store.Credit(accountID, amountMicroUSD, entryType, reference)
}

// PaymentMethodInfo describes a supported payment method for the API.
type PaymentMethodInfo struct {
	Method      PaymentMethod `json:"method"`
	DisplayName string        `json:"display_name"`
	Currencies  []string      `json:"currencies"`
}
