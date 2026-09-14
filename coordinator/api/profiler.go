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
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/profilequeue"
	profiling "github.com/eigeninference/d-inference/coordinator/telemetry/profiler"
)

const (
	envProfiler           = profiling.EnvEnabled
	envProfileSampleRate  = profiling.EnvSampleRate
	defaultProfileSample  = profiling.DefaultSampleRate
	profileFallbackGrace  = defaultTerminalSettleGrace + time.Second
	profileRetainProfiles = 14 * 24 * time.Hour
	profileRetainFleet    = 30 * 24 * time.Hour
	fleetSampleInterval   = 60 * time.Second
	profilePruneInterval  = time.Hour
	profilePruneBatch     = 5000
)

// requestMeta is the single context value the logging middleware attaches to
// every HTTP request. It carries the coordinator-minted correlation id and the
// monotonic t0, plus the pre-handler stamps written sequentially by the
// middleware chain (same goroutine, before the handler runs, so plain fields).
type requestMeta struct {
	coordID string
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

// profilerEnabled reports whether profile records should be created.
func (s *Server) profilerEnabled() bool {
	return s != nil && s.profiler.Enabled()
}

// newRequestProfile creates the request-level profile at inference-handler
// entry (lazily, never in the middleware) and copies the pre-handler stamps.
// With heavy profiling off, only accounted inference requests create compact
// lifecycle evidence. Other call sites remain nil-safe and allocation-free.
func (s *Server) newRequestProfile(r *http.Request, model, publicModel string, stream bool) *registry.RequestProfile {
	if r == nil || (!s.profilerEnabled() && requestOutcomeFromContext(r.Context()) == nil) {
		return nil
	}
	setOutcomeStage(r, "validation")
	m := requestMetaFromContext(r.Context())
	t0 := time.Now()
	coordID := ""
	if m != nil {
		t0 = m.start
		coordID = m.coordID
	}
	o := requestOutcomeFromContext(r.Context())
	rp := registry.NewRequestProfile(t0, coordID, func(rp *registry.RequestProfile, ap *registry.AttemptProfile) {
		o.attemptFinalized(rp, ap)
		s.finalizeAttemptProfile(rp, ap)
	}, profileFallbackGrace)
	rp.CompactOnly = !s.profilerEnabled()
	if o != nil {
		o.mu.Lock()
		o.profile = rp
		o.mu.Unlock()
	}
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

type profiler = profiling.Profiler

func newProfilerFromEnv(s *Server) *profiler {
	return newProfiler(s, profiling.ConfigFromEnv(), defaultTelemetrySinkCapacity)
}

func newProfiler(s *Server, config profiling.Config, capacity int) *profiler {
	return profiling.New(config, profiling.Hooks{
		Logger: s.logger,
		Store:  func() profilequeue.Writer { return s.store },
		Incr:   s.ddIncr,
		Count:  s.ddCount,
	}, capacity)
}

// finalizeAttemptProfile only attempts the nonblocking enqueue. Record
// construction and sampling stay on the profiler's independent worker.
func (s *Server) finalizeAttemptProfile(rp *registry.RequestProfile, ap *registry.AttemptProfile) {
	if s != nil {
		s.profiler.Submit(rp, ap)
	}
}
