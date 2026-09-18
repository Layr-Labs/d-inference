package store

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"time"
)

var ErrPromotionConflict = errors.New("a different promotion already exists for this model")
var ErrPromotionUnavailable = errors.New("promotion cannot be claimed")
var ErrPromotionFull = errors.New("all promotion grants have been claimed")
var ErrPromotionIneligible = errors.New("account does not meet the signup cutoff")

var ErrPromotionInvalidSettlement = errors.New("invalid promotion settlement")

var ErrPromotionReservationClosed = errors.New("promotion reservation is already closed")

// ModelTokenPromotion is a one-time account grant with a bounded claim window.
// ModelID deliberately has no model-registry foreign key: configure before launch.
// Grant terms are immutable. Enabled only controls new claims, never existing grants.
type ModelTokenPromotion struct {
	ModelID        string     `json:"model_id"`
	Tokens         int64      `json:"tokens"`
	ClaimStartsAt  time.Time  `json:"claim_starts_at"`
	ClaimEndsAt    *time.Time `json:"claim_ends_at"`
	SignupCutoffAt time.Time  `json:"signup_cutoff_at"`
	MaxClaims      int64      `json:"max_claims"`
	ClaimedCount   int64      `json:"claimed_count"`
	Enabled        bool       `json:"enabled"`
}

func (p ModelTokenPromotion) Validate() error {
	if p.ModelID == "" || p.ModelID != strings.TrimSpace(p.ModelID) || len(p.ModelID) > 256 || strings.ContainsAny(p.ModelID, "\r\n\t") {
		return errors.New("model_id must be a nonempty model identifier of at most 256 bytes")
	}
	if p.Tokens <= 0 || p.Tokens > 1_000_000_000_000 {
		return errors.New("tokens must be between 1 and 1000000000000")
	}
	if p.ClaimStartsAt.IsZero() || (p.ClaimEndsAt != nil && !p.ClaimEndsAt.After(p.ClaimStartsAt)) {
		return errors.New("claim_ends_at must be after claim_starts_at")
	}
	if p.SignupCutoffAt.IsZero() || p.MaxClaims < 1 || p.MaxClaims > 1_000_000 {
		return errors.New("signup_cutoff_at and max_claims between 1 and 1000000 are required")
	}
	return nil
}

func (p ModelTokenPromotion) sameTerms(other ModelTokenPromotion) bool {
	return p.ModelID == other.ModelID && p.Tokens == other.Tokens && p.ClaimStartsAt.Equal(other.ClaimStartsAt) && sameOptionalTime(p.ClaimEndsAt, other.ClaimEndsAt) && p.SignupCutoffAt.Equal(other.SignupCutoffAt) && p.MaxClaims == other.MaxClaims
}

type ModelTokenGrant struct {
	ModelID         string    `json:"model_id"`
	TotalTokens     int64     `json:"total_tokens"`
	UsedTokens      int64     `json:"used_tokens"`
	ReservedTokens  int64     `json:"reserved_tokens"`
	RemainingTokens int64     `json:"remaining_tokens"`
	ClaimedAt       time.Time `json:"claimed_at"`
}

type ModelTokenReservation struct {
	ID                           string    `json:"id"`
	AccountID                    string    `json:"account_id"`
	ModelID                      string    `json:"model_id"`
	FreeTokens                   int64     `json:"free_tokens"`
	ReservedWithdrawableMicroUSD int64     `json:"reserved_withdrawable_micro_usd"`
	ReservedMicroUSD             int64     `json:"reserved_micro_usd"`
	GrossReservedMicroUSD        int64     `json:"gross_reserved_micro_usd"`
	State                        string    `json:"state"`
	UsedTokens                   int64     `json:"used_tokens"`
	ConsumerCostMicroUSD         int64     `json:"consumer_cost_micro_usd"`
	SponsoredMicroUSD            int64     `json:"sponsored_micro_usd"`
	CreatedAt                    time.Time `json:"created_at"`
	TouchedAt                    time.Time `json:"touched_at"`
}

// ModelTokenQuote must be pure: stores call it while holding the grant lock.
// It returns the full request price and the consumer price after free tokens.
type ModelTokenQuote func(freeTokens int64) (gross, paid int64, err error)

type ModelTokenSettlement struct {
	Reservation ModelTokenReservation
	Applied     bool
}

// Optional backend capability; use As so CachedStore does not hide it.
// Grants are account scoped and never cached. No method writes users or models.
type ModelTokenPromotionStore interface {
	RenewModelTokenReservations(ids []string, now time.Time) error
	ReleaseStaleModelTokenReservations(before time.Time) (int, error)
	PutModelTokenPromotion(ModelTokenPromotion) error
	ListModelTokenPromotions() ([]ModelTokenPromotion, error)
	ClaimModelTokenPromotion(accountID, modelID string, now time.Time) ([]ModelTokenGrant, error)
	ListModelTokenGrants(accountID string) ([]ModelTokenGrant, error)
	ReserveModelTokens(id, accountID, modelID string, tokens int64, quote ModelTokenQuote) (*ModelTokenReservation, error)
	TopUpModelTokenReservation(id string, tokens int64, quote ModelTokenQuote) (*ModelTokenReservation, error)
	ReleaseModelTokenReservation(id string) (bool, error)
	SettleModelTokenReservation(id string, actualTokens int64, quote ModelTokenQuote, earning *ProviderEarning) (ModelTokenSettlement, error)
}

func promotionQuote(quote ModelTokenQuote, free int64) (int64, int64, error) {
	if quote == nil {
		return 0, 0, errors.New("promotion quote is required")
	}
	gross, paid, err := quote(free)
	if err != nil {
		return 0, 0, err
	}
	if paid < 0 || gross < paid || gross > math.MaxInt64/2 {
		return 0, 0, errors.New("invalid promotion price")
	}
	return gross, paid, nil
}

func promotionSettlement(r ModelTokenReservation, actual int64, quote ModelTokenQuote, earning *ProviderEarning) (ModelTokenReservation, error) {
	if actual < 0 {
		return r, fmt.Errorf("%w: negative token usage", ErrPromotionInvalidSettlement)
	}
	used := min(actual, r.FreeTokens)
	gross, paid, err := promotionQuote(quote, used)
	if err != nil {
		return r, fmt.Errorf("%w: %v", ErrPromotionInvalidSettlement, err)
	}
	// Preserve the coordinator's fraud ceiling for provider-reported costs.
	if gross > 2*r.GrossReservedMicroUSD || paid > 2*r.ReservedMicroUSD && paid > 0 {
		return r, fmt.Errorf("%w: cost exceeds reservation ceiling", ErrPromotionInvalidSettlement)
	}
	if earning != nil && (earning.AccountID == "" || earning.JobID == "" || earning.AmountMicroUSD < 0 || earning.AmountMicroUSD > gross) {
		return r, fmt.Errorf("%w: invalid provider earning", ErrPromotionInvalidSettlement)
	}
	r.State, r.UsedTokens, r.ConsumerCostMicroUSD = "settled", used, paid
	r.SponsoredMicroUSD = gross - paid
	return r, nil
}
