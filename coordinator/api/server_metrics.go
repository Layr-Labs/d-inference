package api

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

// registerDefaultGauges wires live-computed gauges (fleet size, etc.) into
// the metrics registry at construction time.
func (s *Server) registerDefaultGauges() {
	s.metrics.RegisterGauge("providers_online", func() float64 {
		return float64(s.registry.ProviderCount())
	})
	s.metrics.RegisterGauge("min_provider_version_set", func() float64 {
		if s.minProviderVersion != "" {
			return 1
		}
		return 0
	})
}

// StartDDGaugeLoop periodically pushes gauge values to DogStatsD. Gauges
// are point-in-time values and must be pushed regularly (not on-demand like
// counters). Call as a goroutine; stops when ctx is cancelled.
func (s *Server) StartDDGaugeLoop(ctx context.Context) {
	if s.dd == nil {
		return
	}
	ticker := time.NewTicker(15 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.ddGauge("providers.online", float64(s.registry.OnlineCount()), nil)
			// APNs code-identity coverage — watch this climb during the grace
			// window before letting APNS_ENFORCE_AFTER pass.
			codeAttested, _ := s.registry.CodeAttestationCoverage()
			s.ddGauge("attestation.code_attested", float64(codeAttested), nil)
			enforced := 0.0
			if s.registry.CodeAttestationEnforced() {
				enforced = 1.0
			}
			s.ddGauge("attestation.code_enforced", enforced, nil)
			for model, count := range s.registry.ModelProviderSnapshot() {
				s.ddGauge("providers.per_model", float64(count), []string{"model:" + model})
			}
			for ver, count := range s.registry.ProviderCountByVersion() {
				s.ddGauge("providers.per_version", float64(count), []string{"version:" + ver})
			}
			for _, b := range s.registry.ProviderCountByTrustStatus() {
				s.ddGauge("providers.by_trust_status", float64(b.Count),
					[]string{"trust_level:" + b.TrustLevel, "status:" + b.Status})
			}
			for reason, count := range s.registry.ProviderCountByMDMFailure() {
				s.ddGauge("providers.by_mdm_failure", float64(count), []string{"reason:" + reason})
			}
			if s.minProviderVersion != "" {
				s.ddGauge("coordinator.min_provider_version_set", 1, []string{"min_version:" + s.minProviderVersion})
			}
			if q := s.registry.Queue(); q != nil {
				s.ddGauge("request_queue.depth", float64(q.TotalSize()), nil)
			}
		}
	}
}

// readCacheJanitorInterval is how often expired readCache entries are reclaimed.
// Get already skips expired entries, so this only frees memory — but without it
// high-cardinality keys (e.g. the per-account "account-earnings:" entries) are
// written and never re-read, so they linger forever and the cache grows unbounded.
const readCacheJanitorInterval = time.Minute

// StartReadCacheJanitor periodically purges expired entries from the read cache
// so it can't grow unbounded. Call as a goroutine; stops when ctx is cancelled.
func (s *Server) StartReadCacheJanitor(ctx context.Context) {
	s.runReadCacheJanitor(ctx, readCacheJanitorInterval)
}

// runReadCacheJanitor is StartReadCacheJanitor with an injectable interval (tests).
func (s *Server) runReadCacheJanitor(ctx context.Context, interval time.Duration) {
	if s.readCache == nil {
		return
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.readCache.PurgeExpired()
		}
	}
}

// handleAdminMetrics returns the metrics snapshot in JSON or Prometheus text.
func (s *Server) handleAdminMetrics(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	snap := s.metrics.Snapshot()
	if r.URL.Query().Get("format") == "prom" {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(snap.RenderProm()))
		return
	}
	writeJSON(w, http.StatusOK, snap)
}

// handleUnimplementedEndpoint returns a structured JSON error for any /v1/*
// path not registered as an explicit route. This prevents OpenAI SDK clients
// from crashing on raw text/plain 404s when hitting unimplemented endpoints
// like /v1/embeddings or /v1/moderations.
func (s *Server) handleUnimplementedEndpoint(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotFound, errorResponse(
		"invalid_request_error",
		fmt.Sprintf("endpoint %s %s is not implemented", r.Method, r.URL.Path),
	))
}
