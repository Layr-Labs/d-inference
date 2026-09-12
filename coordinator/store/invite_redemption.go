package store

import "errors"

// ErrInviteCredit identifies a balance or ledger write failure during invite
// redemption. The store rolls back the claim so the same invite can be retried.
var ErrInviteCredit = errors.New("invite credit failed")
