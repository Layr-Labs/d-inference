// Package catalog owns model publication and the public model projections.
package catalog

import (
	"log/slog"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Store interface {
	store.ModelRegistryStore
	GetModelPrice(string, string) (store.ModelPrice, bool)
	SetModelPrice(store.ModelPrice) error
}

// Hooks preserve the synchronous publication ordering across domain owners.
type Hooks struct {
	ReconcilePromptArtifacts func([]store.ModelRegistryRecord) error
	IsDraining               func() bool
}

type Owner struct {
	registry             *registry.Registry
	store                Store
	access               *access.Owner
	readCache            *readcache.Cache
	logger               *slog.Logger
	hooks                Hooks
	modelCatalogSyncMu   sync.Mutex
	modelAliasMutationMu sync.Mutex
}

func New(reg *registry.Registry, st Store, auth *access.Owner, cache *readcache.Cache, logger *slog.Logger, hooks Hooks) *Owner {
	return &Owner{registry: reg, store: st, access: auth, readCache: cache, logger: logger, hooks: hooks}
}
