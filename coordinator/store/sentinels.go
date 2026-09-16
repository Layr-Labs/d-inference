package store

import (
	"github.com/eigeninference/d-inference/coordinator/store/contracts"
)

var (
	ErrInviteCredit        = contracts.ErrInviteCredit
	ErrPayoutConflict      = contracts.ErrPayoutConflict
	ErrPayoutQuoteExpired  = contracts.ErrPayoutQuoteExpired
	ErrInsufficientBalance = contracts.ErrInsufficientBalance
	ErrNotFound            = contracts.ErrNotFound
	RewardLedgerTypes      = contracts.RewardLedgerTypes
)
