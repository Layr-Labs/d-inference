package api

// System profiler: coordinator-side wiring.
//
// The profiler produces one prompt-free profile record per dispatched attempt
// (registry.RequestProfile / AttemptProfile, stamped along the request path)
// and persists it through a dedicated bounded, batched sink that is separate
// from the routing-telemetry sink, so profile pressure can never evict route
// rows. See docs/architecture/system-profiler.md.
//
// Knobs (the only two):
//   EIGENINFERENCE_PROFILER=off            kill switch (default on)
//   EIGENINFERENCE_PROFILE_SAMPLE_RATE     0..1, default 0.1; sampling is
//                                          all-or-nothing per logical request
//                                          keyed by the coordinator-minted id,
//                                          and bypassed for every non-success /
//                                          slow / retried / anomalous request.

import (
	"context"
	"hash/fnv"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/outcomes"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	envProfiler           = env.EnvPrefix + "_PROFILER"
	envProfileSampleRate  = env.EnvPrefix + "_PROFILE_SAMPLE_RATE"
	defaultProfileSample  = 0.1
	profileFallbackGrace  = defaultTerminalSettleGrace + time.Second
	profileRetainProfiles = 14 * 24 * time.Hour
	profileRetainFleet    = 30 * 24 * time.Hour
	fleetSampleInterval   = 60 * time.Second
	profilePruneInterval  = time.Hour
	profilePruneBatch     = 5000
	// Always-record predicates (code constants, not knobs).
	profileSlowFirstContent = 5 * time.Second
	profileSlowTotal        = 30 * time.Second
)

// requestMeta is the single context value the logging middleware attaches to
// every HTTP request. It carries the coordinator-minted correlation id and the
// monotonic t0, plus the pre-handler stamps written sequentially by the
// middleware chain (same goroutine, before the handler runs, so plain fields).
type requestMeta struct {
	coordID string
	outcome *outcomes.Tracker
	start   time.Time

	authDoneUS      int64
	ratelimitDoneUS int64
	sealedOpenUS    int64
	sealedBodyBytes int
	authKind        string
	authDBRead      bool
}

func (m *requestMeta) offsetUS() int64 {
	if m == nil {
		return 0
	}
	us := time.Since(m.start).Microseconds()
	if us < 1 {
		us = 1
	}
	return us
}

type requestMetaKey struct{}

// requestMetaFromContext returns the middleware meta or nil.
func requestMetaFromContext(ctx context.Context) *requestMeta {
	if ctx == nil {
		return nil
	}
	m, _ := ctx.Value(requestMetaKey{}).(*requestMeta)
	return m
}

// coordRequestIDFromContext returns the coordinator-minted correlation id
// (never the client-supplied X-Request-ID). Empty when no middleware ran.
func coordRequestIDFromContext(ctx context.Context) string {
	if m := requestMetaFromContext(ctx); m != nil {
		return m.coordID
	}
	return ""
}

// profiler holds the profiler configuration and sinks.
type profiler struct {
	enabled    bool
	sampleRate float64
	logger     *slog.Logger
	sink       *profileSink
}

func newProfilerFromEnv(s *Server) *profiler {
	p := &profiler{
		enabled:    !strings.EqualFold(strings.TrimSpace(env.EnvOr(envProfiler, "on")), "off"),
		sampleRate: env.EnvFloat(envProfileSampleRate, defaultProfileSample),
		logger:     s.logger,
	}
	if p.sampleRate < 0 {
		p.sampleRate = 0
	}
	if p.sampleRate > 1 {
		p.sampleRate = 1
	}
	if p.enabled && s.store != nil {
		p.sink = newProfileSink(s, defaultTelemetrySinkCapacity)
	}
	return p
}

func (p *profiler) close() {
	if p == nil || p.sink == nil {
		return
	}
	p.sink.close()
}

// profilerEnabled reports whether profile records should be created.
func (s *Server) profilerEnabled() bool {
	return s != nil && s.profiler != nil && s.profiler.enabled
}

// newRequestProfile creates the request-level profile at inference-handler
// entry (lazily, never in the middleware) and copies the pre-handler stamps.
// Returns nil when the profiler is off, so every call site is nil-safe.
func (s *Server) newRequestProfile(r *http.Request, model, publicModel string, stream bool) *registry.RequestProfile {
	if !s.profilerEnabled() || r == nil {
		return nil
	}
	m := requestMetaFromContext(r.Context())
	t0 := time.Now()
	coordID := ""
	if m != nil {
		t0 = m.start
		coordID = m.coordID
	}
	rp := registry.NewRequestProfile(t0, coordID, s.finalizeAttemptProfile, profileFallbackGrace)
	rp.Endpoint = httpPathLabel(r.Pattern)
	rp.Stream = stream
	rp.Model = model
	rp.PublicModel = publicModel
	if m != nil {
		rp.AuthDoneUS = m.authDoneUS
		rp.RatelimitDoneUS = m.ratelimitDoneUS
		rp.SealedOpenUS = m.sealedOpenUS
		rp.SealedBodyBytes = m.sealedBodyBytes
		rp.AuthKind = m.authKind
		rp.AuthDBRead = m.authDBRead
	}
	rp.Stamp(&rp.HandlerEntryUS)
	return rp
}

// sampled decides, per logical request, whether a success record is kept.
// Deterministic on the coordinator-minted id so every attempt of a request
// lands together; a missing id (no middleware) is always kept.
func (p *profiler) sampled(coordID string) bool {
	if p == nil {
		return false
	}
	if p.sampleRate >= 1 || coordID == "" {
		return true
	}
	if p.sampleRate <= 0 {
		return false
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(coordID))
	// Map the hash to [0,1) and compare; FNV spreads short ids well enough for
	// a fixed-rate sample and costs no allocation.
	frac := float64(h.Sum32()) / float64(1<<32)
	return frac < p.sampleRate
}

// profileDBCall measures a synchronous store call made on the request
// goroutine and folds it into the request-level accumulator.
func profileDBCall(rp *registry.RequestProfile, start time.Time) {
	if rp == nil {
		return
	}
	rp.AddDuration(&rp.DBUS, time.Since(start))
	rp.DBCalls.Add(1)
}

// stampAuth records the auth completion offset and kind on the middleware meta.
func stampAuth(r *http.Request, kind string, dbRead bool) {
	if m := requestMetaFromContext(r.Context()); m != nil && m.authDoneUS == 0 {
		m.authDoneUS = m.offsetUS()
		m.authKind = kind
		m.authDBRead = dbRead
	}
}

// stampRateLimit records the rate-limit completion offset on the meta.
func stampRateLimit(r *http.Request) {
	if m := requestMetaFromContext(r.Context()); m != nil && m.ratelimitDoneUS == 0 {
		m.ratelimitDoneUS = m.offsetUS()
	}
}

// stampSealedOpen records the sealed-transport decrypt completion and the
// sealed body size on the meta.
func stampSealedOpen(r *http.Request, bodyBytes int) {
	if m := requestMetaFromContext(r.Context()); m != nil && m.sealedOpenUS == 0 {
		m.sealedOpenUS = m.offsetUS()
		m.sealedBodyBytes = bodyBytes
	}
}
