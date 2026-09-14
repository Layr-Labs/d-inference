package providerframe

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// Error handles a provider inference_error frame on the read
// loop (and the coordinator-synthesized errors Chunk raises there). The
// frame holds no terminal claim; ownership is decided at the peek inside.
func (s *Service) Error(providerID string, provider *registry.Provider, msg *protocol.InferenceErrorMessage) {
	s.errorOwned(providerID, provider, msg, false)
}

// errorOwned is Error with terminal ownership
// threaded in: owned is true only when the caller already holds the attempt's
// terminal claim (CompleteAt converting a deadline-late empty
// completion), so this path must neither re-claim nor drop that frame as a
// duplicate.
func (s *Service) errorOwned(providerID string, provider *registry.Provider, msg *protocol.InferenceErrorMessage, owned bool) {
	if provider == nil {
		s.deps.Logger().Warn("error from unregistered provider", "provider_id", providerID)
		return
	}
	safeMsg, invalidFailureCode, invalidTerminalCause := attempt.SanitizeProviderInferenceError(msg)
	msg = &safeMsg
	if invalidFailureCode {
		s.deps.Metrics.Incr("inference.invalid_failure_code", nil)
	}
	if invalidTerminalCause {
		// Never tag the counter with the untrusted value: the value itself may be
		// an exfiltration payload and would also create unbounded cardinality.
		s.deps.Metrics.Incr(attempt.MetricUnknownTerminalCause, nil)
		s.deps.Metrics.Incr(attempt.MetricTypedTerminal, []string{"cause:unknown"})
	}
	// Ownership is decided BEFORE the pending request is removed. Completions
	// settle on a worker goroutine while error frames run inline on the read
	// loop, so an error frame for a request whose completion already claimed
	// the terminal (parked on arbitration, or mid-settlement) used to remove
	// the pending request, write the error outcome and settle — mixing the
	// completion's usage/profile with this frame's outcome. The claim is the
	// single ownership token across terminal TYPES: a frame that cannot claim
	// is a duplicate of an in-flight owned terminal and is dropped here,
	// leaving the pending request to its owner. Without a profile (profiler
	// off) there is no token and the RemovePending race decides, as before.
	// claimedHere is set only when THIS call took the claim: a pending request
	// a consumer-side cleanup removes between the claim and RemovePending
	// would otherwise never finalize (neither the funnel nor the fallback
	// completes a claimed terminal).
	var claimedHere *registry.AttemptProfile
	pending := provider.GetPending(msg.RequestID)
	if pending != nil && pending.Profile != nil && !compactOnlyAttempt(pending.Profile) && !owned {
		if !pending.Profile.ClaimTerminal() {
			s.deps.Logger().Warn("duplicate error for in-flight request", "provider_id", providerID)
			s.deps.Metrics.Incr("inference.unknown_request_frames", []string{"kind:duplicate_error"})
			s.unknownRequestFrames.Add(1)
			msg.Profile = nil
			return
		}
		owned, claimedHere = true, pending.Profile
		// Retain the profile now, while the owner still holds the pending
		// request: the record closes at the unknown-request return below if a
		// consumer-side cleanup removes it before RemovePending.
		s.deps.RetainProfile(pending.Profile, msg.Profile)
		msg.Profile = nil
	}
	if pending != nil && attempt.IsDrainingErrorReason(msg.ErrorReason) {
		s.noteProviderDraining(providerID, pending.Model)
	}
	pr := provider.RemovePending(msg.RequestID)
	// Clear any parked settlement record (consumer disconnected mid-stream).
	// Same object as a non-nil pr when the terminal raced the disconnect defer.
	parked := s.deps.ClaimSettlement(msg.RequestID)
	// See CompleteAt: a terminal with no live pending record is matched
	// against the cancel the coordinator sent for it (metric-only).
	var cancelled attempt.Cancellation
	wasCancelled := false
	if pr == nil {
		cancelled, wasCancelled = s.deps.Attempts().ResolveCancelledTerminal(
			msg.RequestID, attempt.CancelTerminalError, attempt.CancelledErrorOutcome(msg), time.Now())
		pr = parked
	}
	if pr == nil {
		if wasCancelled && cancelled.Cause() != attempt.CancelCauseStrayChunk {
			// Coordinator-minted id (it matched a recorded cancel): the
			// provider honored the cancel before producing output.
			s.deps.Logger().Debug("error for cancelled request",
				"request_id", msg.RequestID, "provider_id", providerID,
				"cause", cancelled.Cause(), "status_code", msg.StatusCode)
		} else {
			// request_id is provider-controlled until it matches coordinator-owned
			// pending state. Do not log it: an attacker could use unknown IDs as an
			// arbitrary log exfiltration channel.
			s.deps.Logger().Warn("error for unknown request", "provider_id", providerID)
			s.deps.Telemetry.UnknownFrame(unknownFrameKindError, provider)
		}
		s.deps.Metrics.Incr("inference.unknown_request_frames", []string{"kind:error"})
		s.unknownRequestFrames.Add(1)
		// A terminal claimed here whose pending request a consumer-side cleanup
		// removed in between: the provider errored, the coordinator lost
		// ownership; close the record rather than leak the attempt. An owned
		// claim passed in by CompleteAt is closed by that caller instead
		// (as "completed"); both calls are nil-safe when nothing was claimed.
		claimedHere.SetOutcome("", "", "", "error", "")
		claimedHere.CompleteTerminal()
		return
	}
	// From this point onward use only the coordinator-owned identifier.
	msg.RequestID = pr.RequestID
	if pending == nil && attempt.IsDrainingErrorReason(msg.ErrorReason) {
		// A consumer-gone request may already be parked outside the pending
		// map. Fence its provider before SetProviderIdle drains queued work.
		s.noteProviderDraining(providerID, pr.Model)
	}
	if ap := pr.Profile; ap != nil {
		if compactOnlyAttempt(ap) {
			ap.ClaimTerminal()
		}
		ap.Mark(registry.StampCompleteIngress)
		// A pending entry was claimed at the peek above; a PARKED record (no
		// pending entry) is claimed here. claimSettlement is single-winner, so
		// retention is exactly-once; in the narrow parked race (an owned
		// completion claims on its worker, a post-commit disconnect parks the
		// record, and this error frame wins the parked settlement) the settler
		// can differ from the claim owner — the completion then closes its own
		// record as completed without billing while this frame settles, which
		// is safe because this defer is unconditional. Only the owner retains
		// the profile, once.
		if owned || ap.ClaimTerminal() {
			s.deps.RetainProfile(ap, msg.Profile)
		}
		msg.Profile = nil
		// Leave final_status/error_reason to the phase-aware classifier (the
		// relay or dispatch loop writes partial_success / error / cancelled
		// through the route-outcome funnel); only the terminal cause and the
		// provider-side outcome are authoritative here.
		ap.SetOutcome("", "", string(msg.TerminalCause), "error", "")
		// The terminal half completes when this handler returns: after the
		// parked (consumer-gone) branch has classified partial_success, and
		// after the live branch has pushed the error to its channel reader.
		defer ap.CompleteTerminal()
	}
	// The request is terminal — drop its memoized chunk-decryption key.
	s.chunkKeys.forget(pr.SessionPrivKey)
	consumerGone := parked != nil
	// Provider errors carry no validated cache usage, but still close the
	// selection/outcome correlation denominator as an unreported result.
	s.deps.Cache.Terminal(pr, protocol.UsageInfo{}, false, false)

	// Record a job failure, but not for capacity rejections or consumer
	// cancellations — neither is a provider fault. Capacity = load shedding the
	// coordinator reroutes. Cancel (499 / "request cancelled") = the CONSUMER
	// disconnected; before the settlement holder these terminals died on
	// pr==nil with zero reputation effect, and the old fleet emits one for
	// every mid-stream disconnect — penalizing them would erode the whole
	// fleet's reputation for consumer behavior.
	//
	// A structured health-neutral error_reason is exempt too
	// (isProviderHealthNeutralErrorReason): jinja_* template-render failures (E4 —
	// the model's chat template could not render the REQUEST's tool schemas
	// or message history, a request-shape fault that fails identically on
	// every provider; prod: jinja requests averaged 1.57 dispatch rows, each
	// one erasing reputation fleet-wide for a body the provider never
	// controlled) and tool_noncompliance (E5 — the MODEL's sampled output
	// broke a forced tool_choice contract; the 422 stays on the bounded
	// failover path precisely because a re-sample can comply, so each
	// attempted provider must not eat a reputation strike for what the model
	// generated), plus deadline_unreachable (the coordinator-supplied remaining
	// SLA could not be met). A plain 422 with no structured reason still counts
	// — only the typed vocabulary exonerates.
	// Typed terminal cause (new providers). Classify once and emit the typed
	// terminal metrics; neutral (safety_deadline / backpressure_timeout /
	// cancelled — platform policy or consumer behavior) and capacity
	// (admission_timeout — healthy but busy) causes are exempt from the fault
	// recorder below regardless of status/string shape. Absent, engine_error,
	// or unknown causes keep the legacy heuristics bit-for-bit.
	causeClass := s.deps.Attempts().TypedTerminal(msg.TerminalCause)
	causeNeutralForHealth := causeClass == attempt.CauseClassNeutral || causeClass == attempt.CauseClassCapacity

	capacityRejection := msg.FailureCode == protocol.FailureCodeCapacity ||
		msg.FailureCode == protocol.FailureCodeModelUnavailable ||
		causeClass == attempt.CauseClassCapacity
	cancelTerminal := msg.FailureCode == protocol.FailureCodeCancelled ||
		msg.TerminalCause == attempt.TerminalCauseCancelled
	providerHealthNeutral := attempt.IsProviderHealthNeutralErrorReason(msg.ErrorReason)
	if !capacityRejection && !cancelTerminal && !providerHealthNeutral && !causeNeutralForHealth {
		s.deps.Registry().RecordJobFailure(providerID)
	}

	// Cool down a load-rejecting pair so retries skip it (see
	// dispatchLoadCooldowns). Covers BOTH flavors: capacity rejects
	// ("insufficient memory", not a fault) and generic load failures ("model
	// load failed": bad weights/metallib/kernel — IS a fault, reputation hit
	// above stands). The cool-down matters most during an alias migration: a
	// build that verifies on disk but cannot GPU-load would otherwise keep
	// attracting 100% of the alias traffic as repeated 500s — cooling the pair
	// makes the desired build unroutable so alias resolution falls back to the
	// previous build.
	// A typed fully-neutral cause (safety_deadline / backpressure_timeout /
	// cancelled) is strictly neutral, and a typed capacity cause
	// (admission_timeout) feeds ONLY the capacity cooldown recorded in
	// noteInferenceError — neither may feed the load cooldown. Their error
	// text never carries the load-failure vocabulary anyway; the explicit
	// allowlist (legacy or fault only) makes both guarantees unconditional
	// rather than dependent on provider error-string phrasing.
	if (causeClass == attempt.CauseClassLegacy || causeClass == attempt.CauseClassFault) &&
		msg.ErrorReason == attempt.ErrorReasonModelLoad {
		if s.deps.Registry().RecordDispatchLoadFailure(providerID, pr.Model) {
			s.deps.Logger().Warn("load-failure cool-down started",
				"provider_id", providerID,
				"model", pr.Model,
			)
			s.deps.Metrics.Incr("routing.load_failure_cooldowns", []string{"model:" + pr.Model})
		}
	}

	s.deps.Registry().SetProviderIdle(providerID)

	if consumerGone {
		status := "partial_success"
		errorClass := "client_gone_after_commit_provider_error"
		if cancelTerminal {
			errorClass = "client_gone_after_commit_provider_cancelled"
		}
		// After-commit client cancellation: the provider terminated (error /
		// cancel / disconnect) after the consumer had already gone. Count it on
		// routing.client_gone so the after_commit phase reflects ALL post-commit
		// disconnects, not just provider-completed ones (CompleteAt). A
		// no-terminal disconnect is counted by the settlement grace path.
		s.deps.Telemetry.ClientGone(pr.Model, pr.EstimatedPromptTokens, dispatch.ProviderChipFamily(provider), dispatch.PhaseAfterCommit)
		outcome := attempt.PendingRouteOutcomeWithReason(pr, status, errorClass, msg.StatusCode, msg.ErrorReason, msg.Error)
		if !cancelTerminal {
			outcome.AdmittedButFailed = true
		}
		attempt.ApplyAttemptUsage(outcome, msg.AttemptUsage)
		s.deps.Outcomes.PendingOutcome(pr, outcome)
		// Consumer disconnected — no reader for the channels; settle by
		// refunding, OFF the read loop (a store Credit can block for seconds
		// under DB pressure, and blocking this loop stalls heartbeats and
		// challenge responses — the eviction-churn vector). Idempotent vs. the
		// settlement grace timer via FinalizeReservation.
		//
		// Deliberately NOT unconditional: during the dispatch retry window the
		// consumer handler keeps the base reservation alive for the next
		// attempt — refunding/finalizing it here would let a later successful
		// attempt settle against a dead reservation (served for free). Errors
		// with a live consumer are refunded by their channel readers (relay /
		// dispatch-exhaustion paths); the relay-return→park gap is swept by
		// the post-commit defer's last-chance refund in coordinator/api/consumer.go.
		refundPr := pr
		refundID := msg.RequestID
		saferun.Go(s.deps.Logger(), "api.refundAfterDisconnect", func() {
			s.deps.Settlement().Refund(refundPr, "provider_error_after_disconnect:"+refundID)
		})
		return
	}

	pr.ErrorCh <- *msg
	close(pr.ChunkCh)
	close(pr.CompleteCh)
	close(pr.ErrorCh)

	s.deps.Logger().Error("inference error",
		"request_id", msg.RequestID,
		"provider_id", providerID,
		"failure_code", msg.FailureCode,
		"status_code", msg.StatusCode,
		"terminal_cause", msg.TerminalCause,
	)
}
