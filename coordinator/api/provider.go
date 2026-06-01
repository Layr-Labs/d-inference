package api

// Provider WebSocket management for the Darkbloom coordinator.
//
// This file handles the provider side of the coordinator: WebSocket connections,
// provider registration, attestation verification, challenge-response loops,
// and inference request/response relay.
//
// Provider lifecycle:
//   1. Provider connects via WebSocket to /ws/provider
//   2. Provider sends a Register message with hardware info, models, and attestation
//   3. Coordinator verifies attestation (Secure Enclave P-256 signature)
//   4. Coordinator starts periodic challenge-response loop to verify liveness
//   5. Coordinator routes inference requests to the provider via WebSocket
//   6. Provider streams response chunks back through the WebSocket
//   7. Coordinator relays chunks to the waiting consumer HTTP handler
//
// Attestation trust levels:
//   - none: No attestation provided (Open Mode, still accepted)
//   - self_signed: Attestation signed by provider's own Secure Enclave key
//   - hardware: MDA certificate chain verified against Apple Root CA (future)

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

const (
	// DefaultChallengeInterval is how often the coordinator challenges providers.
	DefaultChallengeInterval = 5 * time.Minute

	// ChallengeResponseTimeout is how long to wait for a challenge response.
	ChallengeResponseTimeout = 30 * time.Second
)

// handleProviderWS upgrades the connection to WebSocket and manages the
// provider's lifecycle: registration, heartbeats, and inference responses.
func (s *Server) handleProviderWS(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// Allow any origin for provider connections.
		InsecureSkipVerify: true,
	})
	if err != nil {
		s.logger.Error("websocket accept failed", "error", err)
		return
	}

	// Raise the read limit to 10 MB. The default 32 KB is too small for
	// large inference responses.
	conn.SetReadLimit(10 * 1024 * 1024)

	providerID := uuid.New().String()
	s.logger.Info("provider websocket connected", "provider_id", providerID, "remote", r.RemoteAddr)

	// Check for ACME client certificate (TLS client auth via nginx).
	// If present and valid, the provider's SE key is Apple-attested.
	acmeResult := s.extractAndVerifyClientCert(r)

	// Run the read loop; on return the provider is disconnected.
	s.providerReadLoop(r.Context(), conn, providerID, acmeResult, r)
}

// providerReadLoop reads messages from the provider WebSocket and dispatches
// them. It runs until the connection closes or the context is cancelled.
func (s *Server) providerReadLoop(ctx context.Context, conn *websocket.Conn, providerID string, acmeResult *ACMEVerificationResult, r *http.Request) {
	var provider *registry.Provider
	tracker := newChallengeTracker()

	// Cancel context for cleanup of the challenge loop goroutine.
	loopCtx, loopCancel := context.WithCancel(ctx)
	defer func() {
		loopCancel()
		s.registry.Disconnect(providerID)
		conn.Close(websocket.StatusNormalClosure, "goodbye")
	}()

	for {
		_, data, err := conn.Read(loopCtx)
		if err != nil {
			if websocket.CloseStatus(err) != -1 {
				s.logger.Info("provider websocket closed", "provider_id", providerID)
			} else {
				s.logger.Error("provider websocket read error", "provider_id", providerID, "error", err)
				s.emit(context.Background(), protocol.SeverityWarn, protocol.KindConnectivity,
					"provider websocket read error",
					map[string]any{
						"provider_id": providerID,
						"ws_state":    "read_error",
						"last_error":  err.Error(),
					})
				if s.metrics != nil {
					s.metrics.IncCounter("ws_disconnects_total",
						MetricLabel{"reason", "read_error"},
					)
				}
				s.ddIncr("ws.disconnects", []string{"reason:read_error"})
			}
			return
		}

		var msg protocol.ProviderMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			s.logger.Warn("invalid provider message", "provider_id", providerID, "error", err)
			continue
		}

		switch msg.Type {
		case protocol.TypeRegister:
			regMsg := msg.Payload.(*protocol.RegisterMessage)
			provider = s.registry.Register(providerID, conn, regMsg)
			s.attachProviderLocation(providerID, provider, r)
			s.verifyProviderAttestation(providerID, provider, regMsg)

			// Record registration outcome metrics + telemetry.
			if s.metrics != nil {
				s.metrics.IncCounter("provider_registrations_total",
					MetricLabel{"trust_level", string(provider.TrustLevel)},
				)
			}
			s.ddIncr("providers.registrations", []string{"trust_level:" + string(provider.TrustLevel)})
			s.emit(context.Background(), protocol.SeverityInfo, protocol.KindLog,
				"provider registered",
				map[string]any{
					"provider_id":   providerID,
					"trust_level":   string(provider.TrustLevel),
					"hardware_chip": regMsg.Hardware.ChipName,
					"memory_gb":     regMsg.Hardware.MemoryGB,
				})

			// Resolve auth token → account linkage.
			if regMsg.AuthToken != "" {
				pt, err := s.store.GetProviderToken(regMsg.AuthToken)
				if err != nil {
					s.logger.Warn("provider auth token invalid",
						"provider_id", providerID,
						"error", err,
					)
				} else {
					provider.Mu().Lock()
					provider.AccountID = pt.AccountID
					provider.Mu().Unlock()
					s.logger.Info("provider linked to account",
						"provider_id", providerID,
						"account_id", pt.AccountID,
						"token_label", pt.Label,
					)
				}
			}

			// Store provider version.
			if regMsg.Version != "" {
				provider.Mu().Lock()
				provider.Version = regMsg.Version
				provider.Mu().Unlock()
			}

			// Verify runtime integrity against the known-good manifest. Swift
			// providers omit Python/vllm hashes, but they still report external
			// runtime assets such as mlx.metallib under template_hashes.
			if s.knownRuntimeManifest != nil {
				runtimeOK, mismatches := s.verifyRuntimeHashesForBackend(
					regMsg.Backend, regMsg.PythonHash, regMsg.RuntimeHash, regMsg.TemplateHashes)
				provider.Mu().Lock()
				provider.RuntimeVerified = runtimeOK
				provider.RuntimeManifestChecked = runtimeOK
				provider.PythonHash = regMsg.PythonHash
				provider.RuntimeHash = regMsg.RuntimeHash
				provider.TemplateHashes = registry.CloneStringMap(regMsg.TemplateHashes)
				provider.Mu().Unlock()

				if !runtimeOK {
					// Send runtime status feedback only on mismatch so the
					// provider can self-heal. Skip the message when everything
					// matches — it would only add noise on the WebSocket.
					statusMsg := protocol.RuntimeStatusMessage{
						Type:       protocol.TypeRuntimeStatus,
						Verified:   false,
						Mismatches: mismatches,
					}
					statusData, err := json.Marshal(statusMsg)
					if err == nil {
						writeCtx, writeCancel := context.WithTimeout(loopCtx, 5*time.Second)
						_ = conn.Write(writeCtx, websocket.MessageText, statusData)
						writeCancel()
					}
					mismatchDetails := make([]string, 0, len(mismatches))
					for _, m := range mismatches {
						mismatchDetails = append(mismatchDetails, m.Component+"="+m.Got)
					}
					s.logger.Warn("provider runtime integrity mismatch — excluded from routing",
						"provider_id", providerID,
						"mismatches", len(mismatches),
						"details", mismatchDetails,
						"backend", regMsg.Backend,
					)
				} else {
					s.logger.Info("provider runtime integrity verified",
						"provider_id", providerID,
						"python_hash", regMsg.PythonHash,
						"runtime_hash", regMsg.RuntimeHash,
					)
				}
			} else {
				// No manifest configured — fail-closed for routing.
				provider.Mu().Lock()
				provider.RuntimeVerified = true
				provider.RuntimeManifestChecked = false
				provider.Mu().Unlock()
			}

			// Version cutoff check — runs AFTER runtime check so it takes precedence.
			// If version is below minimum, override RuntimeVerified to false.
			if s.minProviderVersion != "" && regMsg.Version != "" && semverLess(regMsg.Version, s.minProviderVersion) {
				s.logger.Warn("provider version below minimum — excluded from routing",
					"provider_id", providerID,
					"version", regMsg.Version,
					"min_version", s.minProviderVersion,
				)
				s.ddIncr("provider_version_below_minimum", []string{"gate:registration", "version:" + regMsg.Version})
				provider.Mu().Lock()
				provider.RuntimeVerified = false
				provider.RuntimeManifestChecked = false
				provider.Mu().Unlock()
			}

			s.applyACMETrust(providerID, provider, acmeResult)

			// Start challenge loop after registration
			saferun.Go(s.logger, "challengeLoop", func() {
				s.challengeLoop(loopCtx, conn, providerID, provider, tracker)
			})

		case protocol.TypeHeartbeat:
			hbMsg := msg.Payload.(*protocol.HeartbeatMessage)
			s.registry.Heartbeat(providerID, hbMsg)

		case protocol.TypeInferenceAccepted:
			acceptMsg := msg.Payload.(*protocol.InferenceAcceptedMessage)
			s.handleInferenceAccepted(provider, acceptMsg)

		case protocol.TypeInferenceResponseChunk:
			chunkMsg := msg.Payload.(*protocol.InferenceResponseChunkMessage)
			s.handleChunk(providerID, provider, chunkMsg)

		case protocol.TypeInferenceComplete:
			completeMsg := msg.Payload.(*protocol.InferenceCompleteMessage)
			// Run completion handling (billing settlement) off the read loop.
			// Billing does synchronous DB calls (GetModelPrice, Credit, Charge)
			// that can block for seconds under DB pressure. If the read loop is
			// blocked, attestation challenge responses can't be read from the
			// WebSocket, causing challenge timeouts and provider derouting.
			saferun.Go(s.logger, "handleComplete", func() {
				s.handleComplete(providerID, provider, completeMsg)
			})

		case protocol.TypeInferenceError:
			errMsg := msg.Payload.(*protocol.InferenceErrorMessage)
			s.handleInferenceError(providerID, provider, errMsg)

		case protocol.TypeAttestationResponse:
			respMsg := msg.Payload.(*protocol.AttestationResponseMessage)
			s.handleAttestationResponse(providerID, provider, respMsg, tracker)

		case protocol.TypeLoadModelStatus:
			statusMsg := msg.Payload.(*protocol.LoadModelStatusMessage)
			s.logger.Info("provider load_model_status",
				"provider_id", providerID,
				"model_id", statusMsg.ModelID,
				"status", statusMsg.Status,
				"error", statusMsg.Error,
			)
			switch statusMsg.Status {
			case protocol.LoadModelStatusSucceeded:
				// Mark the model warm on this provider BEFORE draining so
				// the scheduler sees it as a candidate. Without this, the
				// provider still looks cold until the next heartbeat.
				s.registry.MarkModelWarm(providerID, statusMsg.ModelID)
				s.registry.ClearPendingModelLoad(providerID, statusMsg.ModelID)
				s.registry.DrainQueuedRequestsForModel(statusMsg.ModelID)
			case protocol.LoadModelStatusFailed:
				// Keep the pending entry (TTL cooldown suppresses retry storms).
				// If no other provider can serve this model, reject queued
				// requests immediately rather than making them wait 120s.
				s.registry.RejectUnservableQueuedRequests(statusMsg.ModelID)
			}
			// "started" status: no action — load is in progress.

		default:
			s.logger.Warn("unhandled provider message type", "provider_id", providerID, "type", msg.Type)
		}
	}
}
