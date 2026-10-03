// Package reporting owns public network projections and their refresh flights.
package reporting

import (
	"log/slog"
	"net/http"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"golang.org/x/sync/singleflight"
)

type Dependencies struct {
	Store           store.Store
	Registry        *registry.Registry
	Cache           *readcache.Cache
	Logger          *slog.Logger
	Incr            func(string, []string)
	RequireAdminKey func(http.ResponseWriter, *http.Request) bool
}

// Owner holds reporting's mutable state. Cache is supplied by the composition
// root and shared with the other read domains, never cloned here.
type Owner struct {
	store                 store.Store
	registry              *registry.Registry
	readCache             *readcache.Cache
	logger                *slog.Logger
	ddIncr                func(string, []string)
	requireAdminKey       func(http.ResponseWriter, *http.Request) bool
	leaderboardFlights    singleflight.Group
	statsRefresh          cacheRefresher
	statsGeographyRefresh cacheRefresher
	networkTotalsRefresh  struct {
		queryMu sync.Mutex
		mu      sync.Mutex
		entries map[string]*cacheRefresher
	}
	modelDemandRefresh [3]cacheRefresher
}

func New(deps Dependencies) *Owner {
	incr := deps.Incr
	if incr == nil {
		incr = func(string, []string) {}
	}
	return &Owner{
		store: deps.Store, registry: deps.Registry, readCache: deps.Cache,
		logger: deps.Logger, ddIncr: incr, requireAdminKey: deps.RequireAdminKey,
	}
}
