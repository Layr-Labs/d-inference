// Package accountfleet owns the account's provider dashboard: persisted and
// live machine views, earnings summaries, reputation and offline removal.
package accountfleet

import (
	"log/slog"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/store"
	"golang.org/x/sync/singleflight"
)

// Dependencies preserves the API's current bindings, authenticated user and
// version policy without exposing its server or unrelated state.
type Dependencies struct {
	Store         func() Store
	Registry      func() Registry
	Cache         func() *readcache.Cache
	MinVersion    func() string
	LatestVersion func() string
	RequireUser   func(http.ResponseWriter, *http.Request) *store.User
	VersionLess   func(string, string) bool
	Logger        *slog.Logger
}

// Controller shares one per-account earnings flight group across dashboard
// requests. Live provider and durable record ownership stays in their stores.
type Controller struct {
	store                 func() Store
	registry              func() Registry
	readCache             func() *readcache.Cache
	minVersion            func() string
	latestVersion         func() string
	requireUser           func(http.ResponseWriter, *http.Request) *store.User
	versionLess           func(string, string) bool
	logger                *slog.Logger
	summaryWindowsFlights singleflight.Group
}

func New(d Dependencies) *Controller {
	return &Controller{store: d.Store, registry: d.Registry, readCache: d.Cache, minVersion: d.MinVersion, latestVersion: d.LatestVersion, requireUser: d.RequireUser, versionLess: d.VersionLess, logger: d.Logger}
}
