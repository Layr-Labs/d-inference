package middleware

import (
	"crypto/rand"
	_ "embed"
	"errors"
	"fmt"
	"net/http"
	"runtime/debug"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/google/uuid"
)

// cryptoRand is the request-ID entropy source.
var cryptoRand = rand.Read

// bodyLimitMiddleware caps every request body at maxRequestBodyBytes so an
// unbounded POST can't OOM the coordinator (the trusted TEE component).
// Per-handler MaxBytesReader caps (tighter) layer on top. The provider
// WebSocket upgrade is exempt: it hijacks the connection and reads framed
// messages (bounded separately), not r.Body.
func (s *Stack) BodyLimit(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil && r.URL.Path != "/ws/provider" {
			r.Body = http.MaxBytesReader(w, r.Body, maxRequestBodyBytes)
		}
		next.ServeHTTP(w, r)
	})
}

// recoverMiddleware catches panics in any handler, emits a telemetry event
// with the stack trace, and returns 500 to the client. Without this, a single
// nil deref takes down the whole coordinator — panics from tests have hit us
// in production more than once.
func (s *Stack) recoverMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				if recErr, ok := rec.(error); ok && errors.Is(recErr, http.ErrAbortHandler) {
					panic(rec)
				}
				observation.MarkOutcomePanic(r)
				stack := string(debug.Stack())
				s.logger.Error("panic in HTTP handler",
					"error", fmt.Sprintf("%v", rec),
					"path", r.URL.Path,
					"method", r.Method,
					"stack", stack,
				)
				s.observation.EmitPanic(r.Context(),
					fmt.Sprintf("panic in handler %s %s: %v", r.Method, r.URL.Path, rec),
					stack,
					map[string]any{
						"handler":  r.URL.Path,
						"endpoint": r.URL.Path,
					},
				)
				// Write a 500 if the response hasn't started yet. If the
				// handler already flushed headers (e.g. streaming SSE), we
				// can't do anything useful — the client will see the stream
				// truncated.
				defer func() { _ = recover() }()
				httpx. // guard against double-write
					WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "internal server error"))
			}
		}()
		next.ServeHTTP(w, r)
	})
}

// publicCORSPaths are endpoints whose GET is unauthenticated, read-only public
// data. Their GET is served with a wildcard CORS origin so the marketing site
// (darkbloom.dev) and any third party can read them from the browser. NOTE:
// some of these paths (e.g. /v1/pricing) ALSO serve authenticated PUT/DELETE —
// the wildcard applies only to GET; non-GET methods fall through to the
// credentialed, single-origin CORS below.
var publicCORSPaths = map[string]bool{
	"/v1/models/catalog":       true,
	"/v1/pricing":              true,
	"/v1/stats":                true,
	"/v1/network/series":       true,
	"/v1/network/model-demand": true,
}

// corsMiddleware sets CORS headers. Authenticated/credentialed requests are
// locked to a single origin derived from the CORS_ORIGIN environment variable
// (defaulting to the production console domain); a wildcard is never used for
// those. A GET to a public read-only endpoint (see publicCORSPaths) is readable
// from any origin, without credentials, so a wildcard is safe and intended.
func (s *Stack) corsMiddleware(next http.Handler) http.Handler {
	origin := s.corsOrigin
	if origin == "" {
		origin = "https://console.darkbloom.dev"
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Resolve the effective method: for a preflight, the actual request
		// method is in Access-Control-Request-Method (default GET if absent).
		effectiveMethod := r.Method
		if r.Method == http.MethodOptions {
			if reqMethod := r.Header.Get("Access-Control-Request-Method"); reqMethod != "" {
				effectiveMethod = reqMethod
			} else {
				effectiveMethod = http.MethodGet
			}
		}

		if publicCORSPaths[r.URL.Path] && effectiveMethod == http.MethodGet {
			// Public, non-credentialed GET — any origin may read it.
			w.Header().Set("Access-Control-Allow-Origin", "*")
			w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
			w.Header().Set("Vary", "Origin")
		} else {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, "+inreq.MetadataDetailsHeader)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
		}

		w.Header().Set("Access-Control-Expose-Headers", "X-Provider-Verification, X-Provider-Authorization-Method, X-Provider-Encrypted, X-Provider-Trust-Level, X-Provider-Attested")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// loggingMiddleware logs each request using slog and updates HTTP metrics.
func (s *Stack) Logging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &httpx.StatusWriter{ResponseWriter: w, Status: http.StatusOK}

		// Generate (or honor) a request_id and stash it in context +
		// response headers so logs and the client can correlate.
		reqID := r.Header.Get("X-Request-ID")
		if reqID == "" {
			reqID = newRequestID()
		}
		w.Header().Set("X-Request-ID", reqID)
		ctx := access.WithRequestID(r.Context(), reqID)
		// Profiler correlation id is ALWAYS coordinator-minted (the client-supplied
		// X-Request-ID above is echoed and logged but never persisted).
		if !observation.HasRequestMeta(ctx) && (s.observation.ProfilerEnabled() || observation.InferenceOutcomeEndpoint(r)) {
			coordID := reqID
			if observation.InferenceOutcomeEndpoint(r) || r.Header.Get("X-Request-ID") != "" {
				coordID = uuid.NewString()
			}
			ctx = observation.WithRequestMeta(ctx, coordID, start)
		}
		r = r.WithContext(ctx)
		r, autopilotDemand := s.inference.BeginAutopilotDemand(r, start)

		next.ServeHTTP(sw, r)
		s.inference.FinishAutopilotDemand(r, autopilotDemand, sw.Status)

		dur := time.Since(start)

		// Resolve the route pattern that matched (Go 1.22+ method+path).
		// Falls back to URL.Path when no pattern matched (404).
		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}

		// User correlation: if requireAuth attached an account, include
		// it in the access log. Empty for unauthenticated paths.
		userID := access.ConsumerKeyFromContext(ctx)

		s.logger.Info("request",
			"request_id", reqID,
			"method", r.Method,
			"path", r.URL.Path,
			"route", route,
			"status", sw.Status,
			"duration_ms", dur.Milliseconds(),
			"user_id", userID,
		)

		pathLabel := HTTPPathLabel(route)
		statusStr := strconvItoa(sw.Status)

		if s.observation.Metrics() != nil {
			s.observation.Metrics().IncCounter("http_requests_total",
				observation.MetricLabel{Name: "method", Value: r.Method},
				observation.MetricLabel{Name: "path", Value: pathLabel},
				observation.MetricLabel{Name: "status", Value: statusStr},
			)
			s.observation.Metrics().ObserveHistogram("http_request_duration_ms",
				float64(dur.Milliseconds()),
				observation.MetricLabel{Name: "method", Value: r.Method},
				observation.MetricLabel{Name: "path", Value: pathLabel},
			)
		}

		// DogStatsD — emit request counter and latency histogram.
		if s.observation.Datadog() != nil {
			tags := []string{
				"method:" + r.Method,
				"path:" + pathLabel,
				"status_code:" + statusStr,
			}
			s.observation.Datadog().Incr("http.requests", tags)
			s.observation.Datadog().Histogram("http.latency_ms", float64(dur.Milliseconds()), tags)
		}
	})
}

// newRequestID returns a short, URL-safe request identifier. We avoid
// uuid here because request_id is hot-path and we don't need the entropy
// of a UUID — 12 base32 chars (~60 bits) is plenty to distinguish
// concurrent requests for trace correlation.
func newRequestID() string {
	const alphabet = "0123456789abcdefghijklmnopqrstuv"
	var b [12]byte
	if _, err := cryptoRand(b[:]); err != nil {
		// Fall back to a time-based id; collision risk is negligible for
		// log-correlation purposes.
		t := time.Now().UnixNano()
		return strconv.FormatInt(t, 36)
	}
	for i := range b {
		b[i] = alphabet[int(b[i])&31]
	}
	return string(b[:])
}
