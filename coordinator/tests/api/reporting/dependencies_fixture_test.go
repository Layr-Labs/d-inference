package reporting_test

import (
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	production "github.com/eigeninference/d-inference/coordinator/api/reporting"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Retain supplied dependencies rather than reaching into a production owner.
type reportingFixture struct {
	*production.Owner
	deps      production.Dependencies
	store     store.Store
	registry  *registry.Registry
	readCache *readcache.Cache
}

func newReportingFixture(deps production.Dependencies) *reportingFixture {
	return &reportingFixture{Owner: production.New(deps), deps: deps, store: deps.Store, registry: deps.Registry, readCache: deps.Cache}
}
