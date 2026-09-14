// Package accounts owns API-key management, key access/spend policy, provider
// device login and invite operations. Authentication, route middleware and live
// provider registration remain with their separate owners.
package accounts

import (
	"log/slog"
	"net/http"
)

// KeyCache is the existing shared authentication cache's mutation interface.
// No account controller keeps a second cache.
type KeyCache interface {
	InvalidateKey(string)
	InvalidateAllKeys()
}

// Dependencies keeps runtime store/configuration reads and admin authorization
// connected to the router. The getters and callbacks are required; they preserve
// configuration installed after routes were registered.
type Dependencies struct {
	Store          func() Store
	Logger         *slog.Logger
	ConsoleURL     func() string
	KeyCache       KeyCache
	AuthorizeAdmin func(http.ResponseWriter, *http.Request) bool
}

// Controller owns account endpoint policy without duplicating authentication,
// store, ledger or provider state.
type Controller struct {
	store          func() Store
	logger         *slog.Logger
	consoleURL     func() string
	keyCache       KeyCache
	authorizeAdmin func(http.ResponseWriter, *http.Request) bool
}

// New binds account operations to their current services.
func New(d Dependencies) *Controller {
	return &Controller{store: d.Store, logger: d.Logger, consoleURL: d.ConsoleURL,
		keyCache: d.KeyCache, authorizeAdmin: d.AuthorizeAdmin}
}
