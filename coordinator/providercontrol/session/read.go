package session

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"nhooyr.io/websocket"
)

// Run owns one connection until its read loop exits. Each Session is used once.
func (s *Session) Run(ctx context.Context, conn *websocket.Conn, providerID string, r *http.Request) {
	s.ctx, s.conn, s.providerID, s.request = ctx, conn, providerID, r
	s.challenges = s.deps.Challenges()
	s.peerCloseStatus = websocket.StatusCode(-1)
	var loopCancel context.CancelFunc
	s.loopCtx, loopCancel = context.WithCancel(ctx)
	defer func() {
		loopCancel()
		s.disconnect()
	}()
	for {
		_, data, err := s.conn.Read(s.loopCtx)
		if err != nil {
			s.readFailed(err)
			return
		}
		var msg protocol.ProviderMessage
		// Decoder errors can contain provider-controlled data; log no payload detail.
		if err := protocol.DecodeProviderMessage(data, &msg); err != nil {
			if errors.Is(err, protocol.ErrAppAttestShadowFrameTooLarge) {
				if s.appAttestShadow != nil {
					s.appAttestShadow.Drop()
				}
				s.deps.Telemetry.Incr("app_attest.shadow.frames_rejected", []string{"reason:oversized"})
			}
			s.deps.Logger().Warn("invalid provider message", "provider_id", s.providerID)
			continue
		}
		switch msg.Type {
		case protocol.TypeRegister:
			if s.provider != nil {
				s.deps.Logger().Warn("rejecting second register on provider connection",
					"provider_id", s.providerID)
				_ = s.conn.Close(websocket.StatusPolicyViolation, "provider already registered")
				return
			}
			if !s.register(msg.Payload.(*protocol.RegisterMessage)) {
				return
			}
		case protocol.TypeAppAttestShadow:
			if s.appAttestShadow != nil {
				s.appAttestShadow.Offer(msg.Payload.(*protocol.AppAttestShadowMessage).Payload)
			}
		case protocol.TypeHeartbeat:
			if s.provider == nil {
				// Heartbeats are meaningful only after this connection has
				// registered. Reject the protocol violation before touching any
				// provider snapshot or other per-registration state.
				s.deps.Logger().Warn("heartbeat from unregistered provider", "provider_id", s.providerID)
				_ = s.conn.Close(websocket.StatusPolicyViolation, "register before heartbeat")
				return
			}
			s.heartbeat(msg.Payload.(*protocol.HeartbeatMessage))
		case protocol.TypeCapacityQuote:
			if s.provider == nil {
				// A quote answers a coordinator-sent probe, and probes are only
				// sent to registered providers — a quote on an unregistered
				// connection is a protocol violation, same posture as heartbeat.
				s.deps.Logger().Warn("capacity quote from unregistered provider",
					"provider_id", s.providerID)
				continue
			}
			quoteMsg := msg.Payload.(*protocol.CapacityQuoteMessage)
			// Correlation (quote_id → outstanding probe, provider binding,
			// window expiry) and plan confirm/demote all live registry-side
			// with the probe state; the read loop only delivers. Synchronous
			// like heartbeat ingest — no DB or lock-heavy work on this path.
			s.deps.Registry().HandleCapacityQuote(s.providerID, quoteMsg)
		case protocol.TypeInferenceAccepted:
			acceptMsg := msg.Payload.(*protocol.InferenceAcceptedMessage)
			s.deps.Frames.Accepted(s.provider, acceptMsg)
		case protocol.TypeInferenceResponseChunk:
			chunkMsg := msg.Payload.(*protocol.InferenceResponseChunkMessage)
			s.deps.Frames.Chunk(s.providerID, s.provider, chunkMsg)
		case protocol.TypeInferenceComplete:
			if s.provider == nil {
				s.deps.Logger().Warn("complete from unregistered provider", "provider_id", s.providerID)
				continue
			}
			completeMsg := msg.Payload.(*protocol.InferenceCompleteMessage)
			_, receivedAt := s.provider.MarkPendingCompletionIngressNow(completeMsg.RequestID)
			if receivedAt.IsZero() {
				receivedAt = time.Now()
			}
			// Run completion handling (billing settlement) off the read loop.
			// Billing does synchronous DB calls (GetModelPrice, Credit, Charge)
			// that can block for seconds under DB pressure. If the read loop is
			// blocked, attestation challenge responses can't be read from the
			// WebSocket, causing challenge timeouts and provider derouting.
			saferun.Go(s.deps.Logger(), "handleComplete", func() {
				s.deps.Frames.Complete(s.providerID, s.provider, completeMsg, receivedAt)
			})
		case protocol.TypeInferenceError:
			errMsg := msg.Payload.(*protocol.InferenceErrorMessage)
			s.deps.Frames.Error(s.providerID, s.provider, errMsg)
		case protocol.TypePrefixCacheLookup:
			s.cacheLookup(msg.Payload.(*protocol.PrefixCacheLookupMessage))
		case protocol.TypePrefixCacheReady:
			s.cacheReady(msg.Payload.(*protocol.PrefixCacheReadyMessage))
		case protocol.TypePrefixCacheLookupV2:
			s.cacheLookupV2(msg.Payload.(*protocol.PrefixCacheLookupV2Message))
		case protocol.TypePrefixCacheReadyV2:
			s.cacheReadyV2(msg.Payload.(*protocol.PrefixCacheReadyV2Message))
		case protocol.TypeAttestationResponse:
			respMsg := msg.Payload.(*protocol.AttestationResponseMessage)
			s.challenges.Deliver(s.providerID, s.provider, respMsg)
		case protocol.TypeCodeAttestationResponse:
			respMsg := msg.Payload.(*protocol.CodeAttestationResponseMessage)
			// Verify in the delivery path: a reply attests this live
			// connection even if the push round-trip outlived the pushing
			// goroutine or the original connection (reconnect).
			s.deps.CodeIdentity().HandleResponse(s.providerID, s.provider, respMsg)
		case protocol.TypeLoadModelStatus:
			s.loadModelStatus(msg.Payload.(*protocol.LoadModelStatusMessage))
		case protocol.TypeModelsUpdate:
			updateMsg := msg.Payload.(*protocol.ModelsUpdateMessage)
			s.modelsUpdate(s.providerID, s.provider, updateMsg)
		case protocol.TypePrefetchModelStatus:
			// This frame is advisory progress for a provider-autonomous download;
			// it has no coordinator-issued pending-command identity and no state
			// effect. Ignore it entirely. A later catalog-validated models_update
			// remains the authoritative servability signal.
			continue
		default:
			// Provider message types are untrusted strings until explicitly handled.
			s.deps.Logger().Warn("unhandled provider message type", "provider_id", s.providerID)
		}
	}
}
