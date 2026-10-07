package store

import "time"

// RewardLedgerTypes are the ledger entry types that represent non-inference
// "reward" earnings (network participation incentives) counted on the
// leaderboard separately from inference work earnings.
var RewardLedgerTypes = []LedgerEntryType{LedgerReferralReward, LedgerAdminReward}

// IsRewardLedgerType reports whether t is counted as reward earnings.
func IsRewardLedgerType(t LedgerEntryType) bool {
	for _, rt := range RewardLedgerTypes {
		if t == rt {
			return true
		}
	}
	return false
}

// LedgerEntryType categorizes balance changes.
type LedgerEntryType string

const (
	LedgerDeposit        LedgerEntryType = "deposit"             // consumer funds account
	LedgerCharge         LedgerEntryType = "charge"              // consumer pays for inference
	LedgerPayout         LedgerEntryType = "payout"              // provider credited for serving
	LedgerPlatformFee    LedgerEntryType = "platform_fee"        // Darkbloom platform cut
	LedgerWithdrawal     LedgerEntryType = "withdrawal"          // on-chain withdrawal
	LedgerReferralReward LedgerEntryType = "referral_reward"     // referrer earns 5% of collected consumer token spend
	LedgerStripeDeposit  LedgerEntryType = "stripe_deposit"      // Stripe checkout deposit
	LedgerStripePayout   LedgerEntryType = "stripe_payout"       // user-initiated bank/card withdrawal via Stripe Connect
	LedgerInviteCredit   LedgerEntryType = "invite_credit"       // invite code redemption
	LedgerRefund         LedgerEntryType = "refund"              // reservation refund (request failed before inference)
	LedgerAdminCredit    LedgerEntryType = "admin_credit"        // admin-granted non-withdrawable credit
	LedgerAdminReward    LedgerEntryType = "admin_reward"        // admin-granted withdrawable reward
	LedgerMigration      LedgerEntryType = "migration"           // balance moved between account identities (e.g. legacy key re-keying)
	LedgerFloorDraw      LedgerEntryType = "provider_floor_draw" // base-rewards epoch base income (additive)
)

// LedgerEntry is a single balance-changing event.
type LedgerEntry struct {
	ID             int64           `json:"id"`
	AccountID      string          `json:"account_id"`
	Type           LedgerEntryType `json:"type"`
	AmountMicroUSD int64           `json:"amount_micro_usd"` // positive = credit, negative = debit
	BalanceAfter   int64           `json:"balance_after"`
	Reference      string          `json:"reference"` // job ID, tx hash, etc.
	CreatedAt      time.Time       `json:"created_at"`
}
