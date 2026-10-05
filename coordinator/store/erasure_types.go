package store

import (
	"context"
	"errors"
	"time"
)

// Account erasure (GDPR) runs in three steps. An admin plans it (a dry run
// that returns a confirm token), confirms it (soft delete: the account is
// hidden and its keys and tokens are revoked), and after the grace period
// ScrubAccount removes the personal data in one transaction. The rules for
// each table are in coordinator/internal/store/erasure/rules.go.

// ErasureState is the state of an erasure request.
type ErasureState string

const (
	ErasurePlanned  ErasureState = "planned"  // dry run done; waits for confirmation
	ErasurePending  ErasureState = "pending"  // soft deleted; in the grace period
	ErasureErased   ErasureState = "erased"   // personal data scrubbed
	ErasureCanceled ErasureState = "canceled" // canceled during the grace period
)

// ErasureTarget is the kind of external deletion in erasure_outbox.
type ErasureTarget string

const (
	ErasureTargetStripeAccount    ErasureTarget = "stripe_account"    // Stripe Connect Express account
	ErasureTargetGlobalRecipient  ErasureTarget = "global_recipient"  // Stripe Global Payouts recipient account
	ErasureTargetCheckoutSessions ErasureTarget = "checkout_sessions" // up to ErasureCheckoutBatch Checkout Session IDs, comma separated
	ErasureTargetErasureLog       ErasureTarget = "erasure_log"       // durable log record of the erasure
)

// ErasureOutboxState is the delivery state of an erasure_outbox row.
type ErasureOutboxState string

const (
	ErasureOutboxPending      ErasureOutboxState = "pending"
	ErasureOutboxDone         ErasureOutboxState = "done"
	ErasureOutboxManualAction ErasureOutboxState = "manual_action"
)

const (
	// ErasureCheckoutBatch is the most Checkout Session IDs in one outbox row:
	// one Stripe redaction job takes at most 10 objects.
	ErasureCheckoutBatch = 10
	// LedgerErasureForfeit zeroes the balance of an erased account.
	LedgerErasureForfeit LedgerEntryType = "erasure_forfeit"
)

var (
	// ErrErasureConflict: the request is not in a state that allows the step.
	ErrErasureConflict = errors.New("erasure: request is not in a state that allows this step")
	// ErrErasureConfirmToken: the confirm token is wrong or expired.
	ErrErasureConfirmToken = errors.New("erasure: confirm token is invalid or expired")
	// ErrErasureEmailMismatch: the confirming email is not the account email.
	ErrErasureEmailMismatch = errors.New("erasure: email does not match the account")
	// ErrErasureWalletMismatch: the confirming wallet list is not the planned one.
	ErrErasureWalletMismatch = errors.New("erasure: wallet addresses differ from the plan")
	// ErrErasureOpenWithdrawal: a withdrawal of the account is not terminal.
	ErrErasureOpenWithdrawal = errors.New("erasure: account has a withdrawal that is not in a terminal state")
	// ErrErasureCountMismatch: a scrub statement changed a different number
	// of rows than the count read in the same transaction. Nothing commits.
	ErrErasureCountMismatch = errors.New("erasure: affected rows differ from the count")
)

// ErasureRowCount is the number of rows one scrub rule changes.
type ErasureRowCount struct {
	Rule    string   `json:"rule"`
	Table   string   `json:"table"`
	Columns []string `json:"columns,omitempty"`
	Action  string   `json:"action"`
	Rows    int64    `json:"rows"`
}

// ErasureRetained is data the scrub keeps on purpose, with the reason.
type ErasureRetained struct {
	Table  string `json:"table"`
	Rows   int64  `json:"rows"`
	Reason string `json:"reason"`
}

// ErasureStripeObject is one Stripe object that the outbox will delete or
// redact. Plans return them to the admin; they are never stored in a plan.
type ErasureStripeObject struct {
	Target ErasureTarget `json:"target"`
	ID     string        `json:"id"`
}

// ErasureCounts is the part of a plan that is stored in erasure_requests.plan:
// counts only, no personal data and no Stripe IDs.
type ErasureCounts struct {
	Rows                 []ErasureRowCount       `json:"rows"`
	Retained             []ErasureRetained       `json:"retained,omitempty"`
	StripeObjectCounts   map[ErasureTarget]int64 `json:"stripe_object_counts,omitempty"`
	BalanceMicroUSD      int64                   `json:"balance_micro_usd"`
	WithdrawableMicroUSD int64                   `json:"withdrawable_micro_usd"`
	OpenWithdrawals      int64                   `json:"open_withdrawals"`
}

// ErasureSummary is the JSON in erasure_requests.plan.
type ErasureSummary struct {
	Planned *ErasureCounts `json:"planned,omitempty"`
	Applied *ErasureCounts `json:"applied,omitempty"`
}

// ErasurePlan is the dry run of an erasure. Email and StripeObjects are shown
// to the admin and never stored.
type ErasurePlan struct {
	AccountID     string                `json:"account_id"`
	Email         string                `json:"email"`
	StripeObjects []ErasureStripeObject `json:"stripe_objects"`
	Wallets       []ErasureWalletCount  `json:"wallets"`
	ErasureCounts
}

// ErasureWalletCount is how many rows hold one wallet address of the plan.
type ErasureWalletCount struct {
	Address              string `json:"address"`
	PaymentsConsumerRows int64  `json:"payments_consumer_rows"`
	PaymentsProviderRows int64  `json:"payments_provider_rows"`
	ProviderPayoutRows   int64  `json:"provider_payouts_rows"`
}

// ErasureRefusedCredit is a credit that arrived after the account was
// erased. The balance stays zero; an operator reviews the record.
type ErasureRefusedCredit struct {
	ID             int64           `json:"id"`
	AccountID      string          `json:"account_id"`
	EntryType      LedgerEntryType `json:"entry_type"`
	AmountMicroUSD int64           `json:"amount_micro_usd"`
	Reference      string          `json:"reference"`
	CreatedAt      time.Time       `json:"created_at"`
}

// ErasureRequest is one row of erasure_requests, without the confirm token
// hash and the wallet addresses.
type ErasureRequest struct {
	ID                 string         `json:"id"`
	AccountID          string         `json:"account_id"`
	Actor              string         `json:"actor"`
	CanceledBy         string         `json:"canceled_by,omitempty"`
	Reason             string         `json:"reason,omitempty"`
	State              ErasureState   `json:"state"`
	Summary            ErasureSummary `json:"summary"`
	ConfirmExpiresAt   *time.Time     `json:"confirm_expires_at,omitempty"`
	WalletAddressCount int            `json:"wallet_address_count"`
	RequestedAt        *time.Time     `json:"requested_at,omitempty"`
	ScrubAfter         *time.Time     `json:"scrub_after,omitempty"`
	ErasedAt           *time.Time     `json:"erased_at,omitempty"`
	CanceledAt         *time.Time     `json:"canceled_at,omitempty"`
	LastError          string         `json:"last_error,omitempty"`
	CreatedAt          time.Time      `json:"created_at"`
}

// ErasureOutboxItem is one erasure_outbox row. ExternalID is never returned
// by the admin API; HasExternalID says whether the row still holds one.
type ErasureOutboxItem struct {
	ID            string             `json:"id"`
	RequestID     string             `json:"request_id"`
	Target        ErasureTarget      `json:"target"`
	State         ErasureOutboxState `json:"state"`
	Attempts      int                `json:"attempts"`
	NextAt        time.Time          `json:"next_at"`
	LastError     string             `json:"last_error,omitempty"`
	DoneAt        *time.Time         `json:"done_at,omitempty"`
	HasExternalID bool               `json:"has_external_id"`
	HasStripeJob  bool               `json:"has_stripe_job"`
	CreatedAt     time.Time          `json:"created_at"`
	ExternalID    string             `json:"-"`
	StripeJobID   string             `json:"-"` // redaction job of a checkout_sessions row
	// JobStatus is the last Stripe status seen for StripeJobID, since
	// JobStatusSince; JobGeneration changes the job's idempotency key.
	JobStatus      string     `json:"-"`
	JobStatusSince *time.Time `json:"-"`
	JobGeneration  int        `json:"-"`
}

// ErasureOutboxWork is a leased outbox row plus the request fields the
// worker needs for the erasure_log record.
type ErasureOutboxWork struct {
	ErasureOutboxItem
	AccountID string
	ErasedAt  time.Time
}

// ErasureOutboxResult is the new state of a delivered outbox row. State done
// clears the external ID and the job ID and sets done_at to NextAt.
type ErasureOutboxResult struct {
	State          ErasureOutboxState
	Attempts       int
	NextAt         time.Time
	LastError      string
	ExternalID     string // the row's IDs from now on; ignored when done
	StripeJobID    string
	JobStatus      string
	JobStatusSince *time.Time
	JobGeneration  int
	// Split, when set, is a manual_action row written in the same
	// transaction: Checkout Sessions Stripe cannot find with the current key.
	Split *ErasureOutboxItem
}

// ErasureConfirm is the input of RequestAccountErasure.
type ErasureConfirm struct {
	AccountID       string
	ConfirmToken    string // raw token from the plan; compared by hash
	Email           string // must equal the account email (case and space insensitive)
	Actor           string
	Reason          string
	WalletAddresses []string
	Now             time.Time
	Grace           time.Duration
}

// ErasureResult is what ScrubAccount changed. SEKeys and ProviderIDs let the
// caller clear in-memory copies after the commit.
type ErasureResult struct {
	Request     *ErasureRequest
	SEKeys      []string
	ProviderIDs []string
}

// AccountErasureStore erases one account. Every method that writes the users
// table is overridden by CachedStore, so call these through the Store, not
// through store.As.
type AccountErasureStore interface {
	// PlanAccountErasure counts what an erasure of accountID would change.
	// walletAddresses are counted in payments and provider_payouts. It writes
	// nothing.
	PlanAccountErasure(ctx context.Context, accountID string, walletAddresses []string) (*ErasurePlan, error)

	// SaveErasurePlan stores the planned request with the hashes of a confirm
	// token that expires at expiresAt and of the planned wallet list. It
	// replaces an earlier planned request of the account and refuses with
	// ErrErasureConflict while one is pending.
	SaveErasurePlan(ctx context.Context, accountID, actor string, counts ErasureCounts, walletAddresses []string, confirmToken string, expiresAt time.Time) (*ErasureRequest, error)

	// RequestAccountErasure checks the token and email, soft deletes the
	// account (users and providers get deleted_at; API keys and provider
	// tokens are revoked and get deleted_at) and starts the grace period.
	RequestAccountErasure(ctx context.Context, in ErasureConfirm) (*ErasureRequest, error)

	// CancelAccountErasure ends a pending request before scrub_after. Users
	// and providers are live again; API keys and provider tokens stay revoked.
	CancelAccountErasure(ctx context.Context, accountID, actor string, now time.Time) (*ErasureRequest, error)

	// ScrubAccount applies every rule in erasure.Rules in one transaction,
	// forfeits the balance, writes the outbox rows and marks the request
	// erased. It refuses with ErrErasureOpenWithdrawal and aborts with
	// ErrErasureCountMismatch.
	ScrubAccount(ctx context.Context, requestID string, now time.Time) (*ErasureResult, error)

	// GetAccountErasure returns the newest request of the account and its
	// outbox rows, or ErrNotFound.
	GetAccountErasure(ctx context.Context, accountID string) (*ErasureRequest, []ErasureOutboxItem, error)

	// LeaseDueAccountErasures leases up to limit pending requests whose
	// scrub_after has passed, until now+lease, and returns their IDs.
	LeaseDueAccountErasures(ctx context.Context, now time.Time, lease time.Duration, limit int) ([]string, error)

	// ListErasureRefusedCredits returns the credits refused after the
	// account was erased, oldest first (at most 500).
	ListErasureRefusedCredits(ctx context.Context, accountID string) ([]ErasureRefusedCredit, error)

	// RecordAccountErasureFailure stores the last scrub error of a request.
	RecordAccountErasureFailure(ctx context.Context, requestID, message string) error

	// LeaseDueErasureOutbox leases up to limit pending outbox rows whose
	// next_at has passed, until now+lease.
	LeaseDueErasureOutbox(ctx context.Context, now time.Time, lease time.Duration, limit int) ([]ErasureOutboxWork, error)

	// SaveErasureOutboxResult stores the outcome of one delivery attempt and
	// ends the lease. It changes only a pending row.
	SaveErasureOutboxResult(ctx context.Context, id string, r ErasureOutboxResult) error

	// PrivyUserPendingErasure reports whether a soft-deleted account holds
	// this Privy user ID. Login refuses such an account.
	PrivyUserPendingErasure(ctx context.Context, privyUserID string) (bool, error)
}
