package api

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/billing/globalpayouts"
	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
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
	// erasureRedactionPoll is how often a running redaction job is read.
	erasureRedactionPoll = 5 * time.Minute
	// erasureRedactionWait reschedules a batch whose transactions are too
	// recent: Stripe redacts most transactions 90 days after creation.
	erasureRedactionWait = 7 * 24 * time.Hour
	// erasureRedactionDeadline ends the 90-day waits: a batch still too
	// recent this long after the scrub goes to manual_action.
	erasureRedactionDeadline = 105 * 24 * time.Hour
	// erasureRedactionStuck ends a job that stays in one non-terminal status.
	// Stripe says a job can validate or redact for up to 30 days.
	erasureRedactionStuck = 31 * 24 * time.Hour
	erasureLogTag         = "erasure_log:true"
)

// erasureLogSender stores the erasure_log record. *datadog.Client is the
// production sender; tests replace it.
type erasureLogSender interface {
	LogsEnabled() bool
	SendLog(ctx context.Context, entry datadog.TelemetryLogEntry, extraTags ...string) error
}

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

// StartErasureOutboxLoop delivers due outbox rows every minute.
func (s *Server) StartErasureOutboxLoop(ctx context.Context) {
	saferun.Go(s.logger, "api.erasureOutboxLoop", func() {
		ticker := time.NewTicker(erasureOutboxInterval)
		defer ticker.Stop()
		for {
			s.runErasureOutbox(ctx)
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	})
}

// runErasureOutbox leases the due rows and delivers each one.
func (s *Server) runErasureOutbox(ctx context.Context) {
	rows, err := s.store.LeaseDueErasureOutbox(ctx, time.Now().UTC(), erasureOutboxLease, erasureOutboxBatch)
	if err != nil {
		s.logger.Error("erasure outbox: lease failed", "error", err)
		return
	}
	for _, row := range rows {
		if ctx.Err() != nil {
			return
		}
		out := s.deliverErasureOutbox(ctx, row)
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
		State: store.ErasureOutboxPending, Attempts: row.Attempts, NextAt: now, LastError: out.err,
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

func (s *Server) deliverErasureOutbox(ctx context.Context, row store.ErasureOutboxWork) outboxOutcome {
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

func (s *Server) deleteStripeAccount(id string) outboxOutcome {
	if s.billing == nil || s.billing.StripeConnect() == nil {
		return outboxOutcome{kind: outboxRetry, err: "Stripe Connect is not configured"}
	}
	err := s.billing.StripeConnect().DeleteAccount(id)
	switch {
	case err == nil, billing.IsAccountGoneErr(err), billing.IsNotFoundAPIErr(err):
		return outboxOutcome{kind: outboxDone}
	case stripeDefinitive(err):
		// For example a live account whose balances are not zero.
		return outboxOutcome{kind: outboxManual, err: err.Error()}
	}
	return outboxOutcome{kind: outboxRetry, err: err.Error()}
}

func (s *Server) closeGlobalRecipient(ctx context.Context, id string) outboxOutcome {
	if s.billing == nil || s.billing.GlobalPayouts() == nil {
		return outboxOutcome{kind: outboxRetry, err: "Stripe Global Payouts is not configured"}
	}
	err := s.billing.GlobalPayouts().CloseRecipient(ctx, id)
	var apiErr *globalpayouts.Error
	switch {
	case err == nil:
		return outboxOutcome{kind: outboxDone}
	case errors.As(err, &apiErr) && (apiErr.Status == 404 || apiErr.Code == "not_found"):
		return outboxOutcome{kind: outboxDone}
	case errors.As(err, &apiErr) && apiErr.Definitive():
		return outboxOutcome{kind: outboxManual, err: err.Error()}
	}
	return outboxOutcome{kind: outboxRetry, err: err.Error()}
}

// redactionTooRecent matches Stripe's validation message for a transaction
// that is not yet old enough to redact (most become redactable 90 days
// after creation).
var redactionTooRecent = regexp.MustCompile(`(?i)\b\d+\s+days?\b|too recent|not old enough`)

// redactCheckoutSessions moves one batch through a Stripe redaction job:
// create, wait for ready, run, wait for succeeded. The job ID, its last
// status and since when are kept on the row between steps.
func (s *Server) redactCheckoutSessions(row store.ErasureOutboxWork) outboxOutcome {
	if s.billing == nil || s.billing.Stripe() == nil {
		return outboxOutcome{kind: outboxRetry, err: "Stripe Checkout is not configured"}
	}
	stripe := s.billing.Stripe()
	now := time.Now().UTC()
	poll := now.Add(erasureRedactionPoll)
	if row.StripeJobID == "" {
		ids := strings.Split(row.ExternalID, ",")
		key := fmt.Sprintf("erasure-redaction-%s-%d", row.ID, row.JobGeneration)
		job, err := stripe.CreateRedactionJob(ids, key)
		if billing.IsNotFoundAPIErr(err) {
			return splitMissingSessions(stripe, row, ids, now)
		}
		if err != nil {
			return redactionAPIOutcome(err, "")
		}
		return outboxOutcome{kind: outboxProgress, jobID: job.ID, jobStatus: job.Status, next: poll}
	}
	job, err := stripe.GetRedactionJob(row.StripeJobID)
	if billing.IsNotFoundAPIErr(err) {
		// The job is gone. A new job needs a new idempotency key, or Stripe
		// would answer with the dead job for 24 hours.
		return outboxOutcome{kind: outboxProgress, next: now, newGeneration: true}
	}
	if err != nil {
		return redactionAPIOutcome(err, row.StripeJobID)
	}
	switch job.Status {
	case "succeeded":
		return outboxOutcome{kind: outboxDone}
	case "failed":
		return failedRedactionJob(stripe, row, job.ID, now)
	case "canceled":
		return outboxOutcome{kind: outboxManual, err: "redaction job " + job.ID + " was canceled"}
	}
	if job.Status == row.JobStatus && row.JobStatusSince != nil && now.Sub(*row.JobStatusSince) > erasureRedactionStuck {
		return outboxOutcome{kind: outboxManual, jobID: job.ID, jobStatus: job.Status,
			err: fmt.Sprintf("redaction job %s has been %s since %s", job.ID, job.Status, row.JobStatusSince.Format(time.RFC3339))}
	}
	if job.Status == "ready" {
		ran, err := stripe.RunRedactionJob(job.ID)
		if err != nil {
			return redactionAPIOutcome(err, job.ID)
		}
		return outboxOutcome{kind: outboxProgress, jobID: job.ID, jobStatus: ran.Status, next: poll}
	}
	// created, validating, redacting, canceling: still working.
	return outboxOutcome{kind: outboxProgress, jobID: job.ID, jobStatus: job.Status, next: poll}
}

// splitMissingSessions handles a job create that Stripe refused because a
// session does not exist. One missing ID cannot be named from that error,
// so each ID is looked up: the found ones stay on the row for a new job,
// and the missing ones move to a manual_action row, because they may be on
// the earlier Stripe account and need redaction by hand.
func splitMissingSessions(stripe *billing.StripeProcessor, row store.ErasureOutboxWork, ids []string, now time.Time) outboxOutcome {
	const missingMsg = "Checkout Session not found with the current Stripe key; it may belong to the earlier Stripe account. Redact it by hand"
	if len(ids) == 1 {
		return outboxOutcome{kind: outboxManual, err: missingMsg}
	}
	var found, missing []string
	for _, id := range ids {
		ok, err := stripe.CheckoutSessionExists(id)
		if err != nil {
			return redactionAPIOutcome(err, "")
		}
		if ok {
			found = append(found, id)
		} else {
			missing = append(missing, id)
		}
	}
	switch {
	case len(missing) == 0:
		return outboxOutcome{kind: outboxRetry, err: "redaction job create said a session is missing, but every session exists"}
	case len(found) == 0:
		return outboxOutcome{kind: outboxManual, err: missingMsg}
	}
	keep := strings.Join(found, ",")
	return outboxOutcome{
		kind: outboxProgress, next: now, externalIDs: &keep, newGeneration: true,
		split: &store.ErasureOutboxItem{
			ID: uuid.NewString(), RequestID: row.RequestID, Target: store.ErasureTargetCheckoutSessions,
			ExternalID: strings.Join(missing, ","), LastError: missingMsg,
		},
	}
}

// failedRedactionJob reads why the job failed. When every error says the
// transactions are too recent, the batch waits and a new job is made later,
// until erasureRedactionDeadline after the scrub.
func failedRedactionJob(stripe *billing.StripeProcessor, row store.ErasureOutboxWork, jobID string, now time.Time) outboxOutcome {
	verrs, err := stripe.RedactionValidationErrors(jobID)
	if err != nil {
		return redactionAPIOutcome(err, jobID)
	}
	if len(verrs) == 0 {
		return outboxOutcome{kind: outboxManual, err: "redaction job " + jobID + " failed without validation errors"}
	}
	tooRecent := true
	messages := make([]string, 0, len(verrs))
	for _, v := range verrs {
		tooRecent = tooRecent && v.Code == "invalid_state" && redactionTooRecent.MatchString(v.Message)
		messages = append(messages, v.Code+": "+v.Message)
	}
	msg := truncateErasureError("redaction job " + jobID + ": " + strings.Join(messages, "; "))
	if !tooRecent {
		return outboxOutcome{kind: outboxManual, err: msg}
	}
	if now.Sub(row.CreatedAt) > erasureRedactionDeadline {
		return outboxOutcome{kind: outboxManual, err: "still too recent to redact " + erasureRedactionDeadline.String() + " after the scrub: " + msg}
	}
	return outboxOutcome{kind: outboxReschedule, err: msg, next: now.Add(erasureRedactionWait), newGeneration: true}
}

// redactionAPIOutcome classifies a Stripe API error from the redaction
// endpoints. A definitive 4xx (including "feature not enabled for this
// account") needs an operator; anything else is retried. A "not found"
// from the job create or the job read is handled before this call.
func redactionAPIOutcome(err error, jobID string) outboxOutcome {
	if stripeDefinitive(err) {
		return outboxOutcome{kind: outboxManual, err: truncateErasureError(err.Error()), jobID: jobID}
	}
	return outboxOutcome{kind: outboxRetry, err: truncateErasureError(err.Error()), jobID: jobID}
}

// writeErasureLog stores one record of the erasure (no personal data) in
// Datadog with the erasure_log tag, so a log archive keeps it through a
// database restore. Without Datadog it goes to the process log.
func (s *Server) writeErasureLog(ctx context.Context, row store.ErasureOutboxWork) outboxOutcome {
	fields := map[string]any{
		"request_id": row.RequestID,
		"account_id": row.AccountID,
		"erased_at":  row.ErasedAt.UTC().Format(time.RFC3339Nano),
	}
	sender := s.erasureLog
	if sender == nil && s.dd != nil {
		sender = s.dd
	}
	if sender == nil || !sender.LogsEnabled() {
		s.logger.Info("erasure_log", "request_id", row.RequestID, "account_id", row.AccountID,
			"erased_at", fields["erased_at"], "erasure_log", true)
		return outboxOutcome{kind: outboxDone}
	}
	err := sender.SendLog(ctx, datadog.TelemetryLogEntry{
		Source: "coordinator", Severity: "info", Kind: "erasure_log", Message: "account erased", Fields: fields,
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

func truncateErasureError(s string) string {
	const limit = 1000
	if len(s) <= limit {
		return s
	}
	return s[:limit]
}
