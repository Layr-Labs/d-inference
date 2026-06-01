package registry

import (
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// PendingRequest is a channel-based handle for an in-flight inference request.
type PendingRequest struct {
	RequestID   string
	ProviderID  string
	Model       string
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
	// AllowedProviderSerials optionally restricts routing to providers with
	// one of these attested hardware serials. Empty means the request may
	// route to any eligible provider.
	AllowedProviderSerials []string
	// EstimatedPromptTokens is a coordinator-side heuristic used only for
	// routing and queue admission. It does not need tokenizer-perfect accuracy.
	EstimatedPromptTokens int
	// RequestedMaxTokens is the consumer's requested output budget (or a
	// sensible default when omitted). It is used for backlog estimation.
	RequestedMaxTokens int
	AcceptedCh         chan struct{}           // signalled when provider accepts request
	ChunkCh            chan string             // SSE data chunks
	CompleteCh         chan protocol.UsageInfo // closed after usage sent
	ErrorCh            chan protocol.InferenceErrorMessage
	SessionPrivKey     *[32]byte // E2E session private key for decrypting responses
	SESignature        string    // SE signature over response hash
	ResponseHash       string    // SHA-256 of response data

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
	reservationMu        sync.Mutex
	reservationFinalized bool

	// Timing fields for latency decomposition.
	Timing *RequestTiming
}

// MarkReservationFinalized returns true only for the first settlement or refund
// of a pre-flight balance reservation. It prevents a terminal provider error
// racing with a late completion from crediting or refunding the same reservation
// twice.
func (pr *PendingRequest) MarkReservationFinalized() bool {
	ok, _ := pr.FinalizeReservation(nil)
	return ok
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

type RequestTiming struct {
	ReceivedAt   time.Time // handler entry
	ParsedAt     time.Time // after parse + validate
	ReservedAt   time.Time // after balance reservation
	RoutedAt     time.Time // after provider selection (including queue wait)
	EncryptedAt  time.Time // after E2E encryption
	QueuedAt     time.Time // set when request enters the queue
	DispatchedAt time.Time // set when request is sent to provider via WebSocket
	FirstChunkAt time.Time // set when first inference chunk arrives from provider
}
