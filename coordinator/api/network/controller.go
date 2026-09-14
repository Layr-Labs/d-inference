// Package network owns public network statistics, geography, earnings totals,
// traffic series and pseudonymous leaderboards, including their refresh state.
package network

import (
	"log/slog"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
)

// Dependencies binds read models to the router's current store, registry view,
// and shared response cache. The getters preserve bindings installed after
// route registration; Incr retains the existing metric delivery policy.
type Dependencies struct {
	Store  func() Store
	Fleet  func() Fleet
	Cache  func() *readcache.Cache
	Logger *slog.Logger
	Incr   func(string, []string)
}

// Controller owns coalesced refreshes and serializes every earnings window
// through one query mutex. It does not own live providers or durable records.
type Controller struct {
	store                 func() Store
	registry              func() Fleet
	readCache             func() *readcache.Cache
	logger                *slog.Logger
	incr                  func(string, []string)
	statsRefresh          readcache.Refresher
	statsGeographyRefresh readcache.Refresher
	networkTotalsRefresh  struct {
		mu      sync.Mutex
		queryMu sync.Mutex
		entries map[string]*readcache.Refresher
	}
}

// New creates one owner to share between public handlers and refresh loops.
func New(d Dependencies) *Controller {
	return &Controller{store: d.Store, registry: d.Fleet, readCache: d.Cache, logger: d.Logger, incr: d.Incr}
}
