package network

import (
	"log/slog"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Domain fixtures use the real fleet, store and shared cache implementation.
func newTestController(reg *registry.Registry, st store.Store, logger *slog.Logger) *Controller {
	cache := readcache.New()
	return New(Dependencies{Store: func() Store { return st }, Fleet: func() Fleet { return reg }, Cache: func() *readcache.Cache { return cache }, Logger: logger, Incr: func(string, []string) {}})
}

// Handler mounts the actual owner handlers for HTTP concurrency fixtures.
// Server route registration is exercised separately in package api.
func (s *Controller) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/stats", s.Stats)
	mux.HandleFunc("GET /v1/network/totals", s.Totals)
	mux.HandleFunc("GET /v1/network/series", s.Series)
	mux.HandleFunc("GET /v1/leaderboard", s.Leaderboard)
	return mux
}
