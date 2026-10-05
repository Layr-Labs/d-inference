package observation

import (
	"context"
	"net/http"
	"strconv"
	"sync"
	"time"

	outcomes "github.com/eigeninference/d-inference/coordinator/internal/observation/outcomes"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

type requestOutcomeKey struct{}
type requestOutcome struct {
	mu      sync.Mutex
	sink    *outcomes.Sink
	record  store.RequestOutcomeRecord
	profile *registry.RequestProfile
	// Finalization only needs membership; refreshLocked reads current evidence
	// from the profile instead of retaining a second attempt snapshot.
	finalized map[string]struct{}
	finished  bool
}

func requestOutcomeFromContext(ctx context.Context) *requestOutcome {
	if ctx == nil {
		return nil
	}
	o, _ := ctx.Value(requestOutcomeKey{}).(*requestOutcome)
	return o
}
func InferenceOutcomeEndpoint(r *http.Request) bool {
	if r.Method != http.MethodPost {
		return false
	}
	switch r.URL.Path {
	case "/v1/chat/completions", "/v1/responses", "/v1/completions", "/v1/messages":
		return true
	}
	return false
}

// ObserveRequestOutcome encloses recovery, drain/auth/rate-limit/sealed and handler exits.
// Wrong methods, unmatched paths and OPTIONS never enter this population.
func (s *Owner) ObserveRequestOutcome(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s == nil || s.requestOutcomes == nil || !InferenceOutcomeEndpoint(r) {
			next(w, r)
			return
		}
		// ServeMux matches escaped path segments, not just decoded URL.Path.
		// For example /v1%2Fmessages is an unmatched route, not /v1/messages.
		if s.hooks.RoutePattern != nil {
			pattern := s.hooks.RoutePattern(r)
			if pattern != http.MethodPost+" "+r.URL.Path {
				next(w, r)
				return
			}
		}
		meta := requestMetaFromContext(r.Context())
		if meta == nil {
			meta = &requestMeta{coordID: uuid.NewString(), start: time.Now()}
			r = r.WithContext(context.WithValue(r.Context(), requestMetaKey{}, meta))
		}
		o := &requestOutcome{sink: s.requestOutcomes, finalized: make(map[string]struct{}), record: store.RequestOutcomeRecord{CoordRequestID: meta.coordID, SchemaVersion: store.RequestOutcomeSchemaVersion, ReceivedAt: meta.start, Endpoint: r.URL.Path, RawStage: "drain", Termination: "in_progress", ResponseProgress: "unknown", ProviderOutcome: "no_terminal", ResponseTerminal: "unknown", Attempts: []store.RequestAttemptOutcome{}}}
		r = r.WithContext(context.WithValue(r.Context(), requestOutcomeKey{}, o))
		ow := &outcomeWriter{ResponseWriter: w, outcome: o}
		s.requestOutcomes.Received()
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
	if o.record.PublicDemand != nil {
		d := *o.record.PublicDemand
		d.Outcome = outcomes.PublicDemandOutcome(o.record)
		o.record.PublicDemand = &d
	}
	o.record.Revision++
	o.record.UpdatedAt = time.Now()
	r := o.record
	r.Attempts = append([]store.RequestAttemptOutcome{}, r.Attempts...)
	o.sink.Submit(r)
}

func (o *requestOutcome) attemptFinalized(rp *registry.RequestProfile, ap *registry.AttemptProfile) {
	if o == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	key := ap.RequestID + "/" + strconv.Itoa(ap.Attempt)
	if len(o.finalized) < store.MaxRequestOutcomeAttempts {
		o.finalized[key] = struct{}{}
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
	return store.RequestAttemptOutcome{RequestID: ap.RequestID, Attempt: ap.Attempt, BackupOf: ap.BackupOf, Winning: ap.Winning.Load(), WriteSubmitted: ap.WriteSubmittedUS.Load() > 0, WriteCompleted: ap.WriteDoneUS.Load() > 0, ProviderAccepted: ap.AcceptedUS.Load() > 0, ProviderCompleteObserved: completeObserved, ProviderContentObserved: ap.GeneratedContentObserved.Load(), ProviderOutcome: provider, FinalStatus: status, RawReason: reason, TerminalCause: cause, NormalizedCode: outcomes.NormalizedAttempt(reason), Finalized: ap.Finalized()}
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
		r.ClientDeparted = r.ClientDeparted || rp.ClientGoneUS.Load() > 0
		r.ClientWriteError = r.ClientWriteError || rp.ClientWriteErr.Load()
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
	r.EgressCompleted = r.EgressCompleted && !r.ClientWriteError && !r.EgressError
	r.AttemptsComplete = !r.AttemptsTruncated && len(o.finalized) == r.AttemptsTotal
	if o.finished && r.AttemptsComplete && r.FinalizedAt == nil {
		now := time.Now()
		r.FinalizedAt = &now
	}
	outcomes.Classify(r)
}

// AnnotateOutcomeRejection only consumes coordinator-owned enum values. The
// rejected response's bytes are never treated as generated content.
func AnnotateOutcomeRejection(r *http.Request, stage, reasonCode, resolvedModel string) {
	if r == nil {
		return
	}
	o := requestOutcomeFromContext(r.Context())
	if o == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.record.RawReason != "" && (o.record.RawReason != reasonCode || o.record.RawStage != stage) {
		o.record.EvidenceConflict = true
		return
	}
	o.record.RawStage = stage
	o.record.RawReason = reasonCode
	if resolvedModel != "" && len(resolvedModel) <= 256 {
		o.record.Model = resolvedModel
	}
}

func SetOutcomeStage(r *http.Request, stage string) {
	if o := requestOutcomeFromContext(r.Context()); o != nil {
		o.mu.Lock()
		if o.record.RawReason == "" {
			o.record.RawStage = stage
		}
		o.mu.Unlock()
	}
}

// Compact observers never change the profiler-off terminal arbitration policy.
func CompactOnlyAttempt(ap *registry.AttemptProfile) bool {
	return ap != nil && ap.Parent() != nil && ap.Parent().CompactOnly
}
