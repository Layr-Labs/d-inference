package providerframe

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Service) Chunk(providerID string, provider *registry.Provider, msg *protocol.InferenceResponseChunkMessage) {
	if provider == nil {
		s.deps.Logger().Warn("chunk from unregistered provider", "provider_id", providerID)
		return
	}
	pr, receivedAt := provider.BeginPendingChunkIngress(msg.RequestID)
	if pr == nil {
		s.deps.Metrics.Incr("inference.unknown_request_frames", []string{"kind:chunk"})
		s.unknownRequestFrames.Add(1)
		// The provider is generating into a stream the coordinator abandoned
		// (cancelled, consumer gone, already settled) — or sent an id it never
		// owned. noteStrayChunk re-sends the cancel on the escalating zombie
		// schedule and rate-limits the log line per provider; request_id stays
		// out of the log until it matches coordinator state.
		s.deps.Attempts().StrayChunk(provider, providerID, msg.RequestID, receivedAt)
		return
	}
	ingressClassified := false
	defer func() {
		if !ingressClassified {
			pr.FinishProviderChunkIngress(receivedAt, false)
		}
	}()
	decryptStart := time.Now()
	chunkData, err := s.decryptTextResponseChunk(provider, pr, msg)
	if err != nil {
		s.deps.Logger().Warn("rejecting insecure response chunk",
			"provider_id", providerID,
			"request_id", msg.RequestID,
			"error", err,
		)
		s.deps.Registry().MarkUntrusted(providerID)
		// The provider is still generating: the synthesized terminal below
		// settles the request on our side, so the committed writer's exit
		// will not send a cancel for it (a settled terminal means "nothing
		// left to stop"). Stop the real work here, like the deadline and
		// overflow branches do.
		s.deps.Attempts().SendCancel(provider, msg.RequestID)
		s.Error(providerID, provider, &protocol.InferenceErrorMessage{
			Type:        protocol.TypeInferenceError,
			RequestID:   msg.RequestID,
			Error:       "encrypted inference transport failed",
			StatusCode:  http.StatusBadGateway,
			FailureCode: protocol.FailureCodeEncryptionFailure,
		})
		return
	}
	if ap := pr.Profile; ap != nil {
		ap.ChunksIn.Add(1)
		ap.DecryptUSTotal.Add(time.Since(decryptStart).Microseconds())
		ap.MarkAt(registry.StampFirstChunkIngress, receivedAt)
	}
	if pr.Profile != nil && !pr.Profile.GeneratedContentObserved.Load() && (response.GeneratedContentSSE([]byte(chunkData)) || response.GeneratedContentJSON([]byte(chunkData))) {
		pr.Profile.GeneratedContentObserved.Store(true)
	}
	contentBearing := !response.IsBoilerplateChunk(chunkData)
	firstContent := pr.FinishProviderChunkIngress(receivedAt, contentBearing)
	ingressClassified = true
	if firstContent {
		pr.Profile.MarkAt(registry.StampFirstContentIngress, receivedAt)
	}
	deadlineExpiredWithoutContent := !pr.FirstContentDeadline.IsZero() &&
		((firstContent && receivedAt.After(pr.FirstContentDeadline)) ||
			(!contentBearing &&
				!pr.HasFirstContentIngress() &&
				time.Now().After(pr.FirstContentDeadline)))
	if deadlineExpiredWithoutContent {
		// The request-absolute SLA is defined at coordinator ingress. Reject
		// either late first content or an on-time chunk that finished
		// classification as boilerplate only after the deadline.
		s.deps.Metrics.Incr("inference.first_content_after_deadline", []string{})
		s.deps.Attempts().SendAbandonCancel(provider, pr.RequestID, pr.Model, attempt.CancelCauseLateContent)
		s.Error(providerID, provider, &protocol.InferenceErrorMessage{
			Type:        protocol.TypeInferenceError,
			RequestID:   pr.RequestID,
			Error:       "first content was unavailable at the request deadline",
			StatusCode:  http.StatusServiceUnavailable,
			ErrorReason: attempt.ErrorReasonDeadlineUnreachable,
			FailureCode: protocol.FailureCodeCapacity,
		})
		return
	}
	chunk := registry.ProviderChunk{Data: chunkData, ReceivedAt: receivedAt}
	// Fast path: non-blocking send — this is the provider's single read
	// goroutine, so it must not stall behind one slow consumer. A full channel
	// means the consumer is ≥256 chunks behind; silently dropping the chunk
	// (the old behavior) would deliver a corrupted stream with missing tokens
	// that is still billed. Instead, give a healthy-but-bursty consumer a
	// bounded grace window to free one slot (sendChunkWithGrace), and only
	// then fail the request: cancel the provider's generation and surface a
	// terminal error to the consumer goroutine.
	select {
	case pr.ChunkCh <- chunk:
	default:
		if sendChunkWithGrace(pr, chunk) {
			return
		}
		s.deps.Logger().Error("chunk buffer overflow — failing request instead of corrupting stream",
			"provider_id", providerID,
			"request_id", msg.RequestID,
		)
		s.deps.Metrics.Incr("inference.chunk_overflow_abort", []string{})
		s.deps.Attempts().SendAbandonCancel(provider, pr.RequestID, pr.Model, attempt.CancelCauseOverflow)
		// 499 + "request cancelled" classifies as a consumer-side terminal in
		// Error: no provider reputation hit for our backpressure.
		s.Error(providerID, provider, &protocol.InferenceErrorMessage{
			Type:        protocol.TypeInferenceError,
			RequestID:   msg.RequestID,
			Error:       "request cancelled",
			StatusCode:  499,
			FailureCode: protocol.FailureCodeCancelled,
		})
	}
}
