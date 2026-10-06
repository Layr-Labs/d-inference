package cachefunnel

import "sync"

// Request accumulates one request's evidence until Close. Every method is
// safe on a nil receiver, which is how a request outside the population is
// represented, and safe for concurrent use by the handler and provider readers.
type Request struct {
	ledger *Ledger

	mu           sync.Mutex
	closed       bool
	planning     Planning
	promptTokens Tokens
	planned      bool
	repeated     Tokens
	attempts     int
	// lastDispatched classifies the request when no attempt completed.
	lastDispatched Attempt
	completed      bool
	// completing is the attempt whose completion was recorded first.
	completing Attempt
	completion Completion
}

// NotePlanning records the planning decision for the model and body the
// request is dispatched with, together with the prompt tokens that decision
// counted. A later call replaces both, so a count never outlives the decision
// it came from.
func (r *Request) NotePlanning(planning Planning, promptTokens Tokens) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.planning = planning
	r.promptTokens = promptTokens
}

// NotePlan records the plan the request is dispatched with. It is the
// authority for "planned": a planning decision alone may belong to a
// candidate model the request was not served on.
func (r *Request) NotePlan(promptTokens, repeatedPrefixTokens int) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.planned = true
	r.promptTokens = KnownTokens(promptTokens)
	r.repeated = KnownTokens(repeatedPrefixTokens)
}

// NoteAttemptDispatched counts one attempt handed to a provider.
func (r *Request) NoteAttemptDispatched(attempt Attempt) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.attempts++
	r.lastDispatched = attempt
}

// NoteAttemptCompleted records the completing attempt. Only the first
// completion classifies the request; a hedge that also completes is ignored.
func (r *Request) NoteAttemptCompleted(attempt Attempt, completion Completion) {
	if r == nil {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.completed {
		return
	}
	r.completed = true
	r.completing = attempt
	r.completion = completion
}

// Close classifies the request once and folds it into the ledger. Later
// calls, and evidence arriving after Close, change nothing.
func (r *Request) Close(clientCancelled bool) {
	if r == nil {
		return
	}
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return
	}
	r.closed = true
	record := r.recordLocked(clientCancelled)
	r.mu.Unlock()
	r.ledger.close(record)
}

func (r *Request) recordLocked(clientCancelled bool) Record {
	attempt, attempts := r.lastDispatched, r.attempts
	if r.completed {
		// A provider can only complete a request it was handed. The attempt is
		// counted after its frame is on the wire, on another goroutine, so a
		// fast completion may be recorded first.
		attempt, attempts = r.completing, max(attempts, 1)
	}
	record := Record{
		Attempts:             attempts,
		PromptTokens:         r.promptTokens.observed(),
		RepeatedPrefixTokens: r.repeated.observed(),
	}
	if attempts > 0 {
		record.DispatchedWithoutScope = !attempt.Scoped
		record.PredictedTokens = attempt.Predicted.observed()
	}
	if r.completed {
		record.LookupOutcomeReported = r.completion.Lookup != LookupNotReported
		record.ReusedTokens = r.completion.Reused.observed()
	}
	record.Reason = classify(classification{
		planning: r.planning, planned: r.planned, dispatched: attempts > 0,
		completed: r.completed, cancelled: clientCancelled,
		routing: attempt.Routing, scoped: attempt.Scoped, lookup: r.completion.Lookup,
	})
	return record
}
