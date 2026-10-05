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

	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// PaymentMethod identifies the payment rail used for a transaction.
type PaymentMethod string

const (
	MethodStripe PaymentMethod = "stripe"
)

// Service is the unified billing orchestrator. It delegates to chain-specific
// processors and manages the referral reward flow.
type Service struct {
	store  store.Store
	ledger *payments.Ledger
	logger *slog.Logger
	config Config

	stripe        *StripeProcessor
	stripeConnect *StripeConnect
	globalPayouts *globalpayouts.Client
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
		referral: NewReferralService(st, logger, cfg.ReferralSharePercent),
	}

	if cfg.StripeGlobalPayoutsSecretKey != "" && cfg.StripeGlobalPayoutsFinancialAccount != "" {
		svc.globalPayouts = globalpayouts.New(cfg.StripeGlobalPayoutsSecretKey, cfg.StripeGlobalPayoutsFinancialAccount)
	}

	// Initialize Stripe if configured
	if cfg.StripeSecretKey != "" {
		svc.stripe = NewStripeProcessor(cfg.StripeSecretKey, cfg.StripeWebhookSecret,
			cfg.StripeSuccessURL, cfg.StripeCancelURL, logger)
		logger.Info("billing: Stripe processor enabled")
	}
	// Connect remains bound to the old platform while Checkout moves independently.
	connectKey := cfg.StripeConnectSecretKey
	if connectKey == "" && !cfg.StripeGlobalPayoutsOnly {
		connectKey = cfg.StripeSecretKey
	}
	if connectKey != "" || cfg.MockMode {
		svc.stripeConnect = NewStripeConnect(connectKey, cfg.StripeConnectWebhookSecret,
			cfg.StripeConnectPlatformCountry, cfg.MockMode, logger)
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

// GlobalPayouts returns the bank adapter when credentials are configured.
func (s *Service) GlobalPayouts() *globalpayouts.Client { return s.globalPayouts }
func (s *Service) GlobalPayoutsWebhookSecret() string {
	return s.config.StripeGlobalPayoutsWebhookSecret
}

// GlobalPayoutsEnabled gates new onboarding and withdrawals. Reconciliation
// continues while the credentials remain configured, even when admissions stop.
func (s *Service) GlobalPayoutsEnabled() bool {
	return s.config.StripeGlobalPayoutsEnabled && s.globalPayouts != nil
}

// GlobalPayoutsOnly disables all new Connect onboarding and transfers, even while paused.
func (s *Service) GlobalPayoutsOnly() bool           { return s.config.StripeGlobalPayoutsOnly }
func (s *Service) StripeLegacyWebhookSecret() string { return s.config.StripeLegacyWebhookSecret }
func (s *Service) StripeConnectAccountsWebhookSecret() string {
	return s.config.StripeConnectAccountsWebhookSecret
}
