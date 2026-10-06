package erasure

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// The erasure outbox worker delivers the external deletions that
// ScrubAccount queued: Stripe account deletion, Global Payouts recipient
// close, Checkout Session redaction and the durable erasure_log record.
// Each row ends done, or manual_action with the error stored. "Not found"
// counts as done.

const (
	erasureOutboxInterval = time.Minute
	erasureOutboxLease    = 10 * time.Minute
	erasureOutboxBatch    = 20
	// erasureOutboxMaxAttempts failed deliveries move a row to manual_action.
	erasureOutboxMaxAttempts = 8
	erasureOutboxBaseBackoff = time.Minute
	erasureOutboxMaxBackoff  = 6 * time.Hour
	erasureLogTag            = "erasure_log:true"
)

// outboxOutcome is what one delivery attempt decided.
type outboxOutcome struct {
	kind  outboxKind
	err   string
	jobID string    // checkout_sessions: the redaction job to keep
	next  time.Time // progress and reschedule: when to look again
	// jobStatus is the Stripe status just read for jobID ("" when no job).
	jobStatus string
	// newGeneration makes the next job create use a new idempotency key.
	newGeneration bool
	// externalIDs replaces the row's IDs (the sessions Stripe can find).
	externalIDs *string
	// split is a manual_action row for the sessions Stripe cannot find.
	split *store.ErasureOutboxItem
}

type outboxKind int

const (
	outboxDone       outboxKind = iota // delivered, or the object is gone
	outboxRetry                        // transient failure; counts an attempt
	outboxManual                       // definitive failure; needs an operator
	outboxProgress                     // a redaction job is still working
	outboxReschedule                   // too early to redact; try again later
)

// StartOutboxLoop delivers due outbox rows: once at start, then every
// erasureOutboxInterval.
func (s *Owner) StartOutboxLoop(ctx context.Context) {
	saferun.Go(s.logger, "api.erasureOutboxLoop", func() {
		ticker := time.NewTicker(erasureOutboxInterval)
		defer ticker.Stop()
		for {
			s.runOutbox(ctx)
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	})
}

// runOutbox claims each row immediately before delivery. The pass cutoff
// prevents a just-rescheduled row from consuming the same pass again.
func (s *Owner) runOutbox(ctx context.Context) {
	dueBefore := time.Now().UTC()
	for i := 0; i < erasureOutboxBatch; i++ {
		if ctx.Err() != nil {
			return
		}
		rows, err := s.store.LeaseDueErasureOutbox(ctx, dueBefore, time.Now().UTC(), erasureOutboxLease, 1)
		if err != nil {
			s.logger.Error("erasure outbox: lease failed", "error", err)
			return
		}
		if len(rows) == 0 {
			return
		}
		row := rows[0]
		out := s.deliverOutbox(ctx, row)
		result := outboxResult(row, out, time.Now().UTC())
		if err := s.store.SaveErasureOutboxResult(ctx, row.ID, result); err != nil {
			s.logger.Error("erasure outbox: save result failed", "outbox_id", row.ID, "error", err)
			continue
		}
		if result.State == store.ErasureOutboxManualAction {
			s.logger.Error("erasure outbox: manual action required", "outbox_id", row.ID,
				"request_id", row.RequestID, "target", row.Target, "error", result.LastError)
		}
	}
}

// outboxResult turns an outcome into the stored row state.
func outboxResult(row store.ErasureOutboxWork, out outboxOutcome, now time.Time) store.ErasureOutboxResult {
	r := store.ErasureOutboxResult{
		LeaseGeneration: row.LeaseGeneration, State: store.ErasureOutboxPending, Attempts: row.Attempts, NextAt: now, LastError: out.err,
		ExternalID: row.ExternalID, StripeJobID: out.jobID, JobGeneration: row.JobGeneration, Split: out.split,
	}
	if out.externalIDs != nil {
		r.ExternalID = *out.externalIDs
	}
	if out.newGeneration {
		r.JobGeneration++
	}
	// The status clock restarts when the job or its status changes.
	if out.jobID != "" {
		r.JobStatus, r.JobStatusSince = out.jobStatus, row.JobStatusSince
		if out.jobID != row.StripeJobID || out.jobStatus != row.JobStatus || row.JobStatusSince == nil {
			at := now
			r.JobStatusSince = &at
		}
	}
	switch out.kind {
	case outboxDone:
		r.State, r.LastError = store.ErasureOutboxDone, ""
	case outboxManual:
		r.State, r.Attempts = store.ErasureOutboxManualAction, row.Attempts+1
	case outboxProgress, outboxReschedule:
		r.NextAt = out.next
	case outboxRetry:
		r.Attempts = row.Attempts + 1
		if r.Attempts >= erasureOutboxMaxAttempts {
			r.State = store.ErasureOutboxManualAction
			r.LastError = fmt.Sprintf("retries exhausted after %d attempts: %s", r.Attempts, out.err)
			break
		}
		backoff := erasureOutboxBaseBackoff << (r.Attempts - 1)
		r.NextAt = now.Add(min(backoff, erasureOutboxMaxBackoff))
	}
	return r
}

func (s *Owner) deliverOutbox(ctx context.Context, row store.ErasureOutboxWork) outboxOutcome {
	if row.Target != store.ErasureTargetErasureLog && s.billing != nil && s.billing.MockMode() {
		return outboxOutcome{kind: outboxDone}
	}
	switch row.Target {
	case store.ErasureTargetStripeAccount:
		return s.deleteStripeAccount(row.ExternalID)
	case store.ErasureTargetGlobalRecipient:
		return s.closeGlobalRecipient(ctx, row.ExternalID)
	case store.ErasureTargetCheckoutSessions:
		return s.redactCheckoutSessions(row)
	case store.ErasureTargetErasureLog:
		return s.writeErasureLog(ctx, row)
	}
	return outboxOutcome{kind: outboxManual, err: "unknown outbox target " + string(row.Target)}
}

func (s *Owner) deleteStripeAccount(id string) outboxOutcome {
	if s.billing == nil || s.billing.StripeConnect() == nil {
		return outboxOutcome{kind: outboxRetry, err: "Stripe Connect is not configured"}
	}
	err := s.billing.StripeConnect().DeleteAccount(id)
	switch {
	case err == nil, stripeAccountNotFound(err):
		return outboxOutcome{kind: outboxDone}
	case stripeDefinitive(err):
		// For example a live account whose balances are not zero.
		return outboxOutcome{kind: outboxManual, err: err.Error()}
	}
	return outboxOutcome{kind: outboxRetry, err: err.Error()}
}

// stripeAccountNotFound accepts only structured missing-resource responses.
// The onboarding helper IsAccountGoneErr also accepts permission failures:
// an unusable account or an unclassified 404 is not proof of deletion and
// must remain in the outbox.
func stripeAccountNotFound(err error) bool {
	var apiErr *billing.APIError
	if !errors.As(err, &apiErr) || (apiErr.StatusCode != http.StatusBadRequest && apiErr.StatusCode != http.StatusNotFound) {
		return false
	}
	return apiErr.Code == "resource_missing"
}

func (s *Owner) closeGlobalRecipient(ctx context.Context, id string) outboxOutcome {
	if s.billing == nil || s.billing.GlobalPayouts() == nil {
		return outboxOutcome{kind: outboxRetry, err: "Stripe Global Payouts is not configured"}
	}
	err := s.billing.GlobalPayouts().CloseRecipient(ctx, id)
	var apiErr *globalpayouts.Error
	switch {
	case err == nil:
		return outboxOutcome{kind: outboxDone}
	case errors.As(err, &apiErr) && (apiErr.Status == http.StatusNotFound || apiErr.Code == "not_found"):
		return outboxOutcome{kind: outboxDone}
	case errors.As(err, &apiErr) && apiErr.Definitive():
		return outboxOutcome{kind: outboxManual, err: err.Error()}
	}
	return outboxOutcome{kind: outboxRetry, err: err.Error()}
}

// writeErasureLog stores one record of the erasure (no personal data) in
// Datadog with the erasure_log tag, so a log archive keeps it through a
// database restore. Without Datadog it goes to the process log.
func (s *Owner) writeErasureLog(ctx context.Context, row store.ErasureOutboxWork) outboxOutcome {
	erasedAt := row.ErasedAt.UTC().Format(time.RFC3339Nano)
	var dd *datadog.Client
	if s.datadog != nil {
		dd = s.datadog()
	}
	if !dd.LogsEnabled() {
		s.logger.Info("erasure_log", "request_id", row.RequestID, "account_id", row.AccountID,
			"erased_at", erasedAt, "erasure_log", true)
		return outboxOutcome{kind: outboxDone}
	}
	err := dd.SendLog(ctx, datadog.TelemetryLogEntry{
		Source: "coordinator", Severity: "info", Kind: "erasure_log", Message: "account erased",
		Fields: map[string]any{"request_id": row.RequestID, "account_id": row.AccountID, "erased_at": erasedAt},
	}, erasureLogTag)
	if err != nil {
		return outboxOutcome{kind: outboxRetry, err: err.Error()}
	}
	return outboxOutcome{kind: outboxDone}
}

// stripeDefinitive reports a Stripe 4xx that a retry cannot fix. A 429 rate
// limit and a 409 conflict are retried.
func stripeDefinitive(err error) bool {
	var apiErr *billing.APIError
	if errors.As(err, &apiErr) && apiErr.StatusCode == http.StatusTooManyRequests {
		return false
	}
	return billing.IsDefinitiveAPIErr(err)
}
