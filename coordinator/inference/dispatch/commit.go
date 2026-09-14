package dispatch

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	attemptpolicy "github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// commitFirstContent records the first CONTENT chunk on the committed attempt and
// stamps FirstContentAt (the actual_ttft_ms anchor) in the SAME instant, on the
// dispatch goroutine that reads the chunk. Stamping HERE — rather than later in
// writeCommittedResponse — guarantees FirstContentAt is set before ANY route
// outcome is built for this attempt: the committed/success outcome written by
// this goroutine (e.g. waitFirstChunk / waitAccepted's defer) AND the terminal
// CompleteRouteOutcome written concurrently by handleComplete on the provider
// read-loop. Without it a fast single-chunk completion could persist
// actual_ttft_ms as 0/NULL (applyPendingRouteTelemetry derives it solely from
// FirstContentAt). pr is the COMMITTED attempt — the backup on a speculative
// backup win, the primary otherwise. MarkFirstChunkArrived is kept (idempotent:
// it preserves an earlier preamble's first-byte time for dispatch_to_first_chunk_ms).
func (d *execution) commitFirstContent(pr *registry.PendingRequest, chunk string) {
	d.firstChunk = chunk
	pr.MarkFirstChunkArrived()
	pr.MarkFirstContentArrived()
	d.stampFirstContent(pr)
	// Mark THIS attempt as the committed one so handleComplete's fallback only
	// ever stamps FirstContentAt for the attempt that actually delivered content —
	// never a late-completing abandoned/retried attempt sharing the same Timing.
	pr.MarkContentCommitted()
	d.s.observeTTFTCalibration(pr)
	// First CONTENT chunk == the provider ACCEPTED and is serving: clear the
	// pair's capacity-reject streak NOW rather than at completion. A long
	// generation on a busy box must keep vouching for the pair while the box
	// legitimately sheds concurrent dispatches — waiting for the completion
	// accept (noteInferenceSuccess) would let transient fullness masquerade as
	// the zero-accepts black-hole signature. See registry/capacity_cooldown.go.
	//
	// The recorder takes the registry WRITE lock, which in production waits
	// behind every queued writer (~190 ms at the median, seconds at the tail),
	// and this runs BEFORE the chunk is written to the client. It is pure
	// bookkeeping, so it runs off this goroutine and the first byte no longer
	// waits for it. Exactly-once for the capacity-503 RATE window is kept by
	// stamping the request BEFORE the recorder runs: the completion-time
	// re-offer (noteInferenceSuccess) fires only for an unstamped request, and
	// the recorder declines to store an offered accept only when rate tracking
	// is disabled (PenaltyMs <= 0) — in which case the completion re-offer
	// would store nothing either. So the unconditional stamp never loses an
	// outcome and never double counts.
	//
	// The accept carries the instant it was OBSERVED — the first content
	// chunk, stamped above by MarkFirstContentArrived — not the instant the
	// goroutine finally holds the lock: a capacity reject for the same pair
	// recorded in between happened AFTER this accept and must survive it
	// (registry.RecordCapacityAcceptObserved).
	pr.MarkRateOutcomeCounted()
	providerID, model := pr.ProviderID, pr.Model
	observedAt := pr.FirstContentAtSafe()
	if observedAt.IsZero() {
		observedAt = time.Now()
	}
	saferun.Go(d.s.deps.Logger(), "api.recordCapacityAccept", func() {
		d.s.deps.Registry().RecordCapacityAcceptObserved(providerID, model, observedAt, true)
	})
}

func (d *execution) successRoutingOutcomeFor(pr *registry.PendingRequest) *store.InferenceRouteOutcome {
	return attemptpolicy.CommittedRouteOutcome(pr)
}

// contentLatency is the time from dispatch to the first CONTENT chunk delivered
// to the client (FirstContentAt). It deliberately does NOT fall back to
// FirstChunkAt — that timestamp is also stamped on held role-only / lifecycle
// preamble, so using it would let a fast-preamble-then-stall provider (or a
// preamble-only clean close that produced no content) look artificially
// responsive. Returns 0 when no content was delivered or the timing is
// incomplete, which the caller treats as "no sample".
func contentLatency(t *registry.RequestTiming) time.Duration {
	if t == nil || t.DispatchedAt.IsZero() || t.FirstContentAt.IsZero() {
		return 0
	}
	if d := t.FirstContentAt.Sub(t.DispatchedAt); d > 0 {
		return d
	}
	return 0
}

// adjustLatencyForPrefill turns a raw time-to-first-content into the reputation
// latency sample by removing the prompt-size-dependent prefill. Time-to-first-
// token grows with the input length, so a provider serving long prompts would
// otherwise look slow purely because of its workload. Using the provider's own
// benchmarked prefill rate keeps the correction per-provider and free of
// hard-coded constants; what remains approximates queueing, scheduling,
// model-load and first-decode overhead. Returns 0 when there is no usable sample
// (which RecordLatency ignores), including when the prefill estimate exceeds the
// measured latency.
func adjustLatencyForPrefill(raw time.Duration, promptTokens int, prefillTPS float64) time.Duration {
	if raw <= 0 {
		return 0
	}
	if promptTokens > 0 && prefillTPS > 0 {
		raw -= time.Duration(float64(promptTokens) / prefillTPS * float64(time.Second))
	}
	if raw <= 0 {
		return 0
	}
	return raw
}

func shouldRecordReputationLatency(pr *registry.PendingRequest, firstChunk string) bool {
	return pr != nil && pr.Timing != nil && firstChunk != "" && !pr.CacheRoutingParticipates()
}

// writeCommittedResponse writes the provider attestation + timing headers, installs
// the park-before-remove settlement defer, and hands off to the streaming /
// non-streaming response writer. Extracted verbatim from the committed tail of the
// original handler.
func (d *execution) writeCommittedResponse() {
	s := d.s
	w, r := d.w, d.r
	provider, pr, requestID := d.provider, d.pr, d.requestID

	// Record the provider responsiveness sample here, in the goroutine that OWNS
	// pr.Timing. handleComplete runs in the provider read-loop goroutine and could
	// race this goroutine's timing writes, so the latency must be recorded from
	// here rather than handed across. d.firstChunk is non-empty only when an actual
	// content chunk was received — a preamble-then-clean-close commits with no
	// content, so FirstContentAt stays zero and no sample is recorded. The
	// prompt-size prefill is removed using the coordinator-side prompt estimate
	// (known up front, adequate for normalization) and the provider's benchmarked
	// PrefillTPS (set once at registration, read-only thereafter).
	if shouldRecordReputationLatency(pr, d.firstChunk) {
		// FirstContentAt was already stamped at the content-commit site
		// (commitFirstContent), earlier in THIS goroutine, so contentLatency reads
		// a set value here. No re-stamp needed; just read it for the reputation
		// latency sample.
		sample := adjustLatencyForPrefill(contentLatency(pr.Timing), pr.EstimatedPromptTokens, provider.PrefillTPS)
		// Provider-level: p.mu only. The registry-level form looks the
		// provider up under r.mu, and this runs before the first client write.
		provider.RecordLatency(sample)
	}

	// Write provider attestation headers now that we're committed. When the
	// caller opted into metadata_details, snapshot the same consumer-safe
	// fields onto the pending request so chat-completions writers can attach
	// them to the JSON body (OpenAI SDKs often hide custom headers).
	info := response.CollectCommittedProviderInfo(provider)
	response.WriteCommittedProviderHeaders(w, info)
	d.writeTimingHeaderWithProfile(w, pr)
	d.stampCommitted(pr)
	response.WriteInferenceJobIDHeader(w, pr.RequestID)
	response.SnapshotChatCompletionMetadata(pr, info)

	// On return (disconnect/timeout/completion): free the slot, tell the
	// provider to stop if it may still be generating, and preserve billing for
	// a mid-stream disconnect.
	// Park BEFORE RemovePending so a racing provider terminal always finds the
	// record in pending or the holder — never neither (which would drop it and
	// mis-refund). GetPending is nil if a terminal already settled it (normal
	// completion), so nothing is parked then. Both settle paths are
	// FinalizeReservation-guarded, so the park-then-remove overlap can't double-bill.
	//
	// The cancel is sent only when a pending record still existed — no terminal
	// seen, so the provider may still be running (consumer gone mid-stream, idle
	// stream timeout). After a clean completion or a provider error terminal the
	// record is already gone and a cancel would only cost the provider a no-op
	// frame per request (~one per dispatch fleet-wide before this rule).
	defer func() {
		abandoned := false
		cause := attemptpolicy.CancelCauseStreamTimeout
		if r.Context().Err() != nil {
			cause = attemptpolicy.CancelCauseClientGonePost
		}
		if stale := provider.GetPending(requestID); stale != nil {
			// Record the abandon BEFORE parking so a terminal racing this
			// defer is correlated with the cancel rather than logged as unknown.
			s.deps.Attempts().RecordAbandon(requestID, pr.Model, cause, time.Now())
			s.deps.HoldForSettlement(stale)
			abandoned = true
		} else {
			// A terminal already claimed the pending. In every normal path the
			// reservation is finalized by now (completion billed it, the relay
			// error/timeout branches refunded it) and this is a no-op. The one
			// exception is a provider error landing in the gap between this
			// handler abandoning its channels and this defer running: that
			// terminal pushed into an unread ErrorCh and nobody settled — sweep
			// it here. Post-commit only, so it can never finalize a reservation
			// the dispatch loop still needs for a retry attempt.
			refundPr := pr
			saferun.Go(s.deps.Logger(), "api.postTerminalSweep", func() {
				s.deps.Settlement().Refund(refundPr, "post_terminal_sweep:"+requestID)
			})
		}
		removed := provider.RemovePending(requestID) // then remove so SetProviderIdle frees the slot
		s.deps.Registry().SetProviderIdle(provider.ID)
		if !abandoned {
			return
		}
		if removed == nil {
			// A terminal claimed the record between GetPending and
			// RemovePending: it settles via the parked copy and nothing is
			// running provider-side.
			s.deps.Attempts().ForgetCancel(requestID)
			return
		}
		// The provider is still generating for a client that is gone: this
		// cancel is the one that stops real work, so stamp it.
		pr.Profile.Mark(registry.StampCancelSent)
		s.deps.Attempts().SendRecordedCancel(provider, requestID, pr.Model, cause)
	}()

	// The committed provider's held preamble chunks stream out first, in
	// arrival order, ahead of the content chunk that committed the dispatch.
	firstChunks := d.heldChunks
	if d.firstChunk != "" {
		firstChunks = append(firstChunks, d.firstChunk)
	}
	if d.stream {
		s.deps.Response().Stream(
			w, r, pr, firstChunks, d.initialError)
	} else {
		// Record the OR-uptime outcome from the status the non-streaming writer
		// actually emits: it can still return a 5xx/504 after commit, and a
		// client-gone exit writes no status (0 → not counted, cancelled is excluded).
		// httpresponse.StatusWriter captures the WriteHeader code and transparently
		// delegates Flush/Hijack/Unwrap, so wrapping preserves the writer's
		// capabilities; zero-valued status starts at 0 (uncounted).
		sw := httpresponse.NewStatusWriter(w, 0)
		s.deps.Response().NonStream(
			sw, r, pr, firstChunks, d.initialError)
		switch {
		case sw.Status() == http.StatusOK:
			d.recordDispatchedRequestOutcome(d.KVBackendAttribution(), OrClassSuccess)
		case sw.Status() > 0:
			d.recordDispatchedRequestOutcome(
				d.KVBackendAttribution(), ClassifyOutcomeByCode(sw.Status()))
		}
	}
}
