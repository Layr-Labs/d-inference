package erasure

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

const (
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
)

// redactionTooRecent matches Stripe's validation message for a transaction
// that is not yet old enough to redact (most become redactable 90 days
// after creation).
var redactionTooRecent = regexp.MustCompile(`(?i)\b\d+\s+days?\b|too recent|not old enough`)

// redactCheckoutSessions moves one batch through a Stripe redaction job:
// create, wait for ready, run, wait for succeeded. The job ID, its last
// status and since when are kept on the row between steps.
func (s *Owner) redactCheckoutSessions(row store.ErasureOutboxWork) outboxOutcome {
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
			return redactionAPIOutcome(err, "", "")
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
		return redactionAPIOutcome(err, row.StripeJobID, row.JobStatus)
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
			return redactionAPIOutcome(err, job.ID, job.Status)
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
			return redactionAPIOutcome(err, "", "")
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
	validationErrs, err := stripe.RedactionValidationErrors(jobID)
	if err != nil {
		return redactionAPIOutcome(err, jobID, row.JobStatus)
	}
	if len(validationErrs) == 0 {
		return outboxOutcome{kind: outboxManual, err: "redaction job " + jobID + " failed without validation errors"}
	}
	tooRecent := true
	messages := make([]string, 0, len(validationErrs))
	for _, v := range validationErrs {
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
// jobStatus is the last status known for jobID, so a failed call does not
// restart the job's status clock (outboxResult) and postpone the
// erasureRedactionStuck escalation.
func redactionAPIOutcome(err error, jobID, jobStatus string) outboxOutcome {
	out := outboxOutcome{kind: outboxRetry, err: truncateErasureError(err.Error()), jobID: jobID, jobStatus: jobStatus}
	if stripeDefinitive(err) {
		out.kind = outboxManual
	}
	return out
}

// truncateErasureError bounds a Stripe error text stored as last_error.
func truncateErasureError(s string) string {
	const limit = 1000
	if len(s) <= limit {
		return s
	}
	return s[:limit]
}
