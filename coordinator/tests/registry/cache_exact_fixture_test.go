package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Sequential setup retains the exact tracker dependencies supplied to the
// registry. Routing and receipt transitions still enter through the registry.
type exactRoutingFixture struct {
	*production.Registry
	plans     preparationFixture
	tracker   *cachetracker.Tracker[*production.Provider]
	config    cachetracker.Config[*production.Provider]
	query     production.CacheHintQuerier
	admission production.CacheReceiptAdmitter
	routeKey  []byte
}

func newExactRoutingFixture(t *testing.T, dependencies ...production.Dependencies) (*exactRoutingFixture, *production.Provider, protocol.PrefixCacheV2Capability) {
	t.Helper()
	f := &exactRoutingFixture{
		routeKey: cacheactivation.HMACBytes([]byte("0123456789abcdef0123456789abcdef"), []byte("darkbloom/cache-routing/route/v3")),
	}
	var deps production.Dependencies
	if len(dependencies) != 0 {
		deps = dependencies[0]
	}
	deps.Cache.Trackers = func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
		f.config = config
		f.plans.generation = config.Generation
		f.tracker = cachetracker.New(config)
		return f.tracker
	}
	deps.Cache.HintQueries = func(query production.CacheHintQuery) production.CacheHintQuerier {
		f.query = query
		return query
	}
	deps.Cache.ReceiptAdmissions = func(admission production.CacheReceiptAdmission) production.CacheReceiptAdmitter {
		f.admission = admission
		return admission
	}
	r, p, capability := exactTestRegistry(t, deps)
	f.Registry = r
	return f, p, capability
}

func boundTestCachePlan(r *exactRoutingFixture, plan production.CachePlan) production.CachePlan {
	return r.plans.bind(plan)
}

func prepareBoundTestCacheAttempt(r *exactRoutingFixture, pr *production.PendingRequest, provider *production.Provider) error {
	if !pr.CachePlan.HasOrigin() {
		pr.CachePlan = boundTestCachePlan(r, pr.CachePlan)
	}
	return r.PrepareCacheAttempt(pr, provider)
}

func preparedTestCacheMetadata(pr *production.PendingRequest) protocol.InferenceRequestMessage {
	return pr.CacheAttemptSnapshot().MetadataMessage()
}

func (r *exactRoutingFixture) hints(plan production.CachePlan, capabilities map[string]production.CacheRoutingCapability, now time.Time) map[string]production.CacheRoutingHint {
	if !plan.HasOrigin() {
		plan = r.plans.bind(plan)
	}
	keys := make([]string, len(plan.Boundaries))
	for i, anchor := range plan.Boundaries {
		keys[i] = plan.BoundaryKey(r.routeKey, anchor)
	}
	return production.CacheHintsForMatches(plan, r.tracker.MatchBoundaries(plan, keys, now), capabilities)
}

func exactHintCurrent(hint production.CacheRoutingHint, provider *production.Provider) bool {
	provider.Mu().Lock()
	defer provider.Mu().Unlock()
	return hint.CurrentForProviderLocked(provider, "model")
}
