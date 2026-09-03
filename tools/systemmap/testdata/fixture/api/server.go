// Package api is the fixture's HTTP surface, shaped like the coordinator's: a
// Server struct holding the state, a routes method registering onto its own mux,
// method-value handlers, a middleware wrapper, and one handler that gates
// internally instead of through middleware.
package api

import (
	"encoding/json"
	"net/http"

	"svcfix.test/fetch"
	"svcfix.test/flight"
	"svcfix.test/store"
)

type Server struct {
	mux     *http.ServeMux
	store   store.Store
	fetcher *fetch.Client
	cache   map[string]string
	aliases map[string]string
	admins  map[string]bool
	flights *flight.Cache
}

func (s *Server) routes() {
	s.mux.HandleFunc("GET /v1/models", s.withAuth(s.handleModels))
	s.mux.HandleFunc("GET /v1/aliases", s.withAuth(s.handleAliases))
	s.mux.HandleFunc("POST /v1/usage", s.handleUsage)
	s.mux.HandleFunc("GET /v1/admin/stats", s.withAuth(s.handleAdminStats))
	s.mux.HandleFunc("/legacy/", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, s.cache["legacy"], http.StatusGone)
	})
}

func (s *Server) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func (s *Server) handleModels(w http.ResponseWriter, r *http.Request) {
	if hit, ok := s.cache[r.URL.Path]; ok {
		_, _ = w.Write([]byte(hit))
		return
	}
	models, err := s.store.ListModels(r.Context())
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	for _, m := range models {
		s.cache[r.URL.Path] = s.expandAliases(m, 0)
	}
	s.fetcher.FetchIcons(r.Context())
	_ = json.NewEncoder(w).Encode(models)
}

func (s *Server) handleAliases(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	// Coalesced behind a cache the overlay knows by type: the answer is filled by
	// code whose only mutation is a write through one of that type's own fields.
	_ = json.NewEncoder(w).Encode(s.flights.Do(name, func() string {
		return s.resolveAlias(name, 0)
	}))
}

func (s *Server) handleUsage(w http.ResponseWriter, r *http.Request) {
	if err := s.store.RecordUsage(r.Context(), r.URL.Query().Get("id"), 1); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if _, err := s.fetcher.FetchOpaque(r.Context(), r.URL.Query().Get("callback")); err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
	}
}

func (s *Server) handleAdminStats(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	age, err := s.store.UsageAge(r.Context(), r.URL.Query().Get("id"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	_ = json.NewEncoder(w).Encode(age)
}

// isAdmin is the in-handler authorization gate: middleware alone cannot tell
// GET /v1/admin/stats apart from GET /v1/models.
func (s *Server) isAdmin(r *http.Request) bool {
	return s.admins[r.Header.Get("X-User")]
}

// expandAliases and resolveAlias are mutually recursive, and two different routes
// enter the cycle at different points. A memo that cached the truncated result
// produced at a back edge would leave whichever route ran second short of half
// the cycle's evidence.
func (s *Server) expandAliases(name string, depth int) string {
	if depth > 3 {
		return name
	}
	if alias, ok := s.aliases[name]; ok {
		return s.resolveAlias(alias, depth+1)
	}
	return name
}

func (s *Server) resolveAlias(name string, depth int) string {
	if depth > 3 {
		return name
	}
	s.cache[name] = name
	return s.expandAliases(name, depth+1)
}
