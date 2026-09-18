package store

import (
	"context"
	"encoding/json"
	"errors"
	"math"
	"time"
)

var (
	ErrTrialExhausted       = errors.New("trial allowance exhausted")
	ErrTrialBusy            = errors.New("trial allowance reserved by another request")
	ErrTrialRequestTooLarge = errors.New("request exceeds remaining trial allowance")
	ErrTrialUnavailable     = errors.New("trial storage unavailable")
	ErrTrialConflict        = errors.New("trial reservation identity or state conflict")
	ErrTrialInvalidUsage    = errors.New("invalid trial usage")
	ErrTrialNotFound        = errors.New("trial reservation not found")
)

type TrialState string

const (
	TrialReserved   TrialState = "reserved"
	TrialDispatched TrialState = "dispatched"
	TrialUnresolved TrialState = "unresolved"
	TrialReleased   TrialState = "released"
	TrialSettled    TrialState = "settled"
)

// TrialStore is discovered through As so decorators do not hide the capability.
// Dispatch intent must be persisted before sending work. Only evidence that no
// billable work occurred permits releasing a dispatched reservation. Unresolved
// reservations cannot be released by normal cleanup; they require validated
// settlement or a separately audited operator reconciliation.
// No method expires holds by age: a lost terminal must not reset a lifetime cap.
type TrialStore interface {
	ReserveTrial(context.Context, TrialReservation) (TrialReservation, error)
	MarkTrialDispatched(context.Context, string) error
	ReleaseTrial(context.Context, string, bool) error
	SettleTrial(context.Context, string, TrialSettlement) error
	GetTrialReservation(context.Context, string) (TrialReservation, error)
	GetTrialAllowance(context.Context, string, string) (TrialAllowance, error)
}

type TrialAllowance struct {
	AccountID      string
	CampaignID     string
	LimitTokens    int64
	UsedTokens     int64
	ReservedTokens int64
}

type TrialReservation struct {
	ID             string
	AccountID      string
	CampaignID     string
	Model          string
	LimitTokens    int64
	ReservedTokens int64
	UsedTokens     int64
	State          TrialState
	PricingJSON    json.RawMessage
	CreatedAt      time.Time
	UpdatedAt      time.Time
}

// TrialSettlement is trusted coordinator data, never a consumer payload.
// Subsidy is the platform-funded cost; Usage must have zero consumer cost.
// A positive subsidy requires a linked provider earning. Missing payout identity
// leaves work unresolved rather than silently dropping the provider credit.
type TrialSettlement struct {
	Usage            UsageRecord
	Earning          *ProviderEarning
	SubsidyMicroUSD  int64
	ServingRequestID string // committed provider attempt, for operational correlation
}

func validateTrialReservation(r TrialReservation) error {
	if r.ID == "" || r.AccountID == "" || r.CampaignID == "" || r.Model == "" || r.LimitTokens <= 0 || r.ReservedTokens <= 0 {
		return ErrTrialConflict
	}
	if len(r.PricingJSON) > 0 && !json.Valid(r.PricingJSON) {
		return ErrTrialConflict
	}
	return nil
}

func sameTrialReservation(a, b TrialReservation) bool {
	return a.ID == b.ID && a.AccountID == b.AccountID && a.CampaignID == b.CampaignID && a.Model == b.Model && a.LimitTokens == b.LimitTokens && a.ReservedTokens == b.ReservedTokens && string(a.PricingJSON) == string(b.PricingJSON)
}

func trialAdmissionError(a TrialAllowance, requested int64) error {
	if a.UsedTokens >= a.LimitTokens {
		return ErrTrialExhausted
	}
	if requested > a.LimitTokens-a.UsedTokens {
		return ErrTrialRequestTooLarge
	}
	if requested > a.LimitTokens-a.UsedTokens-a.ReservedTokens {
		return ErrTrialBusy
	}
	return nil
}

func validateTrialSettlement(r TrialReservation, s TrialSettlement) (int64, error) {
	u := s.Usage
	if u.PromptTokens < 0 || u.CompletionTokens < 0 || int64(u.PromptTokens) > math.MaxInt64-int64(u.CompletionTokens) {
		return 0, ErrTrialInvalidUsage
	}
	tokens := int64(u.PromptTokens) + int64(u.CompletionTokens)
	if tokens > r.ReservedTokens || u.ConsumerKey != r.AccountID || u.RequestID != r.ID || u.Model != r.Model || u.KeyID != "" || u.CostMicroUSD != 0 || s.SubsidyMicroUSD < 0 {
		return 0, ErrTrialInvalidUsage
	}
	if s.SubsidyMicroUSD > 0 && s.Earning == nil {
		return 0, ErrTrialInvalidUsage
	}
	if e := s.Earning; e != nil {
		if e.AccountID == "" || e.JobID != r.ID || e.ProviderID != u.ProviderID || e.Model != u.Model || e.PromptTokens != u.PromptTokens || e.CompletionTokens != u.CompletionTokens || e.AmountMicroUSD < 0 || e.AmountMicroUSD > s.SubsidyMicroUSD {
			return 0, ErrTrialInvalidUsage
		}
	}
	return tokens, nil
}

func copyTrialReservation(r TrialReservation) TrialReservation {
	r.PricingJSON = append(json.RawMessage(nil), r.PricingJSON...)
	return r
}
