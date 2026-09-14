// Package requestauth authenticates HTTP credentials, owns the API-key cache,
// and installs the shared account, user and key identity for downstream handlers.
package requestauth

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Store is the persistence surface used while authenticating a request.
type Store interface {
	AuthenticateKey(string) (*store.APIKey, error)
	TouchAPIKey(string, time.Time)
	MigrateAccountBalance(string, string) (bool, error)
	GetProviderToken(string) (*store.ProviderToken, error)
	GetUserByAccountID(string) (*store.User, error)
}

// Settings supplies the current runtime configuration for each request. The
// getter passed to the middleware must return the current store and credentials,
// so changes made after routes are registered remain visible. Store is itself
// a getter so asynchronous last-used writes resolve the current store without
// re-reading unrelated credential configuration. SetStage and
// StampAuth connect existing request accounting and profiling; both are required.
// Configuration changes keep the router's existing synchronization contract.
type Settings struct {
	Store     func() Store
	Logger    *slog.Logger
	PrivyAuth *auth.PrivyAuth
	AdminKey  string
	SetStage  func(*http.Request, string)
	StampAuth func(*http.Request, string, bool)
}

// Authenticator owns key-cache state shared by all authentication middleware.
// Create it once per server with New; do not copy it after use.
type Authenticator struct {
	keys keyCache
}

// New creates an authenticator with an empty positive and negative key cache.
func New() *Authenticator {
	return &Authenticator{keys: keyCache{entries: make(map[string]keyEntry)}}
}

// InvalidateKey removes a raw token after revocation.
func (a *Authenticator) InvalidateKey(token string) { a.keys.invalidate(token) }

// InvalidateAllKeys advances the shared cache generation. Call before and after
// a by-ID key mutation to discard entries filled from pre-commit state.
func (a *Authenticator) InvalidateAllKeys() { a.keys.invalidateAll() }
