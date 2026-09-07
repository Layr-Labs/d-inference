package billing

import (
	"errors"
	"fmt"
	"log/slog"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// ErrInvalidReferral identifies a referral input the caller can correct.
var ErrInvalidReferral = errors.New("invalid referral")

// ReferralService manages consumer attribution. The store atomically credits
// 5% of collected token spend during FinalizeConsumerCharge, independently of
// the platform fee and without reducing provider earnings.
type ReferralService struct {
	store  store.Store
	logger *slog.Logger
}

func NewReferralService(st store.Store, logger *slog.Logger) *ReferralService {
	return &ReferralService{store: st, logger: logger}
}

func (r *ReferralService) SharePercent() int64 { return store.ConsumerReferralPercent }

// Register returns the account's immutable code, including on concurrent retry.
func (r *ReferralService) Register(accountID, desiredCode string) (*store.Referrer, error) {
	if accountID == "" {
		return nil, fmt.Errorf("%w: account is required", ErrInvalidReferral)
	}
	existing, err := r.store.GetReferrerByAccount(accountID)
	if err == nil {
		return existing, nil
	}
	if !errors.Is(err, store.ErrNotFound) {
		return nil, err
	}
	code, err := validateReferralCode(desiredCode)
	if err != nil {
		return nil, err
	}
	if err = r.store.CreateReferrer(accountID, code); err != nil {
		if existing, lookupErr := r.store.GetReferrerByAccount(accountID); lookupErr == nil {
			return existing, nil
		}
		return nil, fmt.Errorf("referral: create referrer: %w", err)
	}
	r.logger.Info("referral: new referrer registered", "account", truncateID(accountID), "code", code)
	return r.store.GetReferrerByAccount(accountID)
}

// validateReferralCode keeps share links portable: 3-20 ASCII letters, digits,
// or internal hyphens. Case and surrounding whitespace are normalized.
func validateReferralCode(code string) (string, error) {
	code = strings.ToUpper(strings.TrimSpace(code))
	if len(code) < 3 || len(code) > 20 {
		return "", fmt.Errorf("%w: code must be 3-20 characters", ErrInvalidReferral)
	}
	for _, ch := range code {
		if !(ch >= 'A' && ch <= 'Z') && !(ch >= '0' && ch <= '9') && ch != '-' {
			return "", fmt.Errorf("%w: code can only contain ASCII letters, numbers, and hyphens", ErrInvalidReferral)
		}
	}
	if code[0] == '-' || code[len(code)-1] == '-' {
		return "", fmt.Errorf("%w: code cannot start or end with a hyphen", ErrInvalidReferral)
	}
	return code, nil
}

// Apply is immutable first-touch attribution. Reapplying the same code succeeds
// so login retries and duplicate checkout webhooks are safe.
func (r *ReferralService) Apply(accountID, referralCode string) error {
	if accountID == "" {
		return fmt.Errorf("%w: account is required", ErrInvalidReferral)
	}
	// Existing codes may contain Unicode letters accepted by older releases.
	// Registration is ASCII-only; applying an existing code uses its lookup as
	// the authority so previously shared links keep working.
	code := strings.ToUpper(strings.TrimSpace(referralCode))
	if len(code) < 3 || len(code) > 20 {
		return fmt.Errorf("%w: code must be 3-20 characters", ErrInvalidReferral)
	}
	referrer, err := r.store.GetReferrerByCode(code)
	if errors.Is(err, store.ErrNotFound) {
		return fmt.Errorf("%w: code does not exist", ErrInvalidReferral)
	}
	if err != nil {
		return err
	}
	if referrer.AccountID == accountID {
		return fmt.Errorf("%w: cannot refer yourself", ErrInvalidReferral)
	}
	// The store enforces immutability under its lock/transaction, not a racy read.
	return r.store.RecordReferral(code, accountID)
}

func (r *ReferralService) Stats(accountID string) (*ReferralStatsResponse, error) {
	referrer, err := r.store.GetReferrerByAccount(accountID)
	if err != nil {
		return nil, err
	}
	stats, err := r.store.GetReferralStats(referrer.Code)
	if err != nil {
		return nil, err
	}
	balance := r.store.GetBalance(accountID)
	return &ReferralStatsResponse{
		Code: referrer.Code, SharePercent: r.SharePercent(), RewardBasis: "consumer_spend",
		TotalReferred: stats.TotalReferred, TotalRewardsMicroUSD: stats.TotalRewardsMicroUSD,
		TotalRewardsUSD:            microUSDString(stats.TotalRewardsMicroUSD),
		TotalReferredSpendMicroUSD: stats.TotalReferredSpendMicroUSD, TotalReferredSpendUSD: microUSDString(stats.TotalReferredSpendMicroUSD),
		BalanceMicroUSD: balance, BalanceUSD: microUSDString(balance),
	}, nil
}

type ReferralStatsResponse struct {
	Code                       string `json:"code"`
	SharePercent               int64  `json:"share_percent"`
	RewardBasis                string `json:"reward_basis"`
	TotalReferred              int    `json:"total_referred"`
	TotalRewardsMicroUSD       int64  `json:"total_rewards_micro_usd"`
	TotalRewardsUSD            string `json:"total_rewards_usd"`
	TotalReferredSpendMicroUSD int64  `json:"total_referred_spend_micro_usd"`
	TotalReferredSpendUSD      string `json:"total_referred_spend_usd"`
	BalanceMicroUSD            int64  `json:"balance_micro_usd"`
	BalanceUSD                 string `json:"balance_usd"`
}

func microUSDString(amount int64) string {
	return fmt.Sprintf("%d.%06d", amount/1_000_000, amount%1_000_000)
}

func truncateID(id string) string {
	if len(id) <= 10 {
		return id
	}
	return id[:8] + "..."
}
