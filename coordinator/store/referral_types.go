package store

import "time"

// Referrer represents a registered referral partner.
type Referrer struct {
	AccountID string    `json:"account_id"`
	Code      string    `json:"code"`
	CreatedAt time.Time `json:"created_at"`
}

// ReferralStats provides aggregate metrics for a referral code.
type ReferralStats struct {
	Code                 string `json:"code"`
	TotalReferred        int    `json:"total_referred"`
	TotalRewardsMicroUSD int64  `json:"total_rewards_micro_usd"`
}
