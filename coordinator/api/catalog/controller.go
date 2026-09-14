// Package catalog owns model discovery, publishing, and alias HTTP operations.
// Routing snapshots and catalog publication remain dependencies of the owner.
package catalog

import (
	"log/slog"
	"net/http"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// ModelViews supplies read-only views of the live fleet. The registry retains
// provider locks, routing policy, and reservation state.
type ModelViews interface {
	ListModels() []registry.AggregateModel
	ModelCapacitySnapshot() []registry.ModelCapacity
	OwnedModels(accountID string) []registry.AggregateModel
	ModelCountryCodes(modelID string) []string
}

// Dependencies binds the catalog to the API's current persistence and runtime
// configuration. Cache must be the same instance invalidated by catalog sync.
// Store and AdminKey are getters so post-construction updates remain visible.
// SelfRouteAccount uses the existing authenticated routing policy; it returns
// true only for exclusive self-route. SyncCatalog retains the API's synchronous
// catalog reread and publication; a successful reread invalidates this shared
// cache. The callback retains its existing log-and-return handling of read errors.
type Dependencies struct {
	Store            func() Store
	Models           ModelViews
	Cache            *readcache.Cache
	Logger           *slog.Logger
	AdminKey         func() string
	SelfRouteAccount func(*http.Request) (accountID string, enabled bool)
	SyncCatalog      func()
}

// Controller owns the shared alias mutation lock and catalog operations.
// Create one per server; standard and marketplace aliases must use the same
// instance so cross-endpoint ownership checks stay serialized.
type Controller struct {
	store                func() Store
	registry             ModelViews
	readCache            *readcache.Cache
	logger               *slog.Logger
	adminKey             func() string
	selfRouteAccount     func(*http.Request) (string, bool)
	syncCatalog          func()
	modelAliasMutationMu sync.Mutex
}

// New binds dependencies without loading the catalog or starting background work.
func New(deps Dependencies) *Controller {
	return &Controller{
		store: deps.Store, registry: deps.Models, readCache: deps.Cache,
		logger: deps.Logger, adminKey: deps.AdminKey,
		selfRouteAccount: deps.SelfRouteAccount, syncCatalog: deps.SyncCatalog,
	}
}

type selfRoutePolicy struct {
	ownerAccountID string
	enabled        bool
}

func (s *Controller) selfRoute(r *http.Request) selfRoutePolicy {
	accountID, enabled := s.selfRouteAccount(r)
	return selfRoutePolicy{ownerAccountID: accountID, enabled: enabled}
}
