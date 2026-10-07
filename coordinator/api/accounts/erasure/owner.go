// Package erasure owns the account erasure (GDPR) admin API, the loop that
// scrubs requests whose grace period has ended, and the outbox worker that
// delivers the scrub's Stripe and Privy deletions and erasure_log record. The flow is
// plan (dry run + confirm token), confirm (soft delete, grace period starts),
// then a background scrub after the grace period, or at once with force.
// Runbook: docs/operations/account-erasure.md.
package erasure

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Authorizer is the admin check and the API key cache of the access owner.
type Authorizer interface {
	IsAdminAuthorized(http.ResponseWriter, *http.Request) bool
	AdminKeyAuthorized(token string) bool
	InvalidateAllAPIKeyCache()
}

// Hooks clear the in-memory copies of an account's data that the store
// transaction cannot reach.
type Hooks struct {
	// DisconnectAccount disconnects the account's live providers and
	// returns how many it disconnected.
	DisconnectAccount func(accountID string) int
	// ForgetSEKeys drops the trust state of the erased Secure Enclave keys.
	ForgetSEKeys func(seKeys []string)
	// ForgetAccountTrust removes account-scoped cohort membership, including shared devices.
	ForgetAccountTrust func(accountID string)
	// ForgetConsumer drops the in-memory usage history of the account.
	ForgetConsumer func(accountID string)
}

// PrivyUsers deletes a Privy user; *auth.PrivyAuth implements it. It returns
// auth.ErrPrivyUserNotFound when Privy has no such user.
type PrivyUsers interface {
	DeleteUser(ctx context.Context, privyUserID string) error
}

type Dependencies struct {
	Store                      store.AccountErasureStore
	Access                     Authorizer
	Logger                     *slog.Logger
	Hooks                      Hooks
	MaxBodyBytes               int64
	SoftDeleteMutationsEnabled bool
	// Datadog returns the client that stores the erasure_log record. A nil
	// client, or one without DD_API_KEY, writes the record to the process log.
	Datadog func() *datadog.Client
}

type Owner struct {
	store                      store.AccountErasureStore
	access                     Authorizer
	logger                     *slog.Logger
	hooks                      Hooks
	maxBodyBytes               int64
	softDeleteMutationsEnabled bool
	datadog                    func() *datadog.Client
	// billing holds the Stripe clients the outbox worker deletes through.
	billing *billing.Service
	// privy deletes the Privy user of a privy_user outbox row.
	privy PrivyUsers
	// grace is the time from the soft delete to the scrub
	// (EIGENINFERENCE_ERASURE_GRACE).
	grace time.Duration
}

func New(d Dependencies) *Owner {
	grace, ignored := graceFromEnv()
	if ignored {
		d.Logger.Warn("EIGENINFERENCE_ERASURE_GRACE is not a valid non-negative Go duration; using the default",
			"default", defaultGrace)
	}
	return &Owner{store: d.Store, access: d.Access, logger: d.Logger, hooks: d.Hooks, maxBodyBytes: d.MaxBodyBytes, datadog: d.Datadog, grace: grace,
		softDeleteMutationsEnabled: d.SoftDeleteMutationsEnabled}
}

// SetBilling is called during application assembly, before the outbox loop starts.
func (s *Owner) SetBilling(service *billing.Service) { s.billing = service }

// SetPrivyUsers is called during application assembly, before the outbox loop
// starts. Without it, privy_user rows retry until they need manual action.
func (s *Owner) SetPrivyUsers(privy PrivyUsers) { s.privy = privy }
