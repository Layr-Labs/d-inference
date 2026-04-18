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
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/eigeninference/coordinator/internal/attestation"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

const (
	// DefaultChallengeInterval is how often the coordinator challenges providers.
	DefaultChallengeInterval = 5 * time.Minute

	// ChallengeResponseTimeout is how long to wait for a challenge response.
	ChallengeResponseTimeout = 30 * time.Second

	// MaxFailedChallenges is the number of consecutive failures before marking untrusted.
	MaxFailedChallenges = 3
)

// pendingChallenge tracks an outstanding challenge sent to a provider.
type pendingChallenge struct {
	nonce      string
	timestamp  string
	sentAt     time.Time
	responseCh chan *protocol.AttestationResponseMessage
}

// challengeTracker manages pending challenges for provider connections.
type challengeTracker struct {
	mu      sync.Mutex
	pending map[string]*pendingChallenge // keyed by nonce
}

func newChallengeTracker() *challengeTracker {
	return &challengeTracker{
		pending: make(map[string]*pendingChallenge),
	}
}

func (ct *challengeTracker) add(nonce string, pc *pendingChallenge) {
	ct.mu.Lock()
	defer ct.mu.Unlock()
	ct.pending[nonce] = pc
}

func (ct *challengeTracker) remove(nonce string) *pendingChallenge {
	ct.mu.Lock()
	defer ct.mu.Unlock()
	pc := ct.pending[nonce]
	delete(ct.pending, nonce)
	return pc
}

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
	// image generation responses which carry base64-encoded PNGs (~1-3 MB).
	conn.SetReadLimit(10 * 1024 * 1024)

	providerID := uuid.New().String()
	s.logger.Info("provider websocket connected", "provider_id", providerID, "remote", r.RemoteAddr)

	// Check for ACME client certificate (TLS client auth via nginx).
	// If present and valid, the provider's SE key is Apple-attested.
	acmeResult := s.extractAndVerifyClientCert(r)

	// Run the read loop; on return the provider is disconnected.
	s.providerReadLoop(r.Context(), conn, providerID, acmeResult)
}

// providerReadLoop reads messages from the provider WebSocket and dispatches
// them. It runs until the connection closes or the context is cancelled.
//
//nolint:gocognit
func (s *Server) providerReadLoop(ctx context.Context, conn *websocket.Conn, providerID string, acmeResult *ACMEVerificationResult) {
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
			regMsg, _ := msg.Payload.(*protocol.RegisterMessage)
			provider = s.registry.Register(providerID, conn, regMsg)
			s.verifyProviderAttestation(providerID, provider, regMsg)

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

			// Verify runtime integrity against the known-good manifest.
			if s.knownRuntimeManifest != nil {
				runtimeOK, mismatches := s.verifyRuntimeHashes(
					regMsg.PythonHash, regMsg.RuntimeHash, regMsg.TemplateHashes,
					regMsg.GrpcBinaryHash, regMsg.ImageBridgeHash)
				provider.Mu().Lock()
				provider.RuntimeVerified = runtimeOK
				provider.PythonHash = regMsg.PythonHash
				provider.RuntimeHash = regMsg.RuntimeHash
				provider.Mu().Unlock()

				// Send runtime status feedback to provider so it can self-heal.
				statusMsg := protocol.RuntimeStatusMessage{
					Type:       protocol.TypeRuntimeStatus,
					Verified:   runtimeOK,
					Mismatches: mismatches,
				}
				statusData, err := json.Marshal(statusMsg)
				if err == nil {
					writeCtx, writeCancel := context.WithTimeout(loopCtx, 5*time.Second)
					_ = conn.Write(writeCtx, websocket.MessageText, statusData)
					writeCancel()
				}

				if runtimeOK {
					s.logger.Info("provider runtime integrity verified",
						"provider_id", providerID,
						"python_hash", regMsg.PythonHash,
						"runtime_hash", regMsg.RuntimeHash,
					)
				} else {
					s.logger.Warn("provider runtime integrity mismatch — excluded from routing",
						"provider_id", providerID,
						"mismatches", len(mismatches),
					)
				}
			} else {
				// No manifest configured — all providers pass by default.
				provider.Mu().Lock()
				provider.RuntimeVerified = true
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
				provider.Mu().Lock()
				provider.RuntimeVerified = false
				provider.Mu().Unlock()
			}

			// If ACME client cert was verified, upgrade to hardware trust.
			// ACME device-attest-01 proves the provider's SE key is Apple-attested.
			if acmeResult != nil && acmeResult.Valid {
				provider.Mu().Lock()
				provider.ACMEVerified = true
				provider.Mu().Unlock()
				provider.SetAttested(true, registry.TrustHardware)
				s.logger.Info("ACME client cert verified — hardware trust via Apple SE attestation",
					"provider_id", providerID,
					"acme_serial", acmeResult.SerialNumber,
					"acme_issuer", acmeResult.Issuer,
					"acme_key_alg", acmeResult.PublicKeyAlg,
				)
			}

			// Start challenge loop after registration
			go s.challengeLoop(loopCtx, conn, providerID, provider, tracker)

		case protocol.TypeHeartbeat:
			hbMsg, _ := msg.Payload.(*protocol.HeartbeatMessage)
			s.registry.Heartbeat(providerID, hbMsg)

		case protocol.TypeInferenceAccepted:
			acceptMsg, _ := msg.Payload.(*protocol.InferenceAcceptedMessage)
			s.handleInferenceAccepted(providerID, provider, acceptMsg)

		case protocol.TypeInferenceResponseChunk:
			chunkMsg, _ := msg.Payload.(*protocol.InferenceResponseChunkMessage)
			s.handleChunk(providerID, provider, chunkMsg)

		case protocol.TypeInferenceComplete:
			completeMsg, _ := msg.Payload.(*protocol.InferenceCompleteMessage)
			s.handleComplete(providerID, provider, completeMsg)

		case protocol.TypeInferenceError:
			errMsg, _ := msg.Payload.(*protocol.InferenceErrorMessage)
			s.handleInferenceError(providerID, provider, errMsg)

		case protocol.TypeTranscriptionComplete:
			tcMsg, _ := msg.Payload.(*protocol.TranscriptionCompleteMessage)
			s.handleTranscriptionComplete(providerID, provider, tcMsg)

		case protocol.TypeImageGenerationComplete:
			igMsg, _ := msg.Payload.(*protocol.ImageGenerationCompleteMessage)
			s.handleImageGenerationComplete(providerID, provider, igMsg)

		case protocol.TypeAttestationResponse:
			respMsg, _ := msg.Payload.(*protocol.AttestationResponseMessage)
			s.handleAttestationResponse(providerID, provider, respMsg, tracker)

		default:
			s.logger.Warn("unhandled provider message type", "provider_id", providerID, "type", msg.Type)
		}
	}
}

// challengeLoop periodically sends attestation challenges to a provider.
func (s *Server) challengeLoop(ctx context.Context, conn *websocket.Conn, providerID string, provider *registry.Provider, tracker *challengeTracker) {
	interval := s.challengeInterval
	if interval == 0 {
		interval = DefaultChallengeInterval
	}

	// Send initial challenge immediately so the provider is routable
	// without waiting for the first ticker interval.
	s.sendChallenge(ctx, conn, providerID, provider, tracker)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			provider.Mu().Lock()
			untrusted := provider.Status == registry.StatusUntrusted
			provider.Mu().Unlock()
			if untrusted {
				return
			}
			s.sendChallenge(ctx, conn, providerID, provider, tracker)
		}
	}
}

// generateNonce creates a random 32-byte nonce and returns it as base64.
func generateNonce() (string, error) {
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(nonce), nil
}

// sendChallenge sends an attestation challenge to a provider and waits for the response.
func (s *Server) sendChallenge(ctx context.Context, conn *websocket.Conn, providerID string, provider *registry.Provider, tracker *challengeTracker) {
	nonce, err := generateNonce()
	if err != nil {
		s.logger.Error("failed to generate challenge nonce", "provider_id", providerID, "error", err)
		return
	}

	timestamp := time.Now().UTC().Format(time.RFC3339)

	challenge := protocol.AttestationChallengeMessage{
		Type:      protocol.TypeAttestationChallenge,
		Nonce:     nonce,
		Timestamp: timestamp,
	}

	data, err := json.Marshal(challenge)
	if err != nil {
		s.logger.Error("failed to marshal challenge", "provider_id", providerID, "error", err)
		return
	}

	pc := &pendingChallenge{
		nonce:      nonce,
		timestamp:  timestamp,
		sentAt:     time.Now(),
		responseCh: make(chan *protocol.AttestationResponseMessage, 1),
	}
	tracker.add(nonce, pc)

	writeCtx, writeCancel := context.WithTimeout(ctx, 5*time.Second)
	defer writeCancel()
	if err := conn.Write(writeCtx, websocket.MessageText, data); err != nil {
		s.logger.Error("failed to send challenge", "provider_id", providerID, "error", err)
		tracker.remove(nonce)
		return
	}

	s.logger.Debug("sent attestation challenge", "provider_id", providerID, "nonce", nonce[:8]+"...")

	// Wait for response with timeout.
	timeout := ChallengeResponseTimeout
	select {
	case <-ctx.Done():
		tracker.remove(nonce)
		return
	case resp := <-pc.responseCh:
		tracker.remove(nonce)
		if resp == nil {
			// Channel closed without response
			s.handleChallengeFailure(providerID, "no response")
			return
		}
		s.verifyChallengeResponse(providerID, provider, pc, resp)
	case <-time.After(timeout):
		tracker.remove(nonce)
		s.handleChallengeFailure(providerID, "timeout")
	}
}

// handleAttestationResponse processes an attestation response from a provider.
func (s *Server) handleAttestationResponse(providerID string, provider *registry.Provider, msg *protocol.AttestationResponseMessage, tracker *challengeTracker) {
	if provider == nil {
		s.logger.Warn("attestation response from unregistered provider", "provider_id", providerID)
		return
	}

	pc := tracker.remove(msg.Nonce)
	if pc == nil {
		s.logger.Warn("attestation response for unknown challenge", "provider_id", providerID, "nonce", msg.Nonce[:8]+"...")
		return
	}

	// Send response to the waiting goroutine.
	select {
	case pc.responseCh <- msg:
	default:
	}
}

// verifyChallengeResponse verifies a challenge response from a provider.
// In addition to verifying the nonce and signature, it checks the fresh
// SIP status reported by the provider. If SIP has been disabled since
// registration, the provider is marked untrusted immediately.
//
//nolint:gocognit
func (s *Server) verifyChallengeResponse(providerID string, provider *registry.Provider, pc *pendingChallenge, resp *protocol.AttestationResponseMessage) {
	// Verify the nonce matches.
	if resp.Nonce != pc.nonce {
		s.handleChallengeFailure(providerID, "nonce mismatch")
		return
	}

	// Verify the public key matches the registered key.
	if provider.PublicKey != "" && resp.PublicKey != provider.PublicKey {
		s.handleChallengeFailure(providerID, "public key mismatch")
		return
	}

	// Verify the signature cryptographically using the provider's Secure
	// Enclave P-256 public key. The provider signs SHA-256(nonce + timestamp)
	// with its SE key via eigeninference-enclave CLI.
	if resp.Signature == "" {
		s.handleChallengeFailure(providerID, "empty signature")
		return
	}

	// If the provider has an attested SE public key, verify the signature.
	// Providers without attestation (TrustNone / Open Mode) skip crypto
	// verification — their trust is already "none".
	if provider.AttestationResult != nil && provider.AttestationResult.PublicKey != "" {
		challengeData := pc.nonce + pc.timestamp
		if err := attestation.VerifyChallengeSignature(
			provider.AttestationResult.PublicKey,
			resp.Signature,
			challengeData,
		); err != nil {
			s.logger.Error("challenge signature verification failed",
				"provider_id", providerID,
				"error", err,
			)
			s.handleChallengeFailure(providerID, "signature verification failed: "+err.Error())
			return
		}
	}

	// Verify fresh SIP status. If the provider reports SIP disabled,
	// they've rebooted since registration and are no longer trustworthy.
	// SIP cannot be disabled at runtime — a reboot into Recovery Mode is
	// required. So SIP=false means the provider deliberately weakened
	// their security posture.
	if resp.SIPEnabled != nil && !*resp.SIPEnabled {
		s.logger.Error("provider SIP disabled in challenge response — marking untrusted",
			"provider_id", providerID,
		)
		s.registry.MarkUntrusted(providerID)
		s.handleChallengeFailure(providerID, "SIP disabled")
		return
	}

	// Verify fresh Secure Boot status.
	if resp.SecureBootEnabled != nil && !*resp.SecureBootEnabled {
		s.logger.Error("provider Secure Boot disabled in challenge response — marking untrusted",
			"provider_id", providerID,
		)
		s.registry.MarkUntrusted(providerID)
		s.handleChallengeFailure(providerID, "Secure Boot disabled")
		return
	}

	// Verify fresh RDMA status. RDMA over Thunderbolt 5 allows another Mac
	// to directly read inference process memory, bypassing all software
	// protections (PT_DENY_ATTACH, Hardened Runtime, SIP). This check is
	// required — providers must report RDMA status (v0.2.0+).
	if resp.RDMADisabled == nil {
		s.handleChallengeFailure(providerID, "RDMA status not reported — provider must update to v0.2.0+")
		return
	}
	if !*resp.RDMADisabled {
		// RDMA is enabled — only acceptable if hypervisor memory isolation
		// is active. The hypervisor's Stage 2 page tables make inference
		// memory invisible to RDMA DMA transfers.
		hvActive := resp.HypervisorActive != nil && *resp.HypervisorActive
		if !hvActive {
			s.logger.Error("provider RDMA enabled without hypervisor — remote memory access possible, marking untrusted",
				"provider_id", providerID,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "RDMA enabled without hypervisor memory isolation")
			return
		}
		s.logger.Info("provider RDMA enabled with hypervisor isolation — acceptable",
			"provider_id", providerID,
		)
	}

	// Verify fresh binary hash if reported and known hashes are configured.
	if resp.BinaryHash != "" && len(s.knownBinaryHashes) > 0 {
		if !s.knownBinaryHashes[resp.BinaryHash] {
			s.logger.Error("provider binary hash changed — no longer matches known-good list",
				"provider_id", providerID,
				"binary_hash", resp.BinaryHash,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "binary hash mismatch")
			return
		}
	}

	// Verify active model hash if reported and catalog has expected hash.
	if resp.ActiveModelHash != "" {
		// Get the current model from the provider's last heartbeat.
		provider.Mu().Lock()
		currentModel := provider.CurrentModel
		provider.Mu().Unlock()

		if currentModel != "" {
			expectedHash := s.registry.CatalogWeightHash(currentModel)
			if expectedHash != "" && resp.ActiveModelHash != expectedHash {
				s.logger.Error("provider active model hash mismatch — possible model swap",
					"provider_id", providerID,
					"model", currentModel,
					"expected", registry.TruncHash(expectedHash),
					"got", registry.TruncHash(resp.ActiveModelHash),
				)
				s.registry.MarkUntrusted(providerID)
				s.handleChallengeFailure(providerID, "active model weight hash mismatch")
				return
			}
		}
	}

	// Verify runtime integrity hashes from challenge response.
	if s.knownRuntimeManifest != nil {
		runtimeOK, mismatches := s.verifyRuntimeHashes(
			resp.PythonHash, resp.RuntimeHash, resp.TemplateHashes,
			resp.GrpcBinaryHash, resp.ImageBridgeHash)
		provider.Mu().Lock()
		provider.RuntimeVerified = runtimeOK
		if resp.PythonHash != "" {
			provider.PythonHash = resp.PythonHash
		}
		if resp.RuntimeHash != "" {
			provider.RuntimeHash = resp.RuntimeHash
		}
		provider.Mu().Unlock()

		if !runtimeOK {
			s.logger.Warn("provider runtime integrity mismatch in challenge response — excluding from routing",
				"provider_id", providerID,
				"mismatches", len(mismatches),
			)
			// Send status feedback but do NOT fail the challenge or mark untrusted.
			// The provider remains connected but is excluded from routing until
			// it reports matching hashes.
			if provider.Conn != nil {
				statusMsg := protocol.RuntimeStatusMessage{
					Type:       protocol.TypeRuntimeStatus,
					Verified:   false,
					Mismatches: mismatches,
				}
				statusData, err := json.Marshal(statusMsg)
				if err == nil {
					writeCtx, writeCancel := context.WithTimeout(context.Background(), 5*time.Second)
					_ = provider.Conn.Write(writeCtx, websocket.MessageText, statusData)
					writeCancel()
				}
			}
		}
	}

	// Challenge passed.
	s.registry.RecordChallengeSuccess(providerID)
	s.logger.Info("attestation challenge verified",
		"provider_id", providerID,
		"sip_enabled", resp.SIPEnabled,
		"secure_boot_enabled", resp.SecureBootEnabled,
		"rdma_disabled", resp.RDMADisabled,
		"hypervisor_active", resp.HypervisorActive,
		"binary_hash", resp.BinaryHash,
		"active_model_hash", resp.ActiveModelHash,
		"model_hashes_count", len(resp.ModelHashes),
	)
	for modelID, hash := range resp.ModelHashes {
		s.logger.Info("model weight hash verified",
			"provider_id", providerID,
			"model_id", modelID,
			"weight_hash", hash,
		)
	}
}

// handleChallengeFailure records a failed challenge and marks the provider
// as untrusted if the failure threshold is reached.
func (s *Server) handleChallengeFailure(providerID string, reason string) {
	failures := s.registry.RecordChallengeFailure(providerID)
	s.logger.Warn("attestation challenge failed",
		"provider_id", providerID,
		"reason", reason,
		"consecutive_failures", failures,
	)

	if failures >= MaxFailedChallenges {
		s.registry.MarkUntrusted(providerID)
	}
}

func (s *Server) handleChunk(providerID string, provider *registry.Provider, msg *protocol.InferenceResponseChunkMessage) {
	if provider == nil {
		s.logger.Warn("chunk from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.GetPending(msg.RequestID)
	if pr == nil {
		s.logger.Warn("chunk for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		return
	}
	// Non-blocking send — if consumer is gone the chunk is dropped.
	select {
	case pr.ChunkCh <- msg.Data:
	default:
		s.logger.Warn("dropped chunk, consumer channel full", "request_id", msg.RequestID)
	}
}

func (s *Server) handleInferenceAccepted(providerID string, provider *registry.Provider, msg *protocol.InferenceAcceptedMessage) {
	if provider == nil {
		return
	}
	pr := provider.GetPending(msg.RequestID)
	if pr == nil {
		return
	}
	// Non-blocking signal — the dispatch loop may have already committed.
	select {
	case pr.AcceptedCh <- struct{}{}:
	default:
	}
}

func (s *Server) handleComplete(providerID string, provider *registry.Provider, msg *protocol.InferenceCompleteMessage) {
	if provider == nil {
		s.logger.Warn("complete from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	if pr == nil {
		s.logger.Warn("complete for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		return
	}

	// Store SE signature for the consumer response headers.
	pr.SESignature = msg.SESignature
	pr.ResponseHash = msg.ResponseHash

	// Record job success and usage BEFORE closing ChunkCh. Closing
	// ChunkCh unblocks the consumer response handler, and callers may
	// check usage immediately after the HTTP response completes.
	responseTime := time.Duration(msg.Usage.CompletionTokens) * time.Millisecond * 10
	s.registry.RecordJobSuccess(providerID, responseTime)

	// Calculate cost — check provider's custom price, then platform DB price,
	// then hardcoded defaults.
	providerWalletForPricing := ""
	if p := s.registry.GetProvider(providerID); p != nil {
		providerWalletForPricing = p.WalletAddress
	}
	customIn, customOut, hasCustom := s.store.GetModelPrice(providerWalletForPricing, pr.Model)
	if !hasCustom {
		customIn, customOut, hasCustom = s.store.GetModelPrice("platform", pr.Model)
	}
	totalCost := payments.CalculateCostWithOverrides(pr.Model, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, customIn, customOut, hasCustom)

	// Clamp reported cost at the pre-flight reservation. The reservation
	// uses platform-default and platform-override pricing; a provider that
	// sets a custom price above the platform rate accepts revenue capped at
	// the reservation (this is documented by reservationCost). The clamp
	// also neutralizes over-reporting: with max_tokens injected into the
	// outgoing request a cooperating provider can never legitimately bill
	// more than the reservation, so excess means miscounting or fraud.
	// Logged at Error so misbehavior shows in the operator dashboards.
	if pr.ReservedMicroUSD > 0 && totalCost > pr.ReservedMicroUSD {
		s.logger.Error("provider reported cost above reservation — clamping",
			"provider_id", providerID,
			"request_id", msg.RequestID,
			"reported_cost_micro_usd", totalCost,
			"reserved_micro_usd", pr.ReservedMicroUSD,
			"prompt_tokens", msg.Usage.PromptTokens,
			"completion_tokens", msg.Usage.CompletionTokens,
		)
		totalCost = pr.ReservedMicroUSD
	}
	providerPayout := payments.ProviderPayout(totalCost)

	// Adjust billing against the pre-flight reservation. After the clamp above
	// totalCost <= reserved, so the only path here is a refund of the unused
	// portion. The old "charge extra" path is retained for the unreserved
	// code path below (billing disabled / legacy requests).
	if pr.ReservedMicroUSD > 0 {
		if totalCost < pr.ReservedMicroUSD {
			refund := pr.ReservedMicroUSD - totalCost
			_ = s.store.Credit(pr.ConsumerKey, refund, store.LedgerRefund, msg.RequestID)
		}
	} else {
		// No reservation (billing not configured). Charge best-effort.
		if err := s.ledger.Charge(pr.ConsumerKey, totalCost, msg.RequestID); err != nil {
			s.logger.Warn("could not charge consumer (insufficient balance)",
				"consumer_key", pr.ConsumerKey,
				"cost_micro_usd", totalCost,
				"error", err,
			)
		}
	}

	// Record usage entry — both in-memory (for current session) and persisted
	// to database (survives coordinator restart).
	s.ledger.RecordUsage(pr.ConsumerKey, payments.UsageEntry{
		JobID:            msg.RequestID,
		Model:            pr.Model,
		PromptTokens:     msg.Usage.PromptTokens,
		CompletionTokens: msg.Usage.CompletionTokens,
		CostMicroUSD:     totalCost,
		Timestamp:        time.Now(),
	})
	s.store.RecordUsageWithCost(providerID, pr.ConsumerKey, pr.Model, msg.RequestID, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, totalCost)

	// Credit the provider's pending payout.
	// If the provider is linked to an account (via device auth), credit that account.
	// Otherwise, fall back to the provider's self-reported wallet address.
	if p := s.registry.GetProvider(providerID); p != nil {
		if p.AccountID != "" {
			// Provider is linked to a Privy account — atomically credit the
			// account and record the per-node earning in one store transaction.
			if err := s.store.CreditProviderAccount(&store.ProviderEarning{
				AccountID:        p.AccountID,
				ProviderID:       providerID,
				ProviderKey:      p.PublicKey,
				JobID:            msg.RequestID,
				Model:            pr.Model,
				AmountMicroUSD:   providerPayout,
				PromptTokens:     msg.Usage.PromptTokens,
				CompletionTokens: msg.Usage.CompletionTokens,
				CreatedAt:        time.Now(),
			}); err != nil {
				s.logger.Error("failed to credit linked provider account",
					"provider_id", providerID,
					"account_id", p.AccountID,
					"request_id", msg.RequestID,
					"error", err,
				)
			}
		} else if p.WalletAddress != "" {
			// Unlinked provider — atomically credit the wallet and record payout history.
			if err := s.ledger.CreditProvider(p.WalletAddress, providerPayout, pr.Model, msg.RequestID); err != nil {
				s.logger.Error("failed to credit provider wallet payout",
					"provider_id", providerID,
					"wallet_address", p.WalletAddress,
					"request_id", msg.RequestID,
					"error", err,
				)
			}
		}
	}

	// Record platform fee, distributing referral rewards if applicable.
	platformFee := payments.PlatformFee(totalCost)
	if platformFee > 0 {
		// Check if consumer has a referrer and distribute reward.
		// The referral service deducts the referrer's share from the platform fee.
		if s.billing != nil && s.billing.Referral() != nil {
			platformFee = s.billing.Referral().DistributeReferralReward(pr.ConsumerKey, platformFee, msg.RequestID)
		}
		_ = s.store.Credit("platform", platformFee, store.LedgerPlatformFee, msg.RequestID)
	}

	// Signal completion to the consumer response handler. This must happen
	// AFTER usage/billing is recorded because closing ChunkCh immediately
	// unblocks the HTTP response, and callers may check usage right after.
	pr.CompleteCh <- msg.Usage
	close(pr.ChunkCh)
	close(pr.CompleteCh)

	// Mark provider idle if no more pending requests.
	s.registry.SetProviderIdle(providerID)

	s.logger.Info("inference complete",
		"request_id", msg.RequestID,
		"provider_id", providerID,
		"prompt_tokens", msg.Usage.PromptTokens,
		"completion_tokens", msg.Usage.CompletionTokens,
		"cost_micro_usd", totalCost,
		"provider_payout_micro_usd", providerPayout,
	)
}

func (s *Server) handleInferenceError(providerID string, provider *registry.Provider, msg *protocol.InferenceErrorMessage) {
	if provider == nil {
		s.logger.Warn("error from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	if pr == nil {
		s.logger.Warn("error for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		return
	}

	pr.ErrorCh <- *msg
	close(pr.ChunkCh)
	close(pr.CompleteCh)
	close(pr.ErrorCh)
	if pr.TranscriptionCh != nil {
		close(pr.TranscriptionCh)
	}
	if pr.ImageGenerationCh != nil {
		close(pr.ImageGenerationCh)
	}

	// Record job failure for reputation tracking.
	s.registry.RecordJobFailure(providerID)

	// Mark provider idle.
	s.registry.SetProviderIdle(providerID)

	s.logger.Error("inference error",
		"request_id", msg.RequestID,
		"provider_id", providerID,
		"error", msg.Error,
		"status_code", msg.StatusCode,
	)
}

func (s *Server) handleTranscriptionComplete(providerID string, provider *registry.Provider, msg *protocol.TranscriptionCompleteMessage) {
	if provider == nil {
		s.logger.Warn("transcription complete from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	if pr == nil {
		s.logger.Warn("transcription complete for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		return
	}

	// Send the full transcription result to the waiting handler.
	if pr.TranscriptionCh != nil {
		select {
		case pr.TranscriptionCh <- msg:
		default:
			s.logger.Warn("dropped transcription result, consumer channel full", "request_id", msg.RequestID)
		}
	}

	// Record job success.
	s.registry.RecordJobSuccess(providerID, time.Duration(msg.DurationSecs*float64(time.Second)))

	// Mark provider idle.
	s.registry.SetProviderIdle(providerID)

	s.logger.Info("transcription complete",
		"request_id", msg.RequestID,
		"provider_id", providerID,
		"audio_seconds", msg.Usage.AudioSeconds,
		"generation_tokens", msg.Usage.GenerationTokens,
		"duration_secs", msg.DurationSecs,
		"text_length", len(msg.Text),
	)
}

func (s *Server) handleImageGenerationComplete(providerID string, provider *registry.Provider, msg *protocol.ImageGenerationCompleteMessage) {
	if provider == nil {
		s.logger.Warn("image generation complete from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	if pr == nil {
		s.logger.Warn("image generation complete for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		return
	}

	// Send the result to the waiting consumer handler.
	if pr.ImageGenerationCh != nil {
		select {
		case pr.ImageGenerationCh <- msg:
		default:
			s.logger.Warn("dropped image generation result, consumer channel full", "request_id", msg.RequestID)
		}
	}

	// Record job success.
	s.registry.RecordJobSuccess(providerID, time.Duration(msg.DurationSecs*float64(time.Second)))

	// Calculate per-image cost.
	totalCost := payments.CalculateImageCost(msg.Usage.Model, msg.Usage.Width, msg.Usage.Height, msg.Usage.ImagesGenerated)
	providerPayout := payments.ProviderPayout(totalCost)

	// Charge consumer (best-effort — image already generated).
	if err := s.ledger.Charge(pr.ConsumerKey, totalCost, msg.RequestID); err != nil {
		s.logger.Warn("could not charge consumer for image generation",
			"consumer_key", pr.ConsumerKey,
			"cost_micro_usd", totalCost,
			"error", err,
		)
	}

	// Record usage entry — in-memory + persisted.
	s.ledger.RecordUsage(pr.ConsumerKey, payments.UsageEntry{
		JobID:        msg.RequestID,
		Model:        pr.Model,
		CostMicroUSD: totalCost,
		Timestamp:    time.Now(),
	})
	s.store.RecordUsageWithCost(providerID, pr.ConsumerKey, pr.Model, msg.RequestID, 0, 0, totalCost)

	// Credit the provider.
	if p := s.registry.GetProvider(providerID); p != nil {
		if p.AccountID != "" {
			if err := s.store.CreditProviderAccount(&store.ProviderEarning{
				AccountID:      p.AccountID,
				ProviderID:     providerID,
				ProviderKey:    p.PublicKey,
				JobID:          msg.RequestID,
				Model:          pr.Model,
				AmountMicroUSD: providerPayout,
				CreatedAt:      time.Now(),
			}); err != nil {
				s.logger.Error("failed to credit linked provider account for image generation",
					"provider_id", providerID,
					"account_id", p.AccountID,
					"request_id", msg.RequestID,
					"error", err,
				)
			}
		} else if p.WalletAddress != "" {
			if err := s.ledger.CreditProvider(p.WalletAddress, providerPayout, pr.Model, msg.RequestID); err != nil {
				s.logger.Error("failed to credit provider wallet for image generation",
					"provider_id", providerID,
					"wallet_address", p.WalletAddress,
					"request_id", msg.RequestID,
					"error", err,
				)
			}
		}
	}

	// Platform fee with referral distribution.
	platformFee := payments.PlatformFee(totalCost)
	if platformFee > 0 {
		if s.billing != nil && s.billing.Referral() != nil {
			platformFee = s.billing.Referral().DistributeReferralReward(pr.ConsumerKey, platformFee, msg.RequestID)
		}
		_ = s.store.Credit("platform", platformFee, store.LedgerPlatformFee, msg.RequestID)
	}

	// Mark provider idle.
	s.registry.SetProviderIdle(providerID)

	s.logger.Info("image generation complete",
		"request_id", msg.RequestID,
		"provider_id", providerID,
		"images_generated", msg.Usage.ImagesGenerated,
		"width", msg.Usage.Width,
		"height", msg.Usage.Height,
		"steps", msg.Usage.Steps,
		"duration_secs", msg.DurationSecs,
		"cost_micro_usd", totalCost,
		"provider_payout_micro_usd", providerPayout,
	)
}

// verifyProviderAttestation verifies a provider's Secure Enclave attestation
// if one was included in the registration message. If the attestation is valid,
// the provider is marked as attested. If missing or invalid, the provider is
// still accepted (Open Mode) but marked as not attested.
func (s *Server) verifyProviderAttestation(providerID string, provider *registry.Provider, regMsg *protocol.RegisterMessage) {
	if len(regMsg.Attestation) == 0 {
		s.logger.Info("provider registered without attestation (Open Mode)",
			"provider_id", providerID,
		)
		return
	}

	result, err := attestation.VerifyJSON(regMsg.Attestation)
	if err != nil {
		s.logger.Warn("failed to parse provider attestation",
			"provider_id", providerID,
			"error", err,
		)
		return
	}

	provider.SetAttestationResult(&result)

	if !result.Valid {
		s.logger.Warn("provider attestation invalid",
			"provider_id", providerID,
			"error", result.Error,
		)
		return
	}

	// If the attestation includes an encryption public key, verify it matches
	// the public_key in the Register message (binding E2E key to SE identity).
	if result.EncryptionPublicKey != "" && regMsg.PublicKey != "" {
		if result.EncryptionPublicKey != regMsg.PublicKey {
			s.logger.Warn("attestation encryption key does not match register public key",
				"provider_id", providerID,
				"attestation_key", result.EncryptionPublicKey,
				"register_key", regMsg.PublicKey,
			)
			result.Valid = false
			result.Error = "encryption key mismatch"
			provider.SetAttestationResult(&result)
			return
		}
	}

	// Verify binary hash against known-good hashes.
	if len(s.knownBinaryHashes) > 0 && result.BinaryHash != "" {
		if !s.knownBinaryHashes[result.BinaryHash] {
			s.logger.Warn("provider binary hash not in known-good list",
				"provider_id", providerID,
				"binary_hash", result.BinaryHash,
			)
			result.Valid = false
			result.Error = "binary hash not recognized"
			provider.SetAttestationResult(&result)
			return
		}
		s.logger.Info("provider binary hash verified",
			"provider_id", providerID,
			"binary_hash", registry.TruncHash(result.BinaryHash),
		)
	}

	provider.SetAttested(true, registry.TrustSelfSigned)

	// The SE attestation already proves SIP, Secure Boot, and binary hash —
	// the same checks a challenge re-verifies. Set LastChallengeVerified so
	// the provider is immediately routable. The 5-minute challenge cycle will
	// re-verify and add MDM cross-check for defense-in-depth.
	// Without this, a freshly connected provider waits up to 5 minutes before
	// it can serve any requests (until first challenge passes).
	provider.SetLastChallengeVerified(time.Now())

	s.logger.Info("provider attestation verified (self-signed)",
		"provider_id", providerID,
		"hardware_model", result.HardwareModel,
		"chip_name", result.ChipName,
		"serial_number", result.SerialNumber,
		"secure_enclave", result.SecureEnclaveAvailable,
		"sip_enabled", result.SIPEnabled,
		"secure_boot", result.SecureBootEnabled,
		"authenticated_root", result.AuthenticatedRootEnabled,
		"system_volume_hash", result.SystemVolumeHash,
		"binary_hash", result.BinaryHash,
		"trust_level", registry.TrustSelfSigned,
	)

	// Restore persisted state: if this provider was previously known (by serial
	// number or SE key), restore trust level, reputation, and account linkage.
	// Fresh attestation verification still runs (above), but stored reputation
	// is preserved so routing quality is maintained across coordinator restarts.
	if s.storedProviders != nil {
		var storedRec *store.ProviderRecord
		if result.SerialNumber != "" {
			storedRec = s.storedProviders[result.SerialNumber]
		}
		if storedRec == nil && result.PublicKey != "" {
			storedRec = s.storedProviders["sekey:"+result.PublicKey]
		}
		if storedRec != nil {
			s.registry.RestoreProviderState(provider, storedRec)
			s.logger.Info("restored persisted provider state",
				"provider_id", providerID,
				"stored_serial", storedRec.SerialNumber,
				"stored_trust", storedRec.TrustLevel,
			)
		}
	}

	// Deduplicate: if another provider connection exists from the same physical
	// device (same serial number), disconnect it. This prevents multiple
	// provider processes on the same machine from registering independently
	// and competing for a single shared vllm-mlx backend.
	if result.SerialNumber != "" {
		s.registry.DisconnectDuplicatesBySerial(providerID, result.SerialNumber)
	}

	// Persist provider state after attestation verification.
	// This captures the attestation result, serial number, and trust level.
	s.registry.PersistProvider(provider)

	// MDM verification: independently verify security posture via MicroMDM.
	// This upgrades trust from self_signed to hardware if MDM confirms
	// the device is enrolled and SIP/SecureBoot match.
	if s.mdmClient != nil && result.SerialNumber != "" {
		go s.verifyProviderViaMDM(providerID, provider, result)
	} else if s.mdmClient != nil && result.SerialNumber == "" {
		s.logger.Warn("provider attestation has no serial number — cannot verify via MDM",
			"provider_id", providerID,
		)
	}
}

// verifyProviderViaMDM runs MDM verification in the background.
// If MDM confirms the device's security posture, the trust level is upgraded.
func (s *Server) verifyProviderViaMDM(providerID string, provider *registry.Provider, attestResult attestation.VerificationResult) {
	s.logger.Info("starting MDM verification",
		"provider_id", providerID,
		"serial_number", attestResult.SerialNumber,
	)

	mdmResult, err := s.mdmClient.VerifyProvider(
		attestResult.SerialNumber,
		attestResult.SIPEnabled,
		attestResult.SecureBootEnabled,
	)
	if err != nil {
		s.logger.Error("MDM verification error",
			"provider_id", providerID,
			"error", err,
		)
		return
	}

	if !mdmResult.DeviceEnrolled {
		s.logger.Warn("provider device not enrolled in MDM — staying at self_signed trust",
			"provider_id", providerID,
			"serial_number", attestResult.SerialNumber,
			"error", mdmResult.Error,
		)
		return
	}

	if mdmResult.Error != "" {
		s.logger.Warn("MDM verification failed — marking provider untrusted",
			"provider_id", providerID,
			"error", mdmResult.Error,
			"mdm_sip", mdmResult.MDMSIPEnabled,
			"mdm_secure_boot", mdmResult.MDMSecureBootFull,
			"sip_match", mdmResult.SIPMatch,
			"secure_boot_match", mdmResult.SecureBootMatch,
		)
		s.registry.MarkUntrusted(providerID)
		return
	}

	// MDM SecurityInfo verification passed — upgrade to hardware trust.
	provider.SetAttested(true, registry.TrustHardware)
	s.logger.Info("MDM verification passed — upgraded to hardware trust",
		"provider_id", providerID,
		"serial_number", attestResult.SerialNumber,
		"mdm_sip", mdmResult.MDMSIPEnabled,
		"mdm_secure_boot", mdmResult.MDMSecureBootFull,
		"mdm_auth_root_volume", mdmResult.MDMAuthRootVolume,
	)

	// Persist the trust upgrade.
	s.registry.PersistProvider(provider)

	// Request Apple Device Attestation — Apple's servers generate a
	// certificate chain that proves this device's identity. This cert
	// chain can be independently verified by users against Apple's
	// Enterprise Attestation Root CA.
	s.verifyAppleDeviceAttestation(providerID, provider, attestResult, mdmResult.UDID)
}

// verifyAppleDeviceAttestation sends a DeviceInformation command requesting
// DevicePropertiesAttestation and verifies the Apple-signed certificate chain.
func (s *Server) verifyAppleDeviceAttestation(providerID string, provider *registry.Provider, attestResult attestation.VerificationResult, udid string) {
	if udid == "" {
		s.logger.Warn("no UDID for MDA verification", "provider_id", providerID)
		return
	}

	// Compute SE key hash for nonce-based key binding.
	// If the provider has an SE public key, include its hash as the
	// DeviceAttestationNonce (base64-encoded). Apple decodes the nonce and
	// embeds the raw bytes as FreshnessCode (OID 1.2.840.113635.100.8.11.1)
	// in the signed cert, cryptographically binding the SE key to genuine hardware.
	var seKeyNonce string
	var expectedFreshness [32]byte
	if attestResult.PublicKey != "" {
		seKeyHash := sha256.Sum256([]byte(attestResult.PublicKey))
		seKeyNonce = base64.StdEncoding.EncodeToString(seKeyHash[:])
		expectedFreshness = seKeyHash
		s.logger.Info("requesting Apple Device Attestation (MDA) with SE key binding",
			"provider_id", providerID,
			"udid", udid,
			"se_key_hash", hex.EncodeToString(seKeyHash[:8])+"...",
		)
	} else {
		s.logger.Info("requesting Apple Device Attestation (MDA)",
			"provider_id", providerID,
			"udid", udid,
		)
	}

	// Always send the raw plist command so the nonce reaches Apple's servers.
	// The structured MicroMDM API doesn't support DeviceAttestationNonce.
	_, err := s.mdmClient.SendDeviceAttestationCommand(udid, seKeyNonce)
	if err != nil {
		s.logger.Warn("failed to send DeviceInformation attestation command",
			"provider_id", providerID,
			"error", err,
		)
		return
	}

	// Wait for Apple's response (device contacts Apple's servers — may take longer)
	attestResp, err := s.mdmClient.WaitForDeviceAttestation(udid, 60*time.Second)
	if err != nil {
		s.logger.Warn("DevicePropertiesAttestation response timeout",
			"provider_id", providerID,
			"error", err,
		)
		return
	}

	// Verify the certificate chain against Apple's Enterprise Attestation Root CA
	mdaResult, err := attestation.VerifyMDADeviceAttestation(attestResp.CertChain)
	if err != nil {
		s.logger.Error("MDA certificate chain parse error",
			"provider_id", providerID,
			"error", err,
		)
		return
	}

	if !mdaResult.Valid {
		s.logger.Warn("MDA certificate chain verification FAILED — Apple did not attest this device",
			"provider_id", providerID,
			"error", mdaResult.Error,
		)
		return
	}

	// Cross-check: MDA serial must match the provider's self-reported serial
	if mdaResult.DeviceSerial != "" && mdaResult.DeviceSerial != attestResult.SerialNumber {
		s.logger.Error("MDA serial mismatch — provider is impersonating another device",
			"provider_id", providerID,
			"mda_serial", mdaResult.DeviceSerial,
			"attestation_serial", attestResult.SerialNumber,
		)
		s.registry.MarkUntrusted(providerID)
		return
	}

	// Apple Device Attestation verified — store proof for user verification.
	// Acquire provider lock since these fields are read by HTTP handlers
	// (handleProviderAttestation, handleChatCompletions) concurrently.
	seKeyBound := false
	if seKeyNonce != "" && len(mdaResult.FreshnessCode) > 0 {
		seKeyBound = bytes.Equal(mdaResult.FreshnessCode, expectedFreshness[:])
	}

	provider.Mu().Lock()
	provider.MDAVerified = true
	provider.MDACertChain = attestResp.CertChain
	provider.MDAResult = mdaResult
	provider.SEKeyBound = seKeyBound
	provider.Mu().Unlock()

	// Log results.
	if seKeyNonce != "" && len(mdaResult.FreshnessCode) > 0 {
		if seKeyBound {
			s.logger.Info("MDA verified with SE key binding — Apple CA confirmed device + key",
				"provider_id", providerID,
				"mda_serial", mdaResult.DeviceSerial,
				"mda_udid", mdaResult.DeviceUDID,
				"se_key_bound", true,
			)
		} else {
			s.logger.Warn("MDA verified but FreshnessCode mismatch — SE key NOT bound",
				"provider_id", providerID,
				"mda_serial", mdaResult.DeviceSerial,
				"expected_freshness", hex.EncodeToString(expectedFreshness[:8])+"...",
				"got_freshness", hex.EncodeToString(mdaResult.FreshnessCode[:min(8, len(mdaResult.FreshnessCode))])+"...",
			)
		}
	} else {
		s.logger.Info("Apple Device Attestation (MDA) verified — Apple CA confirmed device identity",
			"provider_id", providerID,
			"mda_serial", mdaResult.DeviceSerial,
			"mda_udid", mdaResult.DeviceUDID,
			"mda_os_version", mdaResult.OSVersion,
			"mda_sepos_version", mdaResult.SepOSVersion,
			"se_key_bound", false,
			"freshness_code_len", len(mdaResult.FreshnessCode),
		)
	}
}

// handleProviderAttestation returns the attestation proof for all providers.
// Users can independently verify the Apple MDA certificate chain against
// Apple's public Enterprise Attestation Root CA.
func (s *Server) handleProviderAttestation(w http.ResponseWriter, r *http.Request) {
	type providerAttestation struct {
		ProviderID    string `json:"provider_id"`
		ChipName      string `json:"chip_name"`
		HardwareModel string `json:"hardware_model"`
		SerialNumber  string `json:"serial_number"`
		TrustLevel    string `json:"trust_level"`
		Status        string `json:"status"`

		// Hardware specs
		MemoryGB int      `json:"memory_gb"`
		GPUCores int      `json:"gpu_cores"`
		Models   []string `json:"models"`

		// Secure Enclave attestation (self-signed)
		SecureEnclave     bool   `json:"secure_enclave"`
		SIPEnabled        bool   `json:"sip_enabled"`
		SecureBootEnabled bool   `json:"secure_boot_enabled"`
		AuthenticatedRoot bool   `json:"authenticated_root_enabled"`
		SystemVolumeHash  string `json:"system_volume_hash,omitempty"`
		SEPublicKey       string `json:"se_public_key"`

		// MDM SecurityInfo (verified by Apple's MDM framework)
		MDMVerified bool `json:"mdm_verified"`

		// ACME device-attest-01 (SE key proven by Apple)
		ACMEVerified bool `json:"acme_verified"`

		// Apple Device Attestation (MDA) — certificate chain signed by Apple
		MDAVerified   bool     `json:"mda_verified"`
		MDACertChain  []string `json:"mda_cert_chain_b64,omitempty"`
		MDASerial     string   `json:"mda_serial,omitempty"`
		MDAUDID       string   `json:"mda_udid,omitempty"`
		MDAOSVersion  string   `json:"mda_os_version,omitempty"`
		MDASepVersion string   `json:"mda_sepos_version,omitempty"`
	}

	var providers []providerAttestation

	s.registry.ForEachProvider(func(p *registry.Provider) {
		// Snapshot mutable fields under provider lock to avoid racing
		// with background MDA verification and challenge goroutines.
		p.Mu().Lock()
		trustLevel := p.TrustLevel
		status := p.Status
		mdaVerified := p.MDAVerified
		acmeVerified := p.ACMEVerified
		attestResult := p.AttestationResult
		mdaCertChain := p.MDACertChain
		mdaResult := p.MDAResult
		p.Mu().Unlock()

		pa := providerAttestation{
			ProviderID:   p.ID,
			TrustLevel:   string(trustLevel),
			Status:       string(status),
			MemoryGB:     p.Hardware.MemoryGB,
			GPUCores:     p.Hardware.GPUCores,
			MDMVerified:  trustLevel == registry.TrustHardware,
			MDAVerified:  mdaVerified,
			ACMEVerified: acmeVerified,
		}

		for _, m := range p.Models {
			pa.Models = append(pa.Models, m.ID)
		}

		if attestResult != nil {
			pa.ChipName = attestResult.ChipName
			pa.HardwareModel = attestResult.HardwareModel
			pa.SerialNumber = attestResult.SerialNumber
			pa.SecureEnclave = attestResult.SecureEnclaveAvailable
			pa.SIPEnabled = attestResult.SIPEnabled
			pa.SecureBootEnabled = attestResult.SecureBootEnabled
			pa.AuthenticatedRoot = attestResult.AuthenticatedRootEnabled
			pa.SystemVolumeHash = attestResult.SystemVolumeHash
			pa.SEPublicKey = attestResult.PublicKey
		}

		// Include MDA cert chain for independent verification
		if len(mdaCertChain) > 0 {
			for _, der := range mdaCertChain {
				pa.MDACertChain = append(pa.MDACertChain, base64.StdEncoding.EncodeToString(der))
			}
		}
		if mdaResult != nil {
			pa.MDASerial = mdaResult.DeviceSerial
			pa.MDAUDID = mdaResult.DeviceUDID
			pa.MDAOSVersion = mdaResult.OSVersion
			pa.MDASepVersion = mdaResult.SepOSVersion
		}

		providers = append(providers, pa)
	})

	resp := map[string]any{
		"providers":                providers,
		"apple_root_ca_url":        "https://www.apple.com/certificateauthority/",
		"apple_enterprise_root_ca": "Apple Enterprise Attestation Root CA",
		"verification_instructions": "Download each provider's mda_cert_chain_b64, decode from base64 to DER, " +
			"then verify the certificate chain against Apple's Enterprise Attestation Root CA. " +
			"If verification passes, Apple has confirmed this is a real Apple device with the attested properties.",
	}
	writeJSON(w, http.StatusOK, resp)
}

// SendInferenceRequest writes an inference request to the provider's WebSocket.
func SendInferenceRequest(ctx context.Context, conn *websocket.Conn, msg *protocol.InferenceRequestMessage, logger *slog.Logger) error {
	data, err := json.Marshal(msg)
	if err != nil {
		return err
	}
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		logger.Error("failed to send inference request", "request_id", msg.RequestID, "error", err)
		return err
	}
	return nil
}
