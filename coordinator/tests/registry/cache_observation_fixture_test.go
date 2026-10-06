package registry_test

import (
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheactivation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheindex"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepeer"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachetracker"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// Retain the actual production components at construction, including the
// generation-bound query and receipt effects; no second registry state exists.
type cacheObservationFixture struct {
	*production.Registry
	plans      preparationFixture
	clock      *fenceTestClock
	core       *cachetracker.Tracker[*production.Provider]
	config     cachetracker.Config[*production.Provider]
	fences     *cacheindex.Records[cachetracker.FenceKey, cachetracker.FenceRecord]
	revisions  map[string]*cachepeer.Revision
	demand     *cachedemand.Tracker
	query      production.CacheHintQuerier
	admission  production.CacheReceiptAdmitter
	quarantine production.CacheQuarantine
	routeKey   []byte
}

type deferredObservationQuarantine struct{}

func (deferredObservationQuarantine) Apply() {}

func newCacheObservationFixture(t *testing.T, inputs ...production.CacheDependencies) (*cacheObservationFixture, *production.Provider, protocol.PrefixCacheV2Capability) {
	t.Helper()
	var input production.CacheDependencies
	if len(inputs) != 0 {
		input = inputs[0]
	}
	return newCacheObservationFixtureWithDependencies(t, production.Dependencies{Cache: input})
}

func newCacheObservationFixtureWithDependencies(t *testing.T, deps production.Dependencies) (*cacheObservationFixture, *production.Provider, protocol.PrefixCacheV2Capability) {
	t.Helper()
	input := deps.Cache
	f := &cacheObservationFixture{clock: &fenceTestClock{now: time.Now()}, revisions: make(map[string]*cachepeer.Revision),
		routeKey: cacheactivation.HMACBytes([]byte("0123456789abcdef0123456789abcdef"), []byte("darkbloom/cache-routing/route/v3"))}
	deps.Cache = production.CacheDependencies{
		SnapshotCommits:   input.SnapshotCommits,
		QuarantineCommits: input.QuarantineCommits,
		Affinities:        input.Affinities,
		Now:               f.clock.Now,
		Generations: func() *cacheplan.Generation {
			f.plans.generation = &cacheplan.Generation{}
			return f.plans.generation
		},
		Trackers: func(config cachetracker.Config[*production.Provider]) *cachetracker.Tracker[*production.Provider] {
			f.config, f.core = config, cachetracker.New(config)
			return f.core
		},
		Fences: func() *cacheindex.Records[cachetracker.FenceKey, cachetracker.FenceRecord] {
			f.fences = cacheindex.NewRecords[cachetracker.FenceKey, cachetracker.FenceRecord]()
			return f.fences
		},
		Revisions: func(id string) *cachepeer.Revision {
			revision := cachepeer.NewRevision()
			f.revisions[id] = revision
			return revision
		},
		Demand: func(limit int, ttl time.Duration, index *cachehistory.Index) *cachedemand.Tracker {
			f.demand = cachedemand.New(limit, ttl, index)
			return f.demand
		},
		HintQueries: func(query production.CacheHintQuery) production.CacheHintQuerier { f.query = query; return query },
		ReceiptAdmissions: func(admission production.CacheReceiptAdmission) production.CacheReceiptAdmitter {
			f.admission = admission
			return admission
		},
		Quarantines: func(q production.CacheQuarantine) production.CacheQuarantiner {
			f.quarantine = q
			return deferredObservationQuarantine{}
		},
	}
	r, p, capability := exactTestRegistry(t, deps)
	f.Registry = r
	return f, p, capability
}

type observationSnapshotCommit struct {
	production.CacheSnapshotCommit
	entered *atomic.Bool
}

func (commit observationSnapshotCommit) Commit() (production.CacheSnapshotResult, error) {
	commit.entered.Store(true)
	return commit.CacheSnapshotCommit.Commit()
}

type observationQuarantineCommit struct {
	production.CacheQuarantineCommit
	entered *atomic.Bool
}

func (commit observationQuarantineCommit) Apply() {
	commit.entered.Store(true)
	commit.CacheQuarantineCommit.Apply()
}

// This writer touches no provider mutex or cache state. Disconnect alone cannot
// prove root ownership: it would also block on the provider mutex held by tests.
func assertObservationRootOwned(t *testing.T, r *production.Registry) <-chan struct{} {
	t.Helper()
	started, done := make(chan struct{}), make(chan struct{})
	go func() {
		close(started)
		r.SetModelAliases(nil)
		close(done)
	}()
	<-started
	select {
	case <-done:
		t.Fatal("cache commit released registry ownership before provider mutation")
	case <-time.After(50 * time.Millisecond):
	}
	return done
}

func (f *cacheObservationFixture) hints(plan production.CachePlan, now time.Time) map[string]production.CacheRoutingHint {
	hints, _ := f.query.Query("model", plan, f.routeKey, production.CacheRoutingOn, now)
	return hints
}

func (f *cacheObservationFixture) setTime(now time.Time) {
	f.clock.mu.Lock()
	f.clock.now = now
	f.clock.mu.Unlock()
}

func currentObservationHint(hint production.CacheRoutingHint, p *production.Provider) bool {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return hint.CurrentForProviderLocked(p, "model")
}

// Obtain a genuine deferred rejection, then select the model-wide effect used
// by these tests before replaying it at the original ownership boundary.
func (f *cacheObservationFixture) mismatch(t *testing.T, p *production.Provider, capability protocol.PrefixCacheV2Capability, id string) production.CacheQuarantine {
	t.Helper()
	plan := f.plans.bind(exactTestPlan(exactTestAnchor(16, "c")))
	pr := &production.PendingRequest{RequestID: id, Model: "model", CachePlan: plan}
	if err := f.PrepareCacheAttempt(pr, p); err != nil {
		t.Fatal(err)
	}
	msg := fenceTestV2Lookup(pr.CacheAttemptSnapshot().MetadataMessage().CacheReceiptNonce, capability, exactTestAnchor(16, "d"), 1)
	msg.RequestID = id
	if result := f.ApplyPrefixCacheLookupV2Result(p.ID, msg); result.Reason != production.CacheReceiptPromptMismatch {
		t.Fatalf("quarantine fixture did not produce mismatch: %+v", result)
	}
	f.quarantine.Quarantine(production.CachePlan{})
	return f.quarantine
}
