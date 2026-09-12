package registry

import (
	"encoding/json"
	"sync"
	"sync/atomic"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ProviderChunk carries a response chunk with its coordinator ingress time.
// ReceivedAt retains time.Now's monotonic component, so deadline comparisons
// remain correct while a chunk waits in a buffered channel.
type ProviderChunk struct {
	Data       string
	ReceivedAt time.Time
}

// PendingRequest is a channel-based handle for an in-flight inference request.
type PendingRequest struct {
	RequestID string
	// Attempt is the zero-based dispatch attempt number that produced this
	// pending request. It lets outcome telemetry correlate the final result
	// with the routing decision record for the same attempt.
	Attempt int
	// FirstContentBudgetMS is the positive remaining first-content budget for
	// this dispatch attempt. It is an in-memory carrier for the provider wire;
	// zero means no budget is attached.
	FirstContentBudgetMS int64
	// FirstContentDeadline is the request-absolute first-content deadline.
	// Queue drain and provider-writer dequeue refresh their attempt-local
	// ceilings from this timestamp; zero preserves legacy relative behavior.
	FirstContentDeadline time.Time
	ProviderID           string
	// Model is the CONCRETE build id used for routing, admission, billing, and
	// warm-model matching (e.g. "mlx-community/gemma-4-26B-A4B-it-qat-4bit").
	Model string
	// PublicModel is the consumer-facing name the caller requested (e.g.
	// "gemma-4-26b"). When the request used a raw build id directly this equals
	// Model. Responses echo PublicModel so consumers never see the quant/build.
	PublicModel string
	ConsumerKey string
	// KeyID is the public ID of the API key that originated the request, used
	// for per-key usage and spend attribution. Empty for account-scoped/legacy
	// callers (Privy JWT, admin, provider tokens, unlinked keys without an ID).
	KeyID string
	// KeyLimitMicroUSD / KeyLimitReset carry the originating key's spend cap so
	// the per-key cap can be re-enforced when a provider's custom price tops up
	// the reservation above the platform rate. Nil limit = no per-key cap.
	KeyLimitMicroUSD *int64
	KeyLimitReset    string
	ConsumerLocation *store.ProviderLocation
	// IsResponsesAPI tracks requests received through /v1/responses so the
	// coordinator can translate provider chat-completions output back into
	// Responses API objects for SDK clients.
	IsResponsesAPI bool
	// ConsumerEndpoint identifies a non-chat API whose request was lowered to
	// the provider's chat-completions wire shape. Response writers translate
	// chat output back to this endpoint's native JSON/SSE schema.
	ConsumerEndpoint string
	// RequestedStopSequences is the caller-authored Anthropic stop allowlist.
	// MatchedStopSequence is accepted from the provider only when it is a member
	// of this list, then translated back into native /v1/messages responses.
	// Both fields are in-memory only and must never enter routing telemetry.
	RequestedStopSequences []string
	MatchedStopSequence    string
	// AllowedProviderSerials optionally restricts routing to providers with
	// one of these attested hardware serials. Empty means the request may
	// route to any eligible provider.
	AllowedProviderSerials []string
	// ExcludedProviderIDs carries pre-dispatch incompatibilities across queue
	// drains after the dispatcher has released the rejected provider.
	ExcludedProviderIDs []string
	// SelfRouteOnly restricts routing to providers owned by OwnerAccountID
	// (the "use my own machine" path). When set, the scheduler skips every
	// provider whose AccountID != OwnerAccountID and never falls back to the
	// public fleet. The owner-match is on the coordinator-stamped AccountID,
	// never on any client-supplied value.
	SelfRouteOnly bool
	// PreferOwner is the "prefer my own machine, but fall back to the paid
	// fleet" mode. Unlike SelfRouteOnly it does NOT exclude public providers:
	// the scheduler picks the caller's own machine whenever one can serve, and
	// only falls back to the public fleet (charged normally) when none can. The
	// hardware-trust floor is relaxed for the caller's own (possibly un-enrolled)
	// machine, exactly as for SelfRouteOnly, but never for public providers.
	// Billing is decided at settlement: free if an owned machine actually served
	// it, paid otherwise — so a PreferOwner request takes a normal reservation
	// up front (unlike SelfRouteOnly, which skips it).
	PreferOwner bool
	// OwnerAccountID is the authenticated account that must own the serving
	// provider when SelfRouteOnly or PreferOwner is set. Stamped server-side
	// from the request's authenticated identity.
	OwnerAccountID string
	// FreeSelfRoute marks a request that must settle at zero cost (no charge,
	// no platform fee, no provider payout) because it is served by a machine
	// the requesting account owns. handleComplete re-verifies ownership of the
	// serving provider before honoring this flag.
	FreeSelfRoute bool
	// EstimatedPromptTokens is a coordinator-side heuristic used only for
	// routing and queue admission. It does not need tokenizer-perfect accuracy.
	EstimatedPromptTokens int
	// RequiresVision is true when the request carries image/video input. Such a
	// request must only be routed to a provider advertising a vision-capable
	// (VLM) build for the resolved model; otherwise the provider would silently
	// drop the media and answer image-blind. Set by the consumer handler from the
	// parsed content parts; enforced in the candidate filter and final admit.
	RequiresVision bool
	// Traits carries request-shape attributes beyond the model id (tool
	// schemas, retry version-diversity) that gate or bias provider selection.
	// Set by the consumer handler; enforced in the candidate filter and final
	// admit. See RequestTraits.
	Traits RequestTraits
	// RequestedMaxTokens is the consumer's requested output budget (or a
	// sensible default when omitted). It is used for backlog estimation.
	RequestedMaxTokens int
	// MaxTTFTMs is an optional per-request TTFT ceiling in milliseconds.
	// When > 0, the scheduler only selects providers whose estimated TTFT is
	// <= MaxTTFTMs. Used by public inference routes to honor the public
	// TTFT target. Self-route / prefer-owner and vision requests leave this at
	// 0; the scheduler also ignores an accidental ceiling on vision because its
	// decode and tower work are absent from the text-prefill estimate.
	MaxTTFTMs float64
	// MinDecodeTPS is an optional per-request sustained-decode floor in tokens/sec
	// (Routing v2 W2). When > 0, the scheduler PREFERS providers that would still
	// deliver >= MinDecodeTPS to a newly admitted request (i.e. not overpack a
	// provider into a degraded stream). It is a SOFT preference: if no candidate
	// meets the floor, the full pool is kept so the request is still served
	// (cold-dispatch/queue spill is a separate concern). 0 disables it.
	MinDecodeTPS float64
	// CachePlan contains exact sidecar block boundaries and opaque build scope.
	// It is never logged or persisted.
	CachePlan              CachePlan
	cacheAttempt           atomic.Pointer[cacheAttemptOwner]
	cacheAttemptMu         sync.Mutex
	cachePreparationTicket uint64
	cachePreparationClosed bool
	// LegacyCacheBustKey is injected only into the encrypted provider-bound
	// request body for protocol-0 providers. It is never reflected to the caller.
	LegacyCacheBustKey string
	// Cache selection fields are low-cardinality terminal-correlation metadata.
	// They contain no route keys, scopes, account identifiers, or provider IDs.
	CacheSelectionMode       string
	CacheSelectionTier       string
	CacheSelectionDiscountMs float64
	// CacheSelectionEstimatedTTFTSavedMs is the selected cache holder's
	// age-weighted prefill time saved minus the full SSD stage time. It is
	// aggregate numeric telemetry only and contains no cache identity.
	CacheSelectionEstimatedTTFTSavedMs float64
	CacheSelectionSelected             bool
	cacheRoutingHints                  map[string]cacheRoutingHint
	// TokenAdmission records the output-token charge admitted at request time so
	// successful completion can reconcile any positive actual-output delta.
	TokenAdmission TokenAdmission
	AcceptedCh     chan struct{}           // signalled when provider accepts request
	ChunkCh        chan ProviderChunk      // SSE data chunks stamped at ingress
	CompleteCh     chan protocol.UsageInfo // closed after usage sent
	ErrorCh        chan protocol.InferenceErrorMessage
	SessionPrivKey *[32]byte // E2E session private key for decrypting responses
	SESignature    string    // SE signature over response hash
	ResponseHash   string    // SHA-256 of response data
	// MetadataDetails asks chat-completions writers to include the same
	// consumer-safe provider/attestation/timing details already returned in
	// X-Provider-* / X-Timing headers in the JSON body. Opt-in so default
	// OpenAI-compatible responses stay clean.
	MetadataDetails bool
	// ResponseMetadata is the JSON object snapshotted at commit when
	// MetadataDetails is true. Opaque to the registry; writers attach it as
	// the response "metadata" field. Nil when the caller did not opt in.
	ResponseMetadata json.RawMessage
	// Speculative backup telemetry. UsedBackup means a backup race was launched
	// for this logical request; BackupWon is true only on the serving backup.
	UsedBackup atomic.Bool
	BackupWon  atomic.Bool

	// ReservedMicroUSD is the balance atomically debited at pre-flight.
	// The post-inference charge adjusts for the difference between the
	// actual cost and this reservation, preventing billing race conditions.
	ReservedMicroUSD int64
	// BaseReservedMicroUSD is the shared base reservation (platform price)
	// charged once per request. ReservedMicroUSD may exceed it after a
	// provider-specific top-up; the difference (the per-attempt "extra") must
	// be refunded if this attempt is abandoned (speculative loser, retry,
	// timeout). The base itself is refunded once globally or settled by the
	// winning attempt.
	BaseReservedMicroUSD int64
	// ServiceReservation marks a trusted service account request whose pre-router
	// admission used an in-memory hold instead of a synchronous ledger debit.
	ServiceReservation    bool
	reservationMu         sync.Mutex
	reservationFinalized  bool
	routeOutcomeMu        sync.Mutex
	routeOutcomeFinalized bool
	cacheTerminalEmitted  bool

	// Timing fields for latency decomposition. Written and read by the
	// consumer/dispatch goroutine that owns the request. The reputation latency
	// sample is recorded from that goroutine at commit (see
	// dispatch.writeCommittedResponse). The TWO fields the provider read-loop
	// goroutine (handleComplete) also needs — FirstChunkAt (X-Timing
	// provider-first-byte diagnostic + decode-throughput metric) and
	// FirstContentAt (the delivered-content actual_ttft_ms metric) — must be
	// accessed via MarkFirstChunkArrived/FirstChunkAtSafe and
	// MarkFirstContentArrived/FirstContentAtSafe, which guard them with timingMu
	// so cross-goroutine access is race-free. All other Timing fields remain
	// dispatch-goroutine-only.
	Timing *RequestTiming
	// Profile is this attempt's profiler record (system profiler). Nil when the
	// profiler is off. Stamped lock-free from any goroutine; see request_profile.go.
	Profile  *AttemptProfile
	timingMu sync.Mutex
	// contentCommitted marks THIS attempt as the one that delivered its first
	// content chunk to the client (set by commitFirstContent / the generic
	// first-content stamp, in the dispatch/handler goroutine). It distinguishes the
	// committed attempt from abandoned/retried attempts that SHARE the same Timing
	// pointer. handleComplete's fallback reads it (ContentCommittedSafe) so a
	// late-completing abandoned attempt can never stamp FirstContentAt on the
	// shared Timing and corrupt the committed attempt's actual_ttft_ms. Guarded by
	// timingMu (written in the dispatch/handler goroutine, read in the provider
	// read-loop goroutine).
	contentCommitted bool
	// Provider ingress arbitration is guarded by one lock so the read loop and
	// the absolute-deadline timer have a total order. A chunk is marked pending
	// before decrypt/classification; completion is marked before asynchronous
	// settlement.
	firstContentIngressMu     sync.Mutex
	chunkIngressPendingAt     time.Time
	firstContentIngressAt     time.Time
	completionIngressAt       time.Time
	completionIngressCh       chan struct{}
	completionIngressSignaled bool
	emptyCompletionMu         sync.Mutex
	emptyCompletionEnabled    bool
	emptyCompletionResolved   bool
	emptyCompletionAccepted   bool
	emptyCompletionDecision   chan struct{}
	// rateOutcomeCounted marks that this request's ONE capacity-503 rate
	// outcome (capacity_rate.go denominator) was recorded by the commit-time
	// accept — RecordCapacityAccept returned rateOutcomeRecorded=true. The
	// completion-time accept (noteInferenceSuccess) re-offers the outcome only
	// when this is false, covering requests that never commit content while a
	// commit-recorded request cannot double-count. Accepts are retained before
	// the first reject so event ordering cannot distort the five-minute rate.
	// Guarded by timingMu like contentCommitted (same writer/reader goroutines).
	rateOutcomeCounted bool
}

// BeginProviderChunkIngress timestamps a provider chunk under the same lock
// used by deadline arbitration, before decrypt/classification can yield.
func (pr *PendingRequest) BeginProviderChunkIngress() time.Time {
	if pr == nil {
		return time.Time{}
	}
	pr.firstContentIngressMu.Lock()
	receivedAt := time.Now()
	pr.chunkIngressPendingAt = receivedAt
	pr.firstContentIngressMu.Unlock()
	return receivedAt
}

// FinishProviderChunkIngress resolves the pending chunk classification and
// reports whether it is the attempt's first content-bearing chunk.
func (pr *PendingRequest) FinishProviderChunkIngress(
	receivedAt time.Time,
	contentBearing bool,
) bool {
	if pr == nil {
		return false
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	if pr.chunkIngressPendingAt.Equal(receivedAt) {
		pr.chunkIngressPendingAt = time.Time{}
	}
	if !contentBearing || !pr.firstContentIngressAt.IsZero() {
		return false
	}
	pr.firstContentIngressAt = receivedAt
	return true
}

// FirstContentIngressAtSafe returns the ingress timestamp of the first
// content-bearing chunk (zero when none), under the ingress lock.
func (pr *PendingRequest) FirstContentIngressAtSafe() time.Time {
	if pr == nil {
		return time.Time{}
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	return pr.firstContentIngressAt
}

// CompletionIngressAtSafe returns the completion-ingress timestamp (zero when
// no terminal has been marked), under the ingress lock.
func (pr *PendingRequest) CompletionIngressAtSafe() time.Time {
	if pr == nil {
		return time.Time{}
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	return pr.completionIngressAt
}

func (pr *PendingRequest) HasFirstContentIngress() bool {
	if pr == nil {
		return false
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	return !pr.firstContentIngressAt.IsZero()
}

func (pr *PendingRequest) markCompletionIngressLocked(receivedAt time.Time) time.Time {
	if pr.completionIngressAt.IsZero() {
		pr.completionIngressAt = receivedAt
	}
	if pr.completionIngressCh == nil {
		pr.completionIngressCh = make(chan struct{})
	}
	if !pr.completionIngressSignaled {
		close(pr.completionIngressCh)
		pr.completionIngressSignaled = true
	}
	return pr.completionIngressAt
}

// MarkCompletionIngress records a supplied completion-ingress timestamp.
func (pr *PendingRequest) MarkCompletionIngress(receivedAt time.Time) time.Time {
	if pr == nil || receivedAt.IsZero() {
		return time.Time{}
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	return pr.markCompletionIngressLocked(receivedAt)
}

// MarkCompletionIngressNow timestamps completion under the same lock used by
// deadline arbitration, eliminating the timestamp-to-publication race.
func (pr *PendingRequest) MarkCompletionIngressNow() time.Time {
	if pr == nil {
		return time.Time{}
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	return pr.markCompletionIngressLocked(time.Now())
}

func (pr *PendingRequest) CompletionIngressSignal() <-chan struct{} {
	if pr == nil {
		return nil
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	if pr.completionIngressCh == nil {
		pr.completionIngressCh = make(chan struct{})
	}
	return pr.completionIngressCh
}

// CompletionArrivedByFirstContentDeadline reports whether a clean terminal
// entered before the request-absolute first-content deadline.
func (pr *PendingRequest) CompletionArrivedByFirstContentDeadline() bool {
	if pr == nil || pr.FirstContentDeadline.IsZero() {
		return false
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	receivedAt := pr.completionIngressAt
	return !receivedAt.IsZero() && !receivedAt.After(pr.FirstContentDeadline)
}

// FirstContentIngressArrivedByDeadline reports whether deadline arbitration
// must wait for an on-time chunk under classification/delivery or an on-time
// completion under settlement.
func (pr *PendingRequest) FirstContentIngressArrivedByDeadline() bool {
	if pr == nil || pr.FirstContentDeadline.IsZero() {
		return false
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	for _, receivedAt := range []time.Time{
		pr.chunkIngressPendingAt,
		pr.firstContentIngressAt,
		pr.completionIngressAt,
	} {
		if !receivedAt.IsZero() && !receivedAt.After(pr.FirstContentDeadline) {
			return true
		}
	}
	return false
}

// OnTimeEmptyCompletionIngress returns the ingress time of an on-time clean
// completion that had no preceding content-bearing chunk.
func (pr *PendingRequest) OnTimeEmptyCompletionIngress() (time.Time, bool) {
	if pr == nil || pr.FirstContentDeadline.IsZero() {
		return time.Time{}, false
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	receivedAt := pr.completionIngressAt
	ok := pr.firstContentIngressAt.IsZero() &&
		!receivedAt.IsZero() &&
		!receivedAt.After(pr.FirstContentDeadline)
	return receivedAt, ok
}

// ContentIngressAtOrBefore reports whether content is being classified or has
// been classified with an ingress timestamp no later than cutoff.
func (pr *PendingRequest) ContentIngressAtOrBefore(cutoff time.Time) bool {
	if pr == nil || cutoff.IsZero() {
		return false
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	for _, receivedAt := range []time.Time{
		pr.chunkIngressPendingAt,
		pr.firstContentIngressAt,
	} {
		if !receivedAt.IsZero() && !receivedAt.After(cutoff) {
			return true
		}
	}
	return false
}

// EnableSpeculativeEmptyCompletionArbitration prevents an empty completion
// from settling until the dispatch owner decides which speculative racer won.
func (pr *PendingRequest) EnableSpeculativeEmptyCompletionArbitration() {
	if pr == nil {
		return
	}
	pr.emptyCompletionMu.Lock()
	if !pr.emptyCompletionEnabled {
		pr.emptyCompletionEnabled = true
		pr.emptyCompletionDecision = make(chan struct{})
	}
	pr.emptyCompletionMu.Unlock()
}

// ResolveSpeculativeEmptyCompletion releases a waiting completion as the
// winner (accepted=true) or loser.
func (pr *PendingRequest) ResolveSpeculativeEmptyCompletion(accepted bool) {
	if pr == nil {
		return
	}
	pr.emptyCompletionMu.Lock()
	if pr.emptyCompletionEnabled && !pr.emptyCompletionResolved {
		pr.emptyCompletionResolved = true
		pr.emptyCompletionAccepted = accepted
		close(pr.emptyCompletionDecision)
	}
	pr.emptyCompletionMu.Unlock()
}

// AwaitSpeculativeEmptyCompletionDecision blocks only when speculative
// arbitration was enabled, and reports whether this attempt may settle.
func (pr *PendingRequest) AwaitSpeculativeEmptyCompletionDecision() (accepted, waited bool) {
	if pr == nil {
		return true, false
	}
	pr.emptyCompletionMu.Lock()
	if !pr.emptyCompletionEnabled {
		pr.emptyCompletionMu.Unlock()
		return true, false
	}
	decision := pr.emptyCompletionDecision
	pr.emptyCompletionMu.Unlock()
	<-decision
	pr.emptyCompletionMu.Lock()
	accepted = pr.emptyCompletionAccepted
	pr.emptyCompletionMu.Unlock()
	return accepted, true
}

// RefreshFirstContentBudget updates the wire budget and, when hard TTFT
// admission is enabled, its scheduler ceiling from the same absolute clock.
// It returns false after expiry. Positive sub-millisecond remainders are
// represented as 1ms because zero means "field absent" on the wire.
func (pr *PendingRequest) RefreshFirstContentBudget(now time.Time) bool {
	if pr == nil || pr.FirstContentDeadline.IsZero() {
		return true
	}
	remaining := pr.FirstContentDeadline.Sub(now)
	if remaining <= 0 {
		pr.FirstContentBudgetMS = 0
		return false
	}
	budgetMS := remaining.Milliseconds()
	if budgetMS < 1 {
		budgetMS = 1
	}
	pr.FirstContentBudgetMS = budgetMS
	if pr.MaxTTFTMs > 0 {
		pr.MaxTTFTMs = float64(budgetMS)
	}
	return true
}

// MarkCacheTerminalTelemetryEmitted claims the single terminal cache-selection
// metric for this attempt. Provider terminals and consumer-side synthetic
// disconnect/timeout paths can race; only the first terminal seam emits.
func (pr *PendingRequest) MarkCacheTerminalTelemetryEmitted() bool {
	if pr == nil {
		return false
	}
	pr.routeOutcomeMu.Lock()
	defer pr.routeOutcomeMu.Unlock()
	if pr.cacheTerminalEmitted {
		return false
	}
	pr.cacheTerminalEmitted = true
	return true
}

// MarkFirstChunkArrived stamps Timing.FirstChunkAt to now exactly once, under
// timingMu. The dispatch goroutine calls this when the first inference chunk
// (incl. held boilerplate) arrives, so the provider read-loop goroutine can read
// the value via FirstChunkAtSafe without a data race.
func (pr *PendingRequest) MarkFirstChunkArrived() {
	if pr == nil || pr.Timing == nil {
		return
	}
	pr.timingMu.Lock()
	if pr.Timing.FirstChunkAt.IsZero() {
		pr.Timing.FirstChunkAt = time.Now()
	}
	pr.timingMu.Unlock()
}

// FirstChunkAtSafe returns Timing.FirstChunkAt under timingMu. It is the only
// safe way for a goroutine other than the request owner (e.g. the provider
// read-loop running handleComplete) to read FirstChunkAt.
func (pr *PendingRequest) FirstChunkAtSafe() time.Time {
	if pr == nil || pr.Timing == nil {
		return time.Time{}
	}
	pr.timingMu.Lock()
	defer pr.timingMu.Unlock()
	return pr.Timing.FirstChunkAt
}

// MarkFirstContentArrived stamps Timing.FirstContentAt to now exactly once,
// under timingMu. The dispatch goroutine calls this when the first CONTENT-
// bearing chunk is committed to the client, so the provider read-loop goroutine
// (handleComplete, via the route-telemetry actual_ttft_ms metric) can read the
// value via FirstContentAtSafe without a data race. Mirrors
// MarkFirstChunkArrived.
func (pr *PendingRequest) MarkFirstContentArrived() {
	if pr == nil || pr.Timing == nil {
		return
	}
	pr.timingMu.Lock()
	if pr.Timing.FirstContentAt.IsZero() {
		pr.Timing.FirstContentAt = time.Now()
	}
	pr.timingMu.Unlock()
}

// FirstContentAtSafe returns Timing.FirstContentAt under timingMu. It is the
// only safe way for a goroutine other than the request owner (e.g. the provider
// read-loop running handleComplete) to read FirstContentAt. Mirrors
// FirstChunkAtSafe.
func (pr *PendingRequest) FirstContentAtSafe() time.Time {
	if pr == nil || pr.Timing == nil {
		return time.Time{}
	}
	pr.timingMu.Lock()
	defer pr.timingMu.Unlock()
	return pr.Timing.FirstContentAt
}

// MarkContentCommitted records that THIS attempt committed its first content
// chunk to the client. Set once, under timingMu, by the dispatch/handler
// goroutine (commitFirstContent / the generic first-content stamp). See the
// contentCommitted field for why it is per-attempt rather than on the shared
// Timing.
func (pr *PendingRequest) MarkContentCommitted() {
	if pr == nil {
		return
	}
	pr.timingMu.Lock()
	pr.contentCommitted = true
	pr.timingMu.Unlock()
}

// ContentCommittedSafe reports whether THIS attempt committed its first content,
// read under timingMu. It is the safe way for the provider read-loop goroutine
// (handleComplete) to verify the completing attempt is the committed one before
// stamping shared-Timing fields.
func (pr *PendingRequest) ContentCommittedSafe() bool {
	if pr == nil {
		return false
	}
	pr.timingMu.Lock()
	defer pr.timingMu.Unlock()
	return pr.contentCommitted
}

// MarkRateOutcomeCounted records that the commit-time capacity accept stored
// this request's one capacity-503 rate outcome (see the rateOutcomeCounted
// field). Called in the dispatch/handler goroutine right after
// RecordCapacityAccept returns rateOutcomeRecorded=true.
func (pr *PendingRequest) MarkRateOutcomeCounted() {
	if pr == nil {
		return
	}
	pr.timingMu.Lock()
	pr.rateOutcomeCounted = true
	pr.timingMu.Unlock()
}

// RateOutcomeCountedSafe reports whether the commit-time accept already stored
// this request's rate outcome, read under timingMu. The completion-time accept
// (noteInferenceSuccess) uses it to decide whether the request still owes its
// one denominator entry.
func (pr *PendingRequest) RateOutcomeCountedSafe() bool {
	if pr == nil {
		return false
	}
	pr.timingMu.Lock()
	defer pr.timingMu.Unlock()
	return pr.rateOutcomeCounted
}

type TokenAdmission struct {
	AdmittedOutputTokens int
	EstimatedOutput      bool
	AccountOutputLimited bool
	AccountTier          string
	KeyOutputLimited     bool
	KeyOutputRPS         float64
	KeyOutputBurst       int
}

func (a TokenAdmission) TracksOutput() bool {
	return a.AccountOutputLimited || a.KeyOutputLimited
}

// MarkReservationFinalized returns true only for the first settlement or refund
// of a pre-flight balance reservation. It prevents a terminal provider error
// racing with a late completion from crediting or refunding the same reservation
// twice.
func (pr *PendingRequest) MarkReservationFinalized() bool {
	ok, _ := pr.FinalizeReservation(nil)
	return ok
}

// IsReservationFinalized reports whether the reservation has already been
// settled or refunded (so a late terminal must not re-settle or be counted
// as a fresh client cancellation).
func (pr *PendingRequest) IsReservationFinalized() bool {
	pr.reservationMu.Lock()
	defer pr.reservationMu.Unlock()
	return pr.reservationFinalized
}

// FinalizeReservation runs settle while holding the reservation finalization
// lock and marks the reservation finalized only if settle succeeds. It returns
// false when another terminal path already finalized the reservation.
func (pr *PendingRequest) FinalizeReservation(settle func() error) (bool, error) {
	pr.reservationMu.Lock()
	defer pr.reservationMu.Unlock()
	if pr.reservationFinalized {
		return false, nil
	}
	if settle != nil {
		if err := settle(); err != nil {
			return false, err
		}
	}
	pr.reservationFinalized = true
	return true, nil
}

// MarkRouteOutcomeFinalized returns true only for the first terminal route
// outcome. Non-terminal commit updates leave this gate untouched. It prevents a
// late provider terminal from overwriting a coordinator-side timeout/error that
// already finalized the user-visible request outcome.
func (pr *PendingRequest) MarkRouteOutcomeFinalized() bool {
	if pr == nil {
		return false
	}
	pr.routeOutcomeMu.Lock()
	defer pr.routeOutcomeMu.Unlock()
	if pr.routeOutcomeFinalized {
		return false
	}
	pr.routeOutcomeFinalized = true
	return true
}

type RequestTiming struct {
	ReceivedAt time.Time // handler entry
	ParsedAt   time.Time // after parse + validate
	ReservedAt time.Time // after balance reservation
	// MediaFetchedAt is set when remote media URLs were fetched and inlined
	// post-reservation (api.resolveRemoteMedia); zero when the request needed
	// no fetches. It sits between ReservedAt and RoutedAt in the lifecycle and
	// anchors the route segment so a multi-second media download is reported as
	// media_fetch time, not routing time.
	MediaFetchedAt time.Time
	RoutedAt       time.Time // after provider selection (including queue wait)
	EncryptedAt    time.Time // after E2E encryption
	QueuedAt       time.Time // set when request enters the queue
	DispatchedAt   time.Time // set when request is sent to provider via WebSocket
	FirstChunkAt   time.Time // set when first inference chunk (incl. held boilerplate) arrives from provider
	// FirstContentAt is set when the first CONTENT-bearing chunk is committed to
	// the client — i.e. excluding role-only / lifecycle boilerplate the dispatch
	// loop holds back. The reputation latency sample uses this so a provider that
	// emits a fast preamble then stalls can't earn an undeserved score;
	// FirstChunkAt remains the X-Timing provider-first-byte diagnostic.
	FirstContentAt time.Time
}

// HasCompletionIngress reports whether a clean provider terminal
// (inference_complete) has been ingressed for this attempt. That includes a
// completion parked on the speculative empty-completion decision, which leaves
// the pending record in place: a hedge loser that finished empty on time is
// still "removed != nil" to the dispatcher's cleanup even though nothing is
// running provider-side. Abandon paths consult it before sending a cancel.
func (pr *PendingRequest) HasCompletionIngress() bool {
	if pr == nil {
		return false
	}
	pr.firstContentIngressMu.Lock()
	defer pr.firstContentIngressMu.Unlock()
	return !pr.completionIngressAt.IsZero()
}
