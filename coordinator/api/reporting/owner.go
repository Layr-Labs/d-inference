// Package reporting owns public network projections and their refresh flights.
package reporting

import (
	"log/slog"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	ranking "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/ranking"
	refresher "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/refresher"
	statsview "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/statsview"
	totalsview "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/totalsview"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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
	*refresher.Service
	*statsview.Stats
	*totalsview.Totals
	*ranking.Ranking
	store              store.Store
	registry           *registry.Registry
	readCache          *readcache.Cache
	logger             *slog.Logger
	ddIncr             func(string, []string)
	requireAdminKey    func(http.ResponseWriter, *http.Request) bool
	modelDemandRefresh [3]refresher.Entry
}

func New(deps Dependencies) *Owner {
	incr := deps.Incr
	if incr == nil {
		incr = func(string, []string) {}
	}
	refresh := refresher.New(deps.Cache, deps.Logger, incr)
	return &Owner{
		Service: refresh,
		Stats:   statsview.New(deps.Store, deps.Registry, deps.Cache, deps.Logger, incr, refresh),
		Totals:  totalsview.New(deps.Store, refresh),
		Ranking: ranking.New(deps.Store, deps.Cache, deps.Logger, incr),
		store:   deps.Store, registry: deps.Registry, readCache: deps.Cache,
		logger: deps.Logger, ddIncr: incr, requireAdminKey: deps.RequireAdminKey,
	}
}
