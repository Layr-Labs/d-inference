package api

// Telemetry ingestion endpoint and Datadog forwarding.
//
// Ingest:   POST /v1/telemetry/events    (provider token | Privy JWT | API key | anon)
//
// Events are stored in the in-memory ring buffer (for admin metrics) and
// forwarded to Datadog Logs API for durable persistence and querying.
// Admin read endpoints have been removed — use Datadog Log Explorer.
//
// Design rules:
//   - Hard cap: 100 events/batch, 64KB body.
//   - Per-source rate limit: 200 burst, 100 events/min refill.
//   - Fields are filtered through an allowlist so free-form user data can't
//     accidentally leak into telemetry.
//   - Source/severity/kind values outside the known set are coerced to the
//     nearest safe default — forward-compatible with newer clients.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/datadog"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/google/uuid"
)

const (
	telemetryMaxBodyBytes = 64 * 1024
	telemetryMaxBatch     = 100
	telemetryMaxMessage   = 4096
	telemetryMaxStack     = 32 * 1024
	telemetryMaxFieldsKB  = 8 * 1024
)

// telemetryFieldAllowlist is the authoritative set of fields permitted in
// telemetry payloads. Keys outside this set are silently dropped server-side.
//
// Rule: this list contains only non-sensitive operational fields. Prompt or
// response content MUST NEVER appear here.
var telemetryFieldAllowlist = map[string]struct{}{
	// Generic
	"component":   {},
	"operation":   {},
	"duration_ms": {},
	"attempt":     {},
	"endpoint":    {},
	"status_code": {},
	"error_class": {},
	"error":       {},
	"target":      {},
	// Provider / backend
	"model":         {},
	"backend":       {},
	"exit_code":     {},
	"signal":        {},
	"hardware_chip": {},
	"memory_gb":     {},
	"macos_version": {},
	// Coordinator
	"handler":           {},
	"provider_id":       {},
	"trust_level":       {},
	"queue_depth":       {},
	"reason":            {},
	"runtime_component": {},
	// Connectivity
	"reconnect_count": {},
	"last_error":      {},
	"ws_state":        {},
	// Billing (booleans/enums only — no dollar amounts)
	"billing_method": {},
	"payment_failed": {},
	// Console UI context
	"url":        {},
	"user_agent": {},
	"route":      {},
}

// ---------------------------------------------------------------------------
// Rate limiter
// ---------------------------------------------------------------------------

type telemetryBucket struct {
	tokens     float64
	lastRefill time.Time
}

type telemetryLimiter struct {
	mu       sync.Mutex
	buckets  map[string]*telemetryBucket
	capacity float64
	rate     float64 // tokens per second
	// anonCapacity/rate are stricter limits applied to unauthenticated sources.
	anonCapacity float64
	anonRate     float64
}

func newTelemetryLimiter() *telemetryLimiter {
	return &telemetryLimiter{
		buckets:      make(map[string]*telemetryBucket),
		capacity:     200,
		rate:         100.0 / 60.0, // 100 events / minute
		anonCapacity: 30,
		anonRate:     10.0 / 60.0,
	}
}

// Allow reports whether a batch of n events is admitted for the given key.
func (l *telemetryLimiter) Allow(key string, n int, anon bool) bool {
	if key == "" {
		key = "_global"
	}
	capacity := l.capacity
	rate := l.rate
	if anon {
		capacity = l.anonCapacity
		rate = l.anonRate
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.buckets[key]
	now := time.Now()
	if !ok {
		b = &telemetryBucket{tokens: capacity, lastRefill: now}
		l.buckets[key] = b
	}
	elapsed := now.Sub(b.lastRefill).Seconds()
	if elapsed > 0 {
		b.tokens += elapsed * rate
		if b.tokens > capacity {
			b.tokens = capacity
		}
		b.lastRefill = now
	}
	cost := float64(n)
	if b.tokens < cost {
		return false
	}
	b.tokens -= cost
	return true
}

// ---------------------------------------------------------------------------
// Ingestion
// ---------------------------------------------------------------------------

// handleTelemetryIngest accepts a batch of telemetry events.
func (s *Server) handleTelemetryIngest(w http.ResponseWriter, r *http.Request) {
	// Size cap before we allocate.
	r.Body = http.MaxBytesReader(w, r.Body, telemetryMaxBodyBytes)
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		var mbe *http.MaxBytesError
		if errors.As(err, &mbe) {
			writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("payload_too_large", "telemetry body exceeds 64KB"))
			return
		}
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "failed to read body"))
		return
	}

	var batch protocol.TelemetryBatch
	if err := json.Unmarshal(raw, &batch); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "malformed JSON batch"))
		return
	}
	if len(batch.Events) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"accepted": 0, "rejected": 0})
		return
	}
	if len(batch.Events) > telemetryMaxBatch {
		writeJSON(w, http.StatusRequestEntityTooLarge, errorResponse("batch_too_large", "maximum 100 events per batch"))
		return
	}

	// Resolve authentication. Three modes:
	//   1. Provider token (device-linked) — identifies machine + account.
	//   2. Privy JWT / API key — identifies account.
	//   3. Anonymous — rate-limited harder, fields always stamped source=console|app.
	authCtx := s.resolveTelemetryAuth(r)

	limiterKey := authCtx.RateLimitKey()
	if !s.telemetryLimiter.Allow(limiterKey, len(batch.Events), authCtx.Anon) {
		writeJSON(w, http.StatusTooManyRequests, errorResponse("rate_limited", "telemetry rate limit exceeded"))
		return
	}

	now := time.Now().UTC()
	records := make([]store.TelemetryEventRecord, 0, len(batch.Events))
	rejected := 0
	for _, e := range batch.Events {
		rec, ok := sanitizeTelemetryEvent(e, authCtx, now)
		if !ok {
			rejected++
			continue
		}
		records = append(records, rec)
	}

	if len(records) > 0 {
		if err := s.store.InsertTelemetryEvents(r.Context(), records); err != nil {
			s.logger.Error("telemetry: failed to insert events", "error", err, "count", len(records))
			writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to persist telemetry"))
			return
		}
		// Metrics: bump ingestion counters.
		if s.metrics != nil {
			for _, rec := range records {
				s.metrics.IncCounter("telemetry_events_total",
					MetricLabel{"source", rec.Source},
					MetricLabel{"severity", rec.Severity},
					MetricLabel{"kind", rec.Kind},
				)
			}
		}

		// Forward to Datadog Logs API asynchronously.
		s.forwardTelemetryToDatadog(records)
	}

	writeJSON(w, http.StatusAccepted, map[string]any{
		"accepted": len(records),
		"rejected": rejected,
	})
}

// telemetryAuthContext holds the resolved identity of a telemetry submitter.
type telemetryAuthContext struct {
	Source    protocol.TelemetrySource // override for events coming from this submitter
	MachineID string
	AccountID string
	Anon      bool
}

// RateLimitKey derives a stable per-submitter key. Anonymous submitters get a
// coarse bucket per source IP hash so flood attacks don't exhaust memory.
func (a telemetryAuthContext) RateLimitKey() string {
	switch {
	case a.MachineID != "":
		return "m:" + a.MachineID
	case a.AccountID != "":
		return "a:" + a.AccountID
	default:
		return "anon"
	}
}

// resolveTelemetryAuth inspects the request and returns what we know about
// the submitter. Never blocks the request for lack of auth (anon is OK).
func (s *Server) resolveTelemetryAuth(r *http.Request) telemetryAuthContext {
	tok := extractBearerToken(r)
	if tok == "" {
		return telemetryAuthContext{Anon: true}
	}

	// Provider token? (device-linked machine credential)
	if pt, err := s.store.GetProviderToken(tok); err == nil && pt != nil && pt.Active {
		// machine_id derived deterministically from the token hash so the rate
		// bucket is stable across reconnects without leaking the token itself.
		return telemetryAuthContext{
			Source:    protocol.TelemetrySourceProvider,
			MachineID: machineIDFromToken(tok),
			AccountID: pt.AccountID,
		}
	}

	// Privy JWT?
	if s.privyAuth != nil && len(tok) > 10 && tok[:3] == "eyJ" {
		if privyID, err := s.privyAuth.VerifyToken(tok); err == nil {
			if user, err := s.privyAuth.GetOrCreateUser(privyID); err == nil {
				return telemetryAuthContext{AccountID: user.AccountID}
			}
		}
	}

	// API key?
	if s.store.ValidateKey(tok) {
		accountID := s.store.GetKeyAccount(tok)
		if accountID == "" {
			accountID = tok // legacy per-key account model
		}
		return telemetryAuthContext{AccountID: accountID}
	}

	return telemetryAuthContext{Anon: true}
}

func machineIDFromToken(tok string) string {
	h := sha256.Sum256([]byte(tok))
	return "tok:" + hex.EncodeToString(h[:8])
}

// sanitizeTelemetryEvent normalizes and validates an incoming event, returning
// the persistent record and a boolean indicating whether to keep it.
func sanitizeTelemetryEvent(
	in protocol.TelemetryEvent,
	auth telemetryAuthContext,
	now time.Time,
) (store.TelemetryEventRecord, bool) {
	// ID: client-supplied or minted here.
	id := in.ID
	if id == "" {
		id = uuid.NewString()
	} else if _, err := uuid.Parse(id); err != nil {
		id = uuid.NewString()
	}

	// Timestamp: trust client unless it's clearly bogus. Clamp to [now-7d, now+5min].
	ts := in.Timestamp.UTC()
	if ts.IsZero() || ts.Before(now.Add(-7*24*time.Hour)) || ts.After(now.Add(5*time.Minute)) {
		ts = now
	}

	// Source: authenticated providers always report as "provider" regardless of body.
	source := in.Source
	if auth.Source != "" {
		source = auth.Source
	}
	if _, ok := protocol.KnownSources()[source]; !ok {
		source = protocol.TelemetrySourceCustom()
	}

	severity := in.Severity
	if _, ok := protocol.KnownSeverities()[severity]; !ok {
		severity = protocol.SeverityInfo
	}

	kind := in.Kind
	if _, ok := protocol.KnownKinds()[kind]; !ok {
		kind = protocol.KindCustom
	}

	message := in.Message
	if message == "" {
		// A message is required; reject events without one.
		return store.TelemetryEventRecord{}, false
	}
	if len(message) > telemetryMaxMessage {
		message = message[:telemetryMaxMessage] + "…"
	}

	stack := in.Stack
	if len(stack) > telemetryMaxStack {
		stack = stack[:telemetryMaxStack] + "\n… [truncated]"
	}

	// Fields: allowlist-filter, cap size, serialize as compact JSON.
	filtered := make(map[string]any, len(in.Fields))
	for k, v := range in.Fields {
		if _, ok := telemetryFieldAllowlist[k]; !ok {
			continue
		}
		filtered[k] = v
	}
	var fieldsJSON json.RawMessage
	if len(filtered) > 0 {
		b, err := json.Marshal(filtered)
		if err != nil {
			b = []byte("{}")
		}
		if len(b) > telemetryMaxFieldsKB {
			b = []byte("{}")
		}
		fieldsJSON = b
	} else {
		fieldsJSON = json.RawMessage("{}")
	}

	machineID := in.MachineID
	if auth.MachineID != "" {
		machineID = auth.MachineID
	}
	accountID := auth.AccountID
	if accountID == "" {
		accountID = in.AccountID
	}

	return store.TelemetryEventRecord{
		ID:         id,
		Timestamp:  ts,
		Source:     string(source),
		Severity:   string(severity),
		Kind:       string(kind),
		Version:    truncField(in.Version, 64),
		MachineID:  truncField(machineID, 128),
		AccountID:  truncField(accountID, 128),
		RequestID:  truncField(in.RequestID, 128),
		SessionID:  truncField(in.SessionID, 64),
		Message:    message,
		Fields:     fieldsJSON,
		Stack:      stack,
		ReceivedAt: now,
	}, true
}

func truncField(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen]
}

// forwardTelemetryToDatadog asynchronously forwards ingested telemetry records
// to the Datadog Logs API via the batching client. Each record becomes one log
// entry. Fatal events also trigger a DD Event for alerting.
func (s *Server) forwardTelemetryToDatadog(records []store.TelemetryEventRecord) {
	if s.dd == nil {
		return
	}
	for _, rec := range records {
		var fields map[string]any
		if len(rec.Fields) > 0 {
			_ = json.Unmarshal(rec.Fields, &fields)
		}
		s.dd.ForwardLog(datadog.TelemetryLogEntry{
			Source:    rec.Source,
			Severity:  rec.Severity,
			Kind:      rec.Kind,
			Message:   rec.Message,
			MachineID: rec.MachineID,
			AccountID: rec.AccountID,
			RequestID: rec.RequestID,
			SessionID: rec.SessionID,
			Version:   rec.Version,
			Fields:    fields,
			Stack:     rec.Stack,
		})

		// DogStatsD counter for ingested events.
		s.dd.Incr("telemetry.events_ingested", []string{
			"source:" + rec.Source,
			"severity:" + rec.Severity,
			"kind:" + rec.Kind,
		})
	}
}
