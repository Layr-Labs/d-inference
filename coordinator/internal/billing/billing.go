// Package billing provides unified payment processing for the DGInf coordinator.
//
// Payment flow (Privy auth + client-side Solana signing):
//  1. User authenticates via Privy → gets embedded Solana wallet
//  2. User deposits USDC into their Privy wallet (from exchange, etc.)
//  3. User signs a USDC transfer to the coordinator address in the frontend
//  4. User submits the tx signature to POST /v1/billing/deposit
//  5. Backend verifies the on-chain tx came FROM the user's wallet, credits balance
//
// The user controls their own keys at all times. The backend never signs
// transactions — it only verifies what happened on-chain.
//
// Stripe checkout is wired but not activated for day-1 launch.
// A referral system allows accounts to earn a share of platform fees.
package billing

import (
	"log/slog"

	"github.com/dginf/coordinator/internal/payments"
	"github.com/dginf/coordinator/internal/store"
)

// PaymentMethod identifies the payment rail used for a transaction.
type PaymentMethod string

const (
	MethodStripe PaymentMethod = "stripe"
	MethodSolana PaymentMethod = "solana"
)

// Chain identifies the specific blockchain network.
type Chain string

const (
	ChainSolana Chain = "solana"
)

// Config holds billing service configuration, typically from environment variables.
type Config struct {
	// Stripe — present but not activated day-1 (set env vars to enable)
	StripeSecretKey     string
	StripeWebhookSecret string
	StripeSuccessURL    string
	StripeCancelURL     string

	// Solana — primary payment rail for launch
	SolanaRPCURL             string
	SolanaUSDCMint           string
	SolanaCoordinatorAddress string // address that receives USDC deposits

	// Referral
	ReferralSharePercent int64 // percentage of platform fee going to referrer (default 20)

	// MockMode skips on-chain verification and auto-credits test balances.
	// Set DGINF_BILLING_MOCK=true for testing without real payments.
	MockMode bool
}

// Service is the unified billing orchestrator. It delegates to chain-specific
// processors and manages the referral reward flow.
type Service struct {
	store    store.Store
	ledger   *payments.Ledger
	logger   *slog.Logger
	config   Config

	stripe   *StripeProcessor
	solana   *SolanaProcessor
	referral *ReferralService
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
	}

	// Initialize Solana processor
	if cfg.SolanaRPCURL != "" {
		svc.solana = NewSolanaProcessor(cfg.SolanaRPCURL, cfg.SolanaCoordinatorAddress,
			cfg.SolanaUSDCMint, "", cfg.MockMode, logger)
		logger.Info("billing: Solana processor enabled",
			"coordinator_address", cfg.SolanaCoordinatorAddress,
			"mock_mode", cfg.MockMode,
		)
	}

	return svc
}

// Stripe returns the Stripe processor, or nil if not configured.
func (s *Service) Stripe() *StripeProcessor { return s.stripe }

// Solana returns the Solana processor, or nil if not configured.
func (s *Service) Solana() *SolanaProcessor { return s.solana }

// Referral returns the referral service.
func (s *Service) Referral() *ReferralService { return s.referral }

// MockMode returns true if billing is in mock mode (no on-chain verification).
func (s *Service) MockMode() bool { return s.config.MockMode }

// Store returns the underlying store for direct access.
func (s *Service) Store() store.Store { return s.store }

// Ledger returns the underlying ledger for direct access.
func (s *Service) Ledger() *payments.Ledger { return s.ledger }

// CoordinatorAddress returns the Solana address that receives USDC payments.
func (s *Service) CoordinatorAddress() string { return s.config.SolanaCoordinatorAddress }

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

	if s.solana != nil {
		methods = append(methods, PaymentMethodInfo{
			Method:      MethodSolana,
			Chain:       ChainSolana,
			DisplayName: "USDC on Solana",
			Currencies:  []string{"USDC"},
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
	Chain       Chain         `json:"chain,omitempty"`
	DisplayName string        `json:"display_name"`
	Currencies  []string      `json:"currencies"`
}
