package store

import "time"

func sameOptionalTime(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return a.Equal(*b)
}

func (p ModelTokenPromotion) claimError(user *User, now time.Time) error {
	if user == nil || user.PrivyUserID == "" || user.Role == RoleService || user.CreatedAt.IsZero() || !user.CreatedAt.Before(p.SignupCutoffAt) {
		return ErrPromotionIneligible
	}
	if !p.Enabled || now.Before(p.ClaimStartsAt) || (p.ClaimEndsAt != nil && !now.Before(*p.ClaimEndsAt)) {
		return ErrPromotionUnavailable
	}
	if p.ClaimedCount >= p.MaxClaims {
		return ErrPromotionFull
	}
	return nil
}

type ModelTokenOffer struct {
	ClaimEndsAt     *time.Time `json:"claim_ends_at"`
	ModelID         string     `json:"model_id"`
	Tokens          int64      `json:"tokens"`
	RemainingClaims int64      `json:"remaining_claims"`
	MaxClaims       int64      `json:"max_claims"`
	SignupCutoffAt  time.Time  `json:"signup_cutoff_at"`
	Status          string     `json:"status"`
}

func (p ModelTokenPromotion) Offer(user *User, now time.Time, claimed bool) ModelTokenOffer {
	status := "available"
	if claimed {
		status = "claimed"
	} else {
		switch p.claimError(user, now) {
		case ErrPromotionIneligible:
			status = "ineligible"
		case ErrPromotionFull:
			status = "sold_out"
		case ErrPromotionUnavailable:
			status = "unavailable"
		}
	}
	return ModelTokenOffer{ClaimEndsAt: p.ClaimEndsAt, ModelID: p.ModelID, Tokens: p.Tokens, RemainingClaims: max(p.MaxClaims-p.ClaimedCount, 0), MaxClaims: p.MaxClaims, SignupCutoffAt: p.SignupCutoffAt, Status: status}
}

func (p ModelTokenPromotion) clone() ModelTokenPromotion {
	if p.ClaimEndsAt != nil {
		end := *p.ClaimEndsAt
		p.ClaimEndsAt = &end
	}
	return p
}
