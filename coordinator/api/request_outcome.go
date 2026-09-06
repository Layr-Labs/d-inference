package api

import (
	"context"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

type requestOutcomeKey struct{}
type requestOutcome struct {
	mu        sync.Mutex
	sink      *requestOutcomeSink
	record    store.RequestOutcomeRecord
	profile   *registry.RequestProfile
	finalized map[string]store.RequestAttemptOutcome
	finished  bool
}

func requestOutcomeFromContext(ctx context.Context) *requestOutcome {
	if ctx == nil {
		return nil
	}
	o, _ := ctx.Value(requestOutcomeKey{}).(*requestOutcome)
	return o
}
func inferenceOutcomeEndpoint(r *http.Request) bool {
	if r.Method != http.MethodPost {
		return false
	}
	switch r.URL.Path {
	case "/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages":
		return true
	}
	return false
}

// observeRequestOutcome encloses drain/auth/rate-limit/sealed and handler exits.
// Wrong methods, unmatched paths and OPTIONS never enter this population.
func (s *Server) observeRequestOutcome(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.requestOutcomes == nil {
			next(w, r)
			return
		}
		meta := requestMetaFromContext(r.Context())
		if meta == nil {
			meta = &requestMeta{coordID: uuid.NewString(), start: time.Now()}
			r = r.WithContext(context.WithValue(r.Context(), requestMetaKey{}, meta))
		}
		o := &requestOutcome{sink: s.requestOutcomes, finalized: make(map[string]store.RequestAttemptOutcome), record: store.RequestOutcomeRecord{CoordRequestID: meta.coordID, SchemaVersion: store.RequestOutcomeSchemaVersion, ReceivedAt: meta.start, Endpoint: r.URL.Path, RawStage: "drain", Termination: "in_progress", ResponseProgress: "unknown", ProviderOutcome: "no_terminal", Attempts: []store.RequestAttemptOutcome{}}}
		r = r.WithContext(context.WithValue(r.Context(), requestOutcomeKey{}, o))
		ow := &outcomeWriter{ResponseWriter: w, outcome: o}
		s.requestOutcomes.received.Add(1)
		s.ddIncr("request_outcomes.received", []string{"endpoint:" + r.URL.Path})
		o.mu.Lock()
		o.publishLocked()
		o.mu.Unlock()
		returned := false
		defer func() {
			o.mu.Lock()
			defer o.mu.Unlock()
			o.finished = true
			now := time.Now()
			o.record.HandlerFinishedAt = &now
			o.record.HTTPStatus = ow.status
			o.record.ClientWriteError = ow.writeFailed
			o.record.ClientDeparted = o.record.ClientDeparted || r.Context().Err() != nil
			if !returned {
				o.record.RawStage = "handler"
				o.record.RawReason = "handler_aborted"
			}
			o.refreshLocked()
			o.publishLocked()
		}()
		next(ow, r)
		returned = true
	}
}
func (o *requestOutcome) publishLocked() {
	o.record.Revision++
	o.record.UpdatedAt = time.Now()
	r := o.record
	r.Attempts = append([]store.RequestAttemptOutcome{}, r.Attempts...)
	o.sink.submit(r)
}

func (o *requestOutcome) attemptFinalized(rp *registry.RequestProfile, ap *registry.AttemptProfile) {
	if o == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	key := ap.RequestID + "/" + strconv.Itoa(ap.Attempt)
	if len(o.finalized) < store.MaxRequestOutcomeAttempts {
		o.finalized[key] = compactAttemptOutcome(ap)
	} else {
		o.record.AttemptsTruncated = true
	}
	if o.finished {
		o.refreshLocked()
		o.publishLocked()
	}
}
func compactAttemptOutcome(ap *registry.AttemptProfile) store.RequestAttemptOutcome {
	status, reason, cause, provider, _ := ap.Outcome()
	completeObserved := ap.ProviderCompleteObserved.Load()
	if provider == "" {
		provider = "no_terminal"
	}
	if provider == "no_terminal" && completeObserved {
		// A discarded speculative completion is evidence of receipt, but
		// cannot establish the terminal accepted by legacy arbitration.
		provider = "unknown"
	}
	return store.RequestAttemptOutcome{RequestID: ap.RequestID, Attempt: ap.Attempt, BackupOf: ap.BackupOf, Winning: ap.Winning.Load(), WriteSubmitted: ap.WriteSubmittedUS.Load() > 0, WriteCompleted: ap.WriteDoneUS.Load() > 0, ProviderAccepted: ap.AcceptedUS.Load() > 0, ProviderCompleteObserved: completeObserved, ProviderContentObserved: ap.GeneratedContentObserved.Load(), ProviderOutcome: provider, FinalStatus: status, RawReason: reason, TerminalCause: cause, NormalizedCode: normalizedAttemptOutcome(reason), Finalized: ap.Finalized()}
}
func (o *requestOutcome) refreshLocked() {
	r := &o.record
	rp := o.profile
	r.Attempts = r.Attempts[:0]
	if rp != nil {
		if rp.Model != "" {
			r.Model = rp.Model
		}
		if len(r.Model) > 256 {
			r.Model = ""
		}
		if rp.ParsedUS.Load() > 0 || rp.Model != "" {
			stream := rp.Stream
			r.Stream = &stream
		}
		r.ClientDeparted = r.ClientDeparted || rp.ClientGoneUS.Load() > 0
		r.ClientWriteError = r.ClientWriteError || rp.ClientWriteErr.Load()
		r.EgressCompleted = rp.DoneFlushedUS.Load() > 0 && !r.ClientWriteError && !r.EgressError
		attempts := rp.Attempts()
		r.AttemptsTotal = len(attempts)
		for _, ap := range attempts {
			a := compactAttemptOutcome(ap)
			if len(r.Attempts) < store.MaxRequestOutcomeAttempts {
				r.Attempts = append(r.Attempts, a)
			} else {
				r.AttemptsTruncated = true
			}
			r.ProviderContentObserved = r.ProviderContentObserved || a.ProviderContentObserved
			if a.Winning {
				r.ProviderOutcome = a.ProviderOutcome
				if a.FinalStatus != "success" && a.RawReason != "" && r.RawReason == "" {
					r.RawStage = "response"
					r.RawReason = a.RawReason
				}
			}
		}
	}
	r.AttemptsComplete = !r.AttemptsTruncated && len(o.finalized) == r.AttemptsTotal
	if o.finished && r.AttemptsComplete && r.FinalizedAt == nil {
		now := time.Now()
		r.FinalizedAt = &now
	}
	classifyRequestOutcome(r)
}

// annotateOutcomeRejection only consumes coordinator-owned enum values. The
// rejected response's bytes are never treated as generated content.
func annotateOutcomeRejection(info rejectionInfo) {
	if info.r == nil {
		return
	}
	o := requestOutcomeFromContext(info.r.Context())
	if o == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.record.RawReason != "" && (o.record.RawReason != info.reasonCode || o.record.RawStage != info.stage) {
		o.record.EvidenceConflict = true
		return
	}
	o.record.RawStage = info.stage
	o.record.RawReason = info.reasonCode
	if info.resolvedModel != "" && len(info.resolvedModel) <= 256 {
		o.record.Model = info.resolvedModel
	}
	stream := info.stream
	o.record.Stream = &stream
}

// classifyRequestOutcome is analytics-only. It never feeds routing, status,
// retry, provider health, billing, or the existing uptime metrics.
func classifyRequestOutcome(r *store.RequestOutcomeRecord) {
	r.ResponseProgress = "no_content_observed"
	if r.ProviderContentObserved {
		r.ResponseProgress = "content_observed"
	}
	if r.ProviderOutcome == "completed" {
		r.ResponseProgress = "provider_completed"
	}
	r.Termination = "unknown"
	if r.HandlerFinishedAt == nil {
		r.Termination = "in_progress"
		return
	}
	switch {
	case r.EvidenceConflict:
		r.Termination = "unknown"
	case r.ClientDeparted:
		r.Termination = "client_departure"
	case r.ClientWriteError || r.EgressError:
		r.Termination = "interrupted_response"
	case r.ProviderOutcome == "completed" && r.EgressCompleted && r.HTTPStatus >= 200 && r.HTTPStatus < 300:
		r.Termination = "completed"
	case r.HTTPStatus >= 400:
		r.Termination = "rejected"
	case r.ProviderContentObserved || r.ContentWriteCompleted || r.ProviderOutcome == "error":
		r.Termination = "interrupted_response"
	}
	r.NormalizedCode = normalizedRequestOutcome(r.RawStage, r.RawReason, r.HTTPStatus, r.Termination)
	if r.Termination == "rejected" && r.CoordinatorExhausted && r.RawReason == "dispatch_exhausted" {
		r.NormalizedCode = "ext_coordinator_exhausted"
	}
}
func normalizedAttemptOutcome(reason string) string {
	if reason == "deadline_unreachable" {
		return "int_provider_deadline_rejected"
	}
	if reason == "" {
		return ""
	}
	return "int_legacy:" + reason
}
func normalizedRequestOutcome(stage, reason string, status int, termination string) string {
	if termination != "rejected" {
		return ""
	}
	if stage == "dispatch" && status == http.StatusTooManyRequests {
		switch reason {
		case "first_chunk_timeout":
			return "ext_first_content_timeout"
		case "deadline_unreachable":
			return "ext_coordinator_exhausted"
		}
	}
	// dispatch_exhausted alone is ambiguous (e.g. a retained real provider 504).
	// Preserve it as scoped raw diagnostics instead of hiding its precedence.
	if reason != "" {
		return "ext_legacy:" + reason
	}
	return "ext_unknown"
}

func setOutcomeStage(r *http.Request, stage string) {
	if o := requestOutcomeFromContext(r.Context()); o != nil {
		o.mu.Lock()
		if o.record.RawReason == "" {
			o.record.RawStage = stage
		}
		o.mu.Unlock()
	}
}

// Compact observers never change the profiler-off terminal arbitration policy.
func compactOnlyAttempt(ap *registry.AttemptProfile) bool {
	return ap != nil && ap.Parent() != nil && ap.Parent().CompactOnly
}
