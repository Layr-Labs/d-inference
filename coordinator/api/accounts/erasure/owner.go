// Package erasure owns the account erasure (GDPR) admin API and the loop that
// scrubs requests whose grace period has ended. The flow is plan (dry run +
// confirm token), confirm (soft delete, grace period starts), then a
// background scrub after the grace period, or at once with force. Runbook:
// docs/operations/account-erasure.md.
package erasure

import (
	"log/slog"
	"net/http"
	"time"

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
	// ForgetConsumer drops the in-memory usage history of the account.
	ForgetConsumer func(accountID string)
}

type Dependencies struct {
	Store        store.AccountErasureStore
	Access       Authorizer
	Logger       *slog.Logger
	Hooks        Hooks
	MaxBodyBytes int64
}

type Owner struct {
	store        store.AccountErasureStore
	access       Authorizer
	logger       *slog.Logger
	hooks        Hooks
	maxBodyBytes int64
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
	return &Owner{store: d.Store, access: d.Access, logger: d.Logger, hooks: d.Hooks, maxBodyBytes: d.MaxBodyBytes, grace: grace}
}
