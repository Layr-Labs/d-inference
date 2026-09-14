package dispatch

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/response"
)

const (
	// inferenceTimeout is the maximum time to wait between chunks (streaming)
	// or for the full response (non-streaming). For streaming, the deadline
	// resets on each received chunk so long-running generations don't time out.
	// 10 minutes allows 32k tokens at ~55 tok/s on slower hardware.
	inferenceTimeout = response.InferenceTimeout

	// DefaultFirstContentDeadlineBase preserves the ordinary coordinator and
	// unit-test budget. Production overrides it to 9s through validated startup
	// configuration; exact model overrides live in modelpolicy and every request
	// adds 1ms per estimated prompt token.
	DefaultFirstContentDeadlineBase = 5 * time.Second

	// preambleContentTimeout is the relative cap from the first boilerplate
	// chunk to the first CONTENT chunk. A provider that produced only preamble
	// (role delta / Responses lifecycle) has written ZERO bytes to the client,
	// so a role-then-stall zombie must fail over instead of pinning the request
	// for the full inferenceTimeout. 90s covers the measured pre-content tail
	// (vision prefill is 6-30s). When ReceivedAt is stamped this cap cannot
	// exceed leftover request-absolute first-token budget: AcceptedCh is not a
	// completion token and must not reset that clock.
	preambleContentTimeout = 90 * time.Second

	// chunkBufferSize is the channel buffer size for SSE chunks flowing from
	// the provider to the consumer. A larger buffer prevents dropped chunks
	// when the consumer reads slowly.
	chunkBufferSize = 256

	// maxDispatchAttempts is a SAFETY CEILING on per-request provider failover,
	// not the normal stopping point. A request keeps failing over to fresh
	// healthy providers until one succeeds, OR candidates are exhausted (every
	// failed provider is excluded from re-selection, so dispatchPrimary returns
	// outcomeFailFast on the next attempt once no eligible provider remains), OR
	// the request's deadline/context fires (run() checks r.Context() each
	// attempt). This ceiling only guards against a pathological retry path that
	// fails to exclude a provider (an unbounded hot loop); it is set well above
	// any realistic per-request fault count. Retries never re-queue — only the
	// first attempt may wait for capacity — so failover stays fast, walking the
	// immediately-available healthy providers rather than waiting on busy ones.
	maxDispatchAttempts = 64

	// maxCapacityClassRetries bounds failover specifically for TRANSIENT-capacity
	// rejections (this provider's live KV budget, a full queue, an update drain).
	// Such a shortage MAY clear on another provider, so we fail over — but only a
	// few times, so a fleet-wide transient (or an oversized request the determinism
	// check didn't tag) cannot walk all maxDispatchAttempts providers and 503 each
	// (the prod storm: median 22, max 63 attempts, ~8.7 min, 0% eventual success).
	// A DETERMINISTIC-context rejection (prompt > model context, identical on every
	// provider) stops on the FIRST attempt regardless — see classifyRejection.
	maxCapacityClassRetries = 3

	// maxFirstChunkTimeoutRetries bounds failover for coordinator-synthesized
	// first-chunk TIMEOUTS (the untyped 504 the exhausted ladder reclassifies
	// to a retryable 429 with reason "first_chunk_timeout"). Unlike capacity
	// rejections these carried NO cap: every retry re-ran a full fleet
	// reservation scan (~1,260 providers, registry.ReserveProviderEx), and in
	// the 2026-09-01 congestion collapse retry-amplified inbound (~100 req/s
	// of retryable 429 traffic from OpenRouter) times per-request fleet scans
	// saturated every coordinator CPU — attempt-0 route p50 went 40ms → 4.6s,
	// success ~40%, 429s were delivered after 11s, inbound ~6k/min vs served
	// ~550/min. The request-absolute first-content budget already bounds WALL
	// time per request; this bounds CPU: after this many timed-out attempts
	// (each on a distinct provider — a timed-out provider is excluded from
	// re-selection) the ladder exhausts immediately into the existing
	// synthetic-timeout → 429 reclassification (classifyExhaustedStatus).
	maxFirstChunkTimeoutRetries = 3

	// SpeculativeTimerRatio is the fraction of the TTFT deadline at which
	// the coordinator launches a speculative backup dispatch. The primary
	// provider gets this fraction of the deadline before the backup is
	// started, and then both race until one produces the first chunk.
	SpeculativeTimerRatio = 0.5

	// maxHeldBoilerplate bounds how many pre-content boilerplate chunks the
	// dispatch loop holds per provider before committing anyway. Real
	// preambles are one chunk (chat role delta) or two (Responses
	// created/in_progress), so the cap exists only to stop a misbehaving
	// provider from growing the held buffer for the whole inference window.
	// Excess boilerplate is dropped while the first-content clock continues;
	// it must never be mistaken for content and commit a bad provider.
	maxHeldBoilerplate = 8
)
