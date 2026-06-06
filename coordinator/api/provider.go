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
	"errors"

	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

const (
	// DefaultChallengeInterval is how often the coordinator challenges providers.
	DefaultChallengeInterval = 5 * time.Minute

	// ChallengeResponseTimeout is how long to wait for a challenge response.
	ChallengeResponseTimeout = 30 * time.Second

	// MaxConsecutiveChallengeTimeoutsBeforeReconnect is the number of consecutive
	// transient challenge timeouts (no response within ChallengeResponseTimeout)
	// after which the coordinator force-closes the provider's WebSocket so it must
	// reconnect and re-register.
	//
	// MarkUntrustedTransient keeps challenging a provider in place so it can
	// self-recover via a later passing challenge — but that only helps if the
	// provider can actually send a response. A provider whose outbound path is
	// wedged keeps heartbeating (so it is never evicted by the stale sweeper)
	// while failing every challenge, leaving it pinned hardware/untrusted forever.
	// Cycling the connection forces a clean re-registration, which is the only way
	// back. Must be > MaxFailedChallenges so a brief blip (sleep/network) still
	// self-recovers without a disconnect.
	MaxConsecutiveChallengeTimeoutsBeforeReconnect = 6
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
		s.clearPendingACME(providerID)
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

// attachProviderLocation resolves the provider's approximate geographic
// location from the registration HTTP request. The resolved location is
// stored on the Provider struct for stats aggregation. Raw IP addresses
// are never persisted.
func (s *Server) attachProviderLocation(providerID string, provider *registry.Provider, r *http.Request) {
	if s.geoResolver == nil || provider == nil || r == nil {
		return
	}
	loc := s.geoResolver.Lookup(r)
	if loc == nil {
		return
	}
	provider.Mu().Lock()
	provider.Location = loc
	provider.Mu().Unlock()
	s.registry.PersistProvider(provider)
	if s.readCache != nil {
		s.readCache.Invalidate("stats:v1")
	}
	s.logger.Info("provider location resolved",
		"provider_id", providerID,
		"city", loc.City,
		"country", loc.CountryCode,
		"source", loc.Source,
	)
}

func (s *Server) applyACMETrust(providerID string, provider *registry.Provider, acmeResult *ACMEVerificationResult) {
	if acmeResult == nil || !acmeResult.Valid {
		return
	}

	provider.Mu().Lock()
	provider.ACMEVerified = true
	provider.Mu().Unlock()

	// Stash the result so retryACMETrust can re-run this on the first passing
	// challenge. At registration the attestation challenge/response has not yet
	// completed, so AttestationResult is nil and the two binding checks below
	// fail purely on ordering — without a retry the provider would stay
	// self_signed forever despite presenting a valid device cert.
	s.stashPendingACME(providerID, acmeResult)

	if !providerHasBoundEncryptionAttestation(provider) {
		// Expected before the first challenge completes; logged at debug so it
		// doesn't look like a failure. The retry path resolves it.
		s.logger.Debug("ACME cert verified but attestation not yet bound — will retry after challenge",
			"provider_id", providerID,
			"acme_serial", acmeResult.SerialNumber,
		)
		return
	}
	if !providerAttestationMatchesACMEKey(provider, acmeResult) {
		s.logger.Warn("ACME client cert key does not match the attested Secure Enclave key",
			"provider_id", providerID,
			"acme_serial", acmeResult.SerialNumber,
			"acme_issuer", acmeResult.Issuer,
			"acme_key_alg", acmeResult.PublicKeyAlg,
		)
		return
	}

	provider.SetAttested(true, registry.TrustHardware)
	s.sendTrustStatus(provider, registry.TrustHardware, "online", "ACME device attestation verified")
	s.clearPendingACME(providerID)
	s.logger.Info("ACME client cert verified — hardware trust via Apple SE attestation",
		"provider_id", providerID,
		"acme_serial", acmeResult.SerialNumber,
		"acme_issuer", acmeResult.Issuer,
		"acme_key_alg", acmeResult.PublicKeyAlg,
	)
}

// stashPendingACME records the connect-time ACME result for later retry.
func (s *Server) stashPendingACME(providerID string, acmeResult *ACMEVerificationResult) {
	s.pendingACMEMu.Lock()
	s.pendingACME[providerID] = acmeResult
	s.pendingACMEMu.Unlock()
}

// clearPendingACME drops a stashed ACME result (after a successful upgrade or
// on disconnect).
func (s *Server) clearPendingACME(providerID string) {
	s.pendingACMEMu.Lock()
	delete(s.pendingACME, providerID)
	s.pendingACMEMu.Unlock()
}

// retryACMETrust re-applies a stashed ACME result. Called from the
// challenge-success path so a provider whose device cert was presented at
// connect — but whose attestation had not yet bound — gets upgraded to
// hardware once the binding completes. Mirrors the MDM re-verification retry.
func (s *Server) retryACMETrust(providerID string, provider *registry.Provider) {
	s.pendingACMEMu.Lock()
	acmeResult := s.pendingACME[providerID]
	s.pendingACMEMu.Unlock()
	if acmeResult == nil {
		return
	}
	s.applyACMETrust(providerID, provider, acmeResult)
}

func providerHasBoundEncryptionAttestation(provider *registry.Provider) bool {
	provider.Mu().Lock()
	defer provider.Mu().Unlock()

	if provider.PublicKey == "" || provider.AttestationResult == nil || !provider.AttestationResult.Valid {
		return false
	}

	return provider.AttestationResult.EncryptionPublicKey != "" &&
		provider.AttestationResult.EncryptionPublicKey == provider.PublicKey
}

func providerAttestationMatchesACMEKey(provider *registry.Provider, acmeResult *ACMEVerificationResult) bool {
	if acmeResult == nil || acmeResult.PublicKey == "" {
		return false
	}

	provider.Mu().Lock()
	if provider.AttestationResult == nil || !provider.AttestationResult.Valid {
		provider.Mu().Unlock()
		return false
	}
	attestedKeyB64 := provider.AttestationResult.PublicKey
	provider.Mu().Unlock()

	if attestedKeyB64 == "" {
		return false
	}

	attestedRaw, err := base64.StdEncoding.DecodeString(attestedKeyB64)
	if err != nil {
		return false
	}
	acmeRaw, err := base64.StdEncoding.DecodeString(acmeResult.PublicKey)
	if err != nil {
		return false
	}

	attestedKey, err := attestation.ParseP256PublicKey(attestedRaw)
	if err != nil {
		return false
	}
	acmeKey, err := attestation.ParseP256PublicKey(acmeRaw)
	if err != nil {
		return false
	}

	return attestedKey.X.Cmp(acmeKey.X) == 0 && attestedKey.Y.Cmp(acmeKey.Y) == 0
}

// challengeLoop periodically sends attestation challenges to a provider.
func (s *Server) challengeLoop(ctx context.Context, conn *websocket.Conn, providerID string, provider *registry.Provider, tracker *challengeTracker) {
	if s.skipChallenge {
		return
	}

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
			// Stop only for a hard (non-recoverable) untrust. A transiently
			// untrusted provider (missed-challenge timeouts) keeps being
			// challenged so a later passing challenge can restore it.
			if provider.ChallengeShouldStop() {
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
	s.ddIncr("attestation.challenges_sent", nil)

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
			s.handleTransientChallengeFailure(conn, providerID, "no response")
			return
		}
		s.verifyChallengeResponse(providerID, provider, pc, resp)
	case <-time.After(timeout):
		tracker.remove(nonce)
		s.handleTransientChallengeFailure(conn, providerID, "timeout")
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

	// statusFieldsTrusted gates whether we treat resp.SIPEnabled,
	// resp.BinaryHash etc. as authoritative. False means the provider
	// signed only nonce+timestamp (legacy or downgrade), so the status
	// fields are advisory and we must not act on them as if they were
	// cryptographically bound.
	statusFieldsTrusted := false

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

		// Now verify the extended status signature if the provider sent
		// one. Old providers (pre-v0.3.11) won't — log and continue with
		// status fields untrusted. Mismatch is fatal: it means either
		// tampering or the provider is signing a different canonical
		// payload than this code expects.
		statusInput := attestation.StatusCanonicalInput{
			Nonce:             pc.nonce,
			Timestamp:         pc.timestamp,
			HypervisorActive:  resp.HypervisorActive,
			RDMADisabled:      resp.RDMADisabled,
			SIPEnabled:        resp.SIPEnabled,
			SecureBootEnabled: resp.SecureBootEnabled,
			BinaryHash:        resp.BinaryHash,
			ActiveModelHash:   resp.ActiveModelHash,
			PythonHash:        resp.PythonHash,
			RuntimeHash:       resp.RuntimeHash,
			TemplateHashes:    resp.TemplateHashes,
			ModelHashes:       resp.ModelHashes,
		}
		switch err := attestation.VerifyStatusSignature(
			provider.AttestationResult.PublicKey,
			resp.StatusSignature,
			statusInput,
		); err {
		case nil:
			statusFieldsTrusted = true
		case attestation.ErrStatusSignatureMissing:
			s.ddIncr("attestation.challenges", []string{"outcome:status_sig_missing"})
			s.logger.Warn("provider sent no status_signature — status fields are advisory; upgrade provider to bind them",
				"provider_id", providerID,
			)
		default:
			// Instrumentation for the non-recovering status-sig lockout seen on
			// a couple of nodes (cause unconfirmed). Because the plain challenge
			// signature already verified above (we returned on its failure),
			// reaching here isolates the status-sig / canonical path: log
			// plain_sig_passed plus the Go canonical bytes and per-field lengths
			// so a field-presence or canonicalization mismatch is diagnosable
			// from logs alone, without shipping a new build to the affected box.
			canonical, cerr := attestation.BuildStatusCanonical(statusInput)
			canonicalB64 := ""
			if cerr == nil {
				canonicalB64 = base64.StdEncoding.EncodeToString(canonical)
			}
			s.ddIncr("attestation.challenges", []string{"outcome:status_sig_failed"})
			if s.metrics != nil {
				s.metrics.IncCounter("attestation_status_sig_failed_total")
			}
			s.logger.Error("status signature verification failed — possible tampering or canonical mismatch",
				"provider_id", providerID,
				"error", err,
				"plain_sig_passed", true,
				"go_canonical_b64", canonicalB64,
				"go_canonical_len", len(canonical),
				"canonical_build_err", cerr,
				"status_sig_len", len(resp.StatusSignature),
				"binary_hash_len", len(resp.BinaryHash),
				"active_model_hash_len", len(resp.ActiveModelHash),
				"python_hash_len", len(resp.PythonHash),
				"runtime_hash_len", len(resp.RuntimeHash),
				"template_hashes_count", len(resp.TemplateHashes),
				"model_hashes_count", len(resp.ModelHashes),
			)
			s.handleChallengeFailure(providerID, "status signature verification failed: "+err.Error())
			return
		}
	}

	// Status-field enforcement policy (asymmetric, by design):
	//
	// The checks below act on resp.SIPEnabled / SecureBootEnabled /
	// RDMADisabled / BinaryHash / ActiveModelHash regardless of
	// statusFieldsTrusted. The asymmetry is intentional during the
	// v0.3.11 rollout window:
	//
	//   - Negative reports (SIP=false, hash mismatch, etc.) ALWAYS mark
	//     the provider untrusted. Acting on a negative is safe even if
	//     the field is spoofable: the worst case is a compromised
	//     provider DoS-ing itself, which we want anyway.
	//
	//   - Positive reports (SIP=true, hash matches) are accepted but
	//     can only be fully trusted when statusFieldsTrusted is true.
	//     A v0.3.10 provider with a compromised process (but intact SE
	//     key) can echo a valid nonce signature while lying that
	//     SIPEnabled=true. We accept this risk during rollout.
	//
	// TODO(security/v0.3.13+): Once `attestation_challenges_total{
	// outcome="status_sig_missing"}` is zero across the fleet for a
	// week, treat ErrStatusSignatureMissing as a hard challenge failure
	// (target: 2 release cycles after v0.3.11 GA).
	s.logger.Debug("attestation challenge response verified",
		"provider_id", providerID,
		"status_fields_trusted", statusFieldsTrusted,
	)

	// Verify fresh SIP status. This signal is mandatory for private text:
	// an omitted value is not evidence of safety, so fail closed.
	if resp.SIPEnabled == nil {
		s.handleChallengeFailure(providerID, "SIP status not reported")
		return
	}
	// If the provider reports SIP disabled, they've rebooted since
	// registration and are no longer trustworthy. SIP cannot be disabled at
	// runtime — a reboot into Recovery Mode is required.
	if !*resp.SIPEnabled {
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

	// Verify fresh RDMA status. Reporting remains mandatory so routing and
	// trust policy can distinguish single-node providers from RDMA-aware
	// cluster runtimes. RDMA enablement is not itself a challenge failure:
	// Apple Silicon Thunderbolt RDMA is IOMMU-scoped to registered buffers,
	// so the security boundary is the signed runtime's buffer-registration
	// discipline, not a hypervisor flag.
	if resp.RDMADisabled == nil {
		s.handleChallengeFailure(providerID, "RDMA status not reported — provider must update to v0.2.0+")
		return
	}
	if !*resp.RDMADisabled {
		s.logger.Info("provider RDMA enabled — accepting under registered-buffer RDMA policy",
			"provider_id", providerID,
			"backend", provider.Backend,
			"hypervisor_active", resp.HypervisorActive,
		)
	}

	// Verify fresh binary hash when a known-good policy is configured. A
	// reported binary hash only counts when the response is signed by the
	// provider key from a valid registration attestation.
	policyConfigured, knownBinaryHashes := s.binaryHashPolicySnapshot()
	if policyConfigured {
		attestationResult := provider.AttestationResult
		if attestationResult == nil || !attestationResult.Valid || attestationResult.PublicKey == "" {
			s.logger.Error("provider cannot prove binary hash without valid attestation",
				"provider_id", providerID,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "valid attestation required for binary hash policy")
			return
		}
		if resp.BinaryHash == "" {
			s.logger.Error("provider omitted binary hash while known-good policy is configured",
				"provider_id", providerID,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "binary hash missing")
			return
		}
		attestedBinaryHash, err := normalizeSHA256Hex(attestationResult.BinaryHash, "attested binary_hash")
		if err != nil {
			s.logger.Error("provider attestation has no usable binary hash",
				"provider_id", providerID,
				"binary_hash", attestationResult.BinaryHash,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "attested binary hash missing")
			return
		}
		binaryHash, err := normalizeSHA256Hex(resp.BinaryHash, "binary_hash")
		if err != nil || !knownBinaryHashes[binaryHash] {
			s.logger.Error("provider binary hash changed — no longer matches known-good list",
				"provider_id", providerID,
				"binary_hash", resp.BinaryHash,
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "binary hash mismatch")
			return
		}
		if binaryHash != attestedBinaryHash {
			s.logger.Error("provider binary hash changed from registration attestation",
				"provider_id", providerID,
				"attested_binary_hash", registry.TruncHash(attestedBinaryHash),
				"challenge_binary_hash", registry.TruncHash(binaryHash),
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "binary hash changed from registration attestation")
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

	// Verify runtime integrity hashes from the signed challenge response.
	// Swift providers omit Python/vllm hashes, but must still match manifest
	// entries for external runtime assets such as mlx.metallib.
	if s.knownRuntimeManifest != nil {
		runtimeOK, mismatches := s.verifyRuntimeHashesForBackend(
			provider.Backend, resp.PythonHash, resp.RuntimeHash, resp.TemplateHashes)
		provider.Mu().Lock()
		provider.RuntimeVerified = runtimeOK
		provider.RuntimeManifestChecked = runtimeOK
		if resp.PythonHash != "" {
			provider.PythonHash = resp.PythonHash
		}
		if resp.RuntimeHash != "" {
			provider.RuntimeHash = resp.RuntimeHash
		}
		if len(resp.TemplateHashes) > 0 {
			provider.TemplateHashes = registry.CloneStringMap(resp.TemplateHashes)
		}
		provider.Mu().Unlock()

		if !runtimeOK {
			// Log detailed mismatch info for debugging outages.
			mismatchDetails := make([]string, 0, len(mismatches))
			for _, m := range mismatches {
				mismatchDetails = append(mismatchDetails, m.Component+"="+m.Got)
			}
			s.logger.Warn("provider runtime integrity mismatch in challenge response — excluding from routing",
				"provider_id", providerID,
				"mismatches", len(mismatches),
				"details", mismatchDetails,
				"backend", provider.Backend,
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
			return
		}
	}

	provider.Mu().Lock()
	version := provider.Version
	provider.Mu().Unlock()
	if s.minProviderVersion != "" && version != "" && semverLess(version, s.minProviderVersion) {
		s.logger.Warn("provider version below minimum during challenge revalidation — excluded from routing",
			"provider_id", providerID,
			"version", version,
			"min_version", s.minProviderVersion,
		)
		s.ddIncr("provider_version_below_minimum", []string{"gate:challenge_revalidation", "version:" + version})
		provider.Mu().Lock()
		provider.RuntimeVerified = false
		provider.RuntimeManifestChecked = false
		provider.Mu().Unlock()
		return
	}

	// Override self-reported privacy capabilities with coordinator-verified
	// values from the challenge response. The coordinator independently checks
	// SIP during each attestation challenge. Hypervisor status is preserved as
	// a reported capability only; it is not the RDMA safety proof.
	provider.Mu().Lock()
	if provider.PrivacyCapabilities != nil {
		if resp.SIPEnabled != nil {
			provider.PrivacyCapabilities.SIPEnabled = *resp.SIPEnabled
		}
		if resp.HypervisorActive != nil {
			provider.PrivacyCapabilities.HypervisorActive = *resp.HypervisorActive
		}
	}
	provider.ChallengeVerifiedSIP = resp.SIPEnabled != nil && *resp.SIPEnabled
	provider.Mu().Unlock()

	// Challenge passed.
	recovered := s.registry.RecordChallengeSuccess(providerID)
	if recovered {
		// The provider was transiently untrusted and is now back online. It was
		// last told "untrusted" (handleChallengeFailure) and scheduled a 10-min
		// diagnostic auto-report; push a fresh "online" trust_status so it clears
		// that local state and cancels the report.
		provider.Mu().Lock()
		trustLevel := provider.TrustLevel
		provider.Mu().Unlock()
		s.sendTrustStatus(provider, trustLevel, "online", "recovered after transient deroute")
	}
	s.ddIncr("attestation.challenges", []string{"outcome:passed"})
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

	// Re-attempt MDM verification for self_signed providers. This handles
	// providers that installed the MDM enrollment profile after their initial
	// registration — they would otherwise stay at self_signed trust forever
	// since verifyProviderViaMDM only ran once at registration time.
	provider.Mu().Lock()
	trustLevel := provider.TrustLevel
	attestResult := provider.AttestationResult
	provider.Mu().Unlock()

	if trustLevel == registry.TrustSelfSigned && s.mdmClient != nil && attestResult != nil {
		result := *attestResult
		saferun.Go(s.logger, "retryMDMVerification", func() {
			s.verifyProviderViaMDM(providerID, provider, result)
		})
	}

	// Re-attempt ACME (mTLS device-cert) trust for self_signed providers.
	// applyACMETrust ran at registration before attestation was bound, so a
	// provider that presented a valid device cert can be promoted to hardware
	// now that the challenge has passed. No-op if nothing was stashed.
	if trustLevel == registry.TrustSelfSigned {
		s.retryACMETrust(providerID, provider)
	}
}

// handleTransientChallengeFailure records a transient challenge failure
// (timeout / no response) and, once a provider has missed too many consecutive
// challenges, force-closes its WebSocket so it must reconnect and re-register.
//
// A provider whose outbound path is wedged keeps heartbeating (so the stale
// sweeper never evicts it) while every challenge times out, pinning it
// hardware/untrusted forever. MarkUntrustedTransient alone cannot recover it
// because recovery requires a passing challenge, which requires a working
// outbound path. Cycling the connection forces a clean re-registration.
func (s *Server) handleTransientChallengeFailure(conn *websocket.Conn, providerID, reason string) {
	failures := s.handleChallengeFailure(providerID, reason)
	if conn == nil || failures < MaxConsecutiveChallengeTimeoutsBeforeReconnect {
		return
	}
	s.logger.Warn("provider exceeded consecutive challenge timeouts — forcing reconnect",
		"provider_id", providerID,
		"consecutive_failures", failures,
		"reason", reason,
	)
	s.ddIncr("attestation.force_reconnect", []string{"reason:" + reason})
	if s.metrics != nil {
		s.metrics.IncCounter("attestation_force_reconnect_total", MetricLabel{"reason", reason})
	}
	// Closing the conn unblocks providerReadLoop's conn.Read, which cancels the
	// loop context (stopping this challenge loop) and runs registry.Disconnect.
	_ = conn.Close(websocket.StatusPolicyViolation, "attestation unresponsive — reconnect required")
}

// handleChallengeFailure records a failed challenge and marks the provider
// as untrusted if the failure threshold is reached. It returns the running
// count of consecutive failures.
func (s *Server) handleChallengeFailure(providerID string, reason string) int {
	transient := reason == "timeout" || reason == "no response"
	failures := s.registry.RecordChallengeFailure(providerID, transient)
	s.ddIncr("attestation.challenges", []string{"outcome:failed"})
	s.logger.Warn("attestation challenge failed",
		"provider_id", providerID,
		"reason", reason,
		"consecutive_failures", failures,
	)

	severity := protocol.SeverityWarn
	if failures >= registry.MaxFailedChallenges {
		severity = protocol.SeverityError
		if transient {
			// Missed-challenge timeouts (sleep / network blip) are recoverable:
			// keep challenging and let a later passing challenge restore the
			// provider without requiring a reconnect.
			s.registry.MarkUntrustedTransient(providerID)
		} else {
			s.registry.MarkUntrusted(providerID)
		}
		if p := s.registry.GetProvider(providerID); p != nil {
			s.sendTrustStatus(p, p.TrustLevel, string(registry.StatusUntrusted), reason)
		}
	}
	s.emit(context.Background(), severity, protocol.KindAttestationFailure,
		"attestation challenge failed",
		map[string]any{
			"provider_id":     providerID,
			"reason":          reason,
			"reconnect_count": failures,
		})
	if s.metrics != nil {
		s.metrics.IncCounter("attestation_failures_total",
			MetricLabel{"reason", reason},
		)
	}
	s.ddIncr("attestation.failures", []string{"reason:" + reason})
	return failures
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
	chunkData, err := decryptTextResponseChunk(provider, pr, msg)
	if err != nil {
		s.logger.Warn("rejecting insecure response chunk",
			"provider_id", providerID,
			"request_id", msg.RequestID,
			"error", err,
		)
		s.registry.MarkUntrusted(providerID)
		s.handleInferenceError(providerID, provider, &protocol.InferenceErrorMessage{
			Type:       protocol.TypeInferenceError,
			RequestID:  msg.RequestID,
			Error:      "provider returned invalid encrypted chunk",
			StatusCode: http.StatusBadGateway,
		})
		return
	}
	// Non-blocking send — if consumer is gone the chunk is dropped.
	select {
	case pr.ChunkCh <- chunkData:
	default:
		s.logger.Warn("dropped chunk, consumer channel full", "request_id", msg.RequestID)
	}
}

func decryptTextResponseChunk(provider *registry.Provider, pr *registry.PendingRequest, msg *protocol.InferenceResponseChunkMessage) (string, error) {
	if msg.EncryptedData == nil {
		return "", errTextChunkViolation("plaintext text chunk")
	}
	if msg.Data != "" {
		return "", errTextChunkViolation("mixed plaintext and encrypted text chunk")
	}
	if provider.PublicKey == "" {
		return "", errTextChunkViolation("provider missing registered public key")
	}
	if msg.EncryptedData.EphemeralPublicKey != provider.PublicKey {
		return "", errTextChunkViolation("chunk sender key mismatch")
	}
	if pr.SessionPrivKey == nil {
		return "", errTextChunkViolation("missing coordinator session key")
	}

	payload := &e2e.EncryptedPayload{
		EphemeralPublicKey: msg.EncryptedData.EphemeralPublicKey,
		Ciphertext:         msg.EncryptedData.Ciphertext,
	}
	session := &e2e.SessionKeys{PrivateKey: *pr.SessionPrivKey}
	plaintext, err := e2e.Decrypt(payload, session)
	if err != nil {
		return "", err
	}
	return string(plaintext), nil
}

func errTextChunkViolation(reason string) error {
	return &textChunkViolationError{reason: reason}
}

type textChunkViolationError struct {
	reason string
}

func (e *textChunkViolationError) Error() string {
	return e.reason
}

func (s *Server) handleInferenceAccepted(provider *registry.Provider, msg *protocol.InferenceAcceptedMessage) {
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

	// Billing-zero observability: a COMPLETED request that reports zero tokens
	// is billed $0 (and fully refunded). The provider-side fix (EngineBridge
	// max + content-frame floor) should prevent this, but emit a metric so any
	// residual leak is visible on the dashboard rather than silent.
	if msg.Usage.CompletionTokens == 0 {
		s.ddIncr("billing.zero_usage_complete", []string{"model:" + pr.Model})
		s.logger.Warn("completed request reported zero completion tokens — billed $0",
			"provider_id", providerID,
			"request_id", msg.RequestID,
			"model", pr.Model,
			"prompt_tokens", msg.Usage.PromptTokens,
		)
	}

	// Record job success and usage BEFORE closing ChunkCh. Closing
	// ChunkCh unblocks the consumer response handler, and callers may
	// check usage immediately after the HTTP response completes.
	responseTime := time.Duration(msg.Usage.CompletionTokens) * time.Millisecond * 10
	s.registry.RecordJobSuccess(providerID, responseTime)

	// Resolve the consumer once: platform-fee override (nil = global default)
	// and whether this is a wholesale/service channel (e.g. OpenRouter). A
	// failed lookup (raw API-key account with no user row) falls back to
	// defaults. Service accounts run on a 0% fee.
	var feePercent *int64
	isServiceConsumer := false
	if u, err := s.store.GetUserByAccountID(pr.ConsumerKey); err == nil && u != nil {
		feePercent = u.PlatformFeePercent
		isServiceConsumer = u.Role == store.RoleService
	}

	// Calculate cost. Direct consumers: provider custom price, then platform DB
	// price, then hardcoded defaults, with the per-request minimum applied.
	// Service/wholesale traffic is billed at the advertised platform price
	// (never a provider's higher custom price) and is exempt from the minimum,
	// so the debit matches the published per-token OpenRouter feed exactly.
	providerAccountForPricing := ""
	if p := s.registry.GetProvider(providerID); p != nil {
		providerAccountForPricing = providerPricingKeys(p)
	}
	var customIn, customOut int64
	var hasCustom bool
	if !isServiceConsumer {
		customIn, customOut, hasCustom = s.store.GetModelPrice(providerAccountForPricing, pr.Model)
	}
	if !hasCustom {
		customIn, customOut, hasCustom = s.store.GetModelPrice("platform", pr.Model)
	}
	var totalCost int64
	if isServiceConsumer {
		totalCost = payments.CalculateCostWithOverridesNoMinimum(pr.Model, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, customIn, customOut, hasCustom)
	} else {
		totalCost = payments.CalculateCostWithOverrides(pr.Model, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, customIn, customOut, hasCustom)
	}

	providerPayout := payments.ProviderPayoutWithPercent(totalCost, feePercent)

	// Free settlement when an OWNED machine served the request. Two paths reach
	// here:
	//   - FreeSelfRoute (exclusive self-route): the router only ever picks owned
	//     providers, so a mismatch should be impossible (machine unlinked
	//     mid-flight); a mismatch falls back to paid to close the "mark free,
	//     serve elsewhere" hole.
	//   - PreferOwner (prefer-with-fallback): the request may legitimately have
	//     fallen back to a PUBLIC provider, in which case paid settlement is the
	//     correct, expected outcome — not an error.
	// Either way: free iff the provider that actually served it is owned by the
	// requesting account. Ownership is read from the serving provider object
	// (stable across deregistration), not a fresh lookup.
	freeSelfRoute := false
	if pr.FreeSelfRoute || pr.PreferOwner {
		serving := s.registry.GetProvider(providerID)
		if serving == nil {
			serving = provider
		}
		serving.Mu().Lock()
		servingOwner := serving.AccountID
		serving.Mu().Unlock()
		if servingOwner != "" && servingOwner == pr.ConsumerKey {
			// Owned machine served it → free. For PreferOwner this also fully
			// refunds the up-front reservation below (totalCost 0 < reserved).
			freeSelfRoute = true
			totalCost = 0
			providerPayout = 0
		} else if pr.FreeSelfRoute {
			// Exclusive self-route should never be served by a non-owned
			// provider — surface it and settle as paid (defense-in-depth).
			s.logger.Error("self-route completion served by a non-owned provider — settling as paid (defense-in-depth)",
				"provider_id", providerID,
				"request_id", msg.RequestID,
				"serving_owner", servingOwner,
				"consumer_key", pr.ConsumerKey,
			)
		}
		// PreferOwner served by a public provider is the normal fallback — no
		// log, settle as paid against the reservation.
	}

	billingFinalized := true

	// Settle billing against the pre-flight reservation. All balance
	// mutations (overage charge, refund) happen inside the finalization
	// gate so that a concurrent timeout/error refund path cannot race
	// with the settlement here.
	if pr.ReservedMicroUSD > 0 {
		if !pr.MarkReservationFinalized() {
			billingFinalized = false
			s.logger.Warn("skipping completion billing for already-finalized reservation",
				"provider_id", providerID,
				"request_id", msg.RequestID,
			)
		} else if totalCost > pr.ReservedMicroUSD {
			// Actual cost exceeds reservation (e.g. provider custom
			// pricing above platform rate). Attempt to charge the
			// consumer the difference. Cap overage at the reservation
			// amount as a fraud circuit-breaker — a provider cannot
			// bill more than 2x the pre-flight estimate.
			overage := totalCost - pr.ReservedMicroUSD
			if overage > pr.ReservedMicroUSD {
				s.logger.Error("overage exceeds reservation cap — clamping",
					"provider_id", providerID,
					"request_id", msg.RequestID,
					"reported_cost_micro_usd", totalCost,
					"reserved_micro_usd", pr.ReservedMicroUSD,
					"uncapped_overage_micro_usd", overage,
				)
				s.ddIncr("billing.cost_clamped", []string{"model:" + pr.Model})
				overage = pr.ReservedMicroUSD
				totalCost = pr.ReservedMicroUSD * 2
			}
			if err := s.ledger.Charge(pr.ConsumerKey, overage, "overage:"+msg.RequestID); err != nil {
				// Overage charge failed — clamp to reservation so
				// the provider still gets paid something.
				if errors.Is(err, store.ErrInsufficientBalance) {
					s.logger.Warn("overage charge failed (insufficient balance) — clamping to reservation",
						"provider_id", providerID,
						"request_id", msg.RequestID,
						"reported_cost_micro_usd", totalCost,
						"reserved_micro_usd", pr.ReservedMicroUSD,
						"overage_micro_usd", overage,
					)
				} else {
					s.logger.Error("overage charge failed (DB error) — clamping to reservation",
						"provider_id", providerID,
						"request_id", msg.RequestID,
						"reported_cost_micro_usd", totalCost,
						"reserved_micro_usd", pr.ReservedMicroUSD,
						"overage_micro_usd", overage,
						"error", err,
					)
				}
				s.ddIncr("billing.cost_clamped", []string{"model:" + pr.Model})
				totalCost = pr.ReservedMicroUSD
			} else {
				s.logger.Info("overage charged to consumer",
					"provider_id", providerID,
					"request_id", msg.RequestID,
					"overage_micro_usd", overage,
					"total_cost_micro_usd", totalCost,
				)
				s.ddIncr("billing.overage_charged", []string{"model:" + pr.Model})
				s.ddHistogram("billing.overage_micro_usd", float64(overage), []string{"model:" + pr.Model})
				pr.ReservedMicroUSD = totalCost
			}
			// Recompute payout after potential clamp.
			providerPayout = payments.ProviderPayoutWithPercent(totalCost, feePercent)
		} else if totalCost < pr.ReservedMicroUSD {
			refund := pr.ReservedMicroUSD - totalCost
			start := time.Now()
			_ = s.store.Credit(pr.ConsumerKey, refund, store.LedgerRefund, msg.RequestID)
			s.ddHistogram("billing.settlement_refund_micro_usd", float64(refund), []string{"model:" + pr.Model})
			s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:settlement_refund"})
		}
	} else if !freeSelfRoute {
		start := time.Now()
		if err := s.ledger.Charge(pr.ConsumerKey, totalCost, msg.RequestID); err != nil {
			if errors.Is(err, store.ErrInsufficientBalance) {
				s.logger.Warn("could not charge consumer (insufficient balance)",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
				)
			} else {
				s.logger.Error("could not charge consumer (DB error)",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
					"error", err,
				)
			}
			// If this was a self-route request that FELL BACK to paid settlement
			// (marked free at dispatch, but mid-flight ownership revalidation
			// failed), the owner has no balance because self-route skips
			// reservation — so a failed charge means no money was collected and
			// we must NOT credit the provider from an unfunded balance. Zero the
			// cost and payout. (Other no-reservation paths — e.g. admin /
			// platform-covered usage — keep their existing payout behavior.)
			if pr.FreeSelfRoute {
				totalCost = 0
				providerPayout = 0
				s.ddIncr("billing.uncollected_zeroed", []string{"model:" + pr.Model})
			}
		}
		s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:charge"})
	}

	if billingFinalized {
		// Record in-memory usage (for current session queries).
		s.ledger.RecordUsage(pr.ConsumerKey, payments.UsageEntry{
			JobID:            msg.RequestID,
			Model:            pr.Model,
			PromptTokens:     msg.Usage.PromptTokens,
			CompletionTokens: msg.Usage.CompletionTokens,
			CostMicroUSD:     totalCost,
			Timestamp:        time.Now(),
		})

		// Persist usage to DB asynchronously — billing has already been
		// settled above, so this INSERT is not on the critical path. KeyID
		// carries per-key usage/spend attribution (empty for legacy callers).
		//
		// Skip the persistent (public-stats-feeding) row for FREE self-route:
		// it is private, owner-only traffic and must not appear in the public
		// /stats time-series, request-location, or flow aggregations. Private-only
		// providers only ever serve free self-route, so this also keeps their
		// traffic out of public stats. The owner still sees it via the in-memory
		// RecordUsage above (their session/transparency view).
		if !freeSelfRoute {
			saferun.Go(s.logger, "recordUsage", func() {
				s.store.RecordUsageFull(providerID, pr.ConsumerKey, pr.KeyID, pr.Model, msg.RequestID, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, totalCost, pr.ConsumerLocation)
			})
		}

		s.ddIncr("inference.completions", []string{"model:" + pr.Model})
		s.ddCount("inference.prompt_tokens_total", int64(msg.Usage.PromptTokens), []string{"model:" + pr.Model})
		s.ddHistogram("inference.prompt_tokens", float64(msg.Usage.PromptTokens), []string{"model:" + pr.Model})
		s.ddCount("inference.completion_tokens_total", int64(msg.Usage.CompletionTokens), []string{"model:" + pr.Model})
		s.ddHistogram("inference.completion_tokens", float64(msg.Usage.CompletionTokens), []string{"model:" + pr.Model})

		// Resolve provider identity for payout.
		p := s.registry.GetProvider(providerID)
		if p == nil {
			p = provider
		}

		// Compute platform fee (needs referral lookup before spawning goroutines).
		platformFee := payments.PlatformFeeWithPercent(totalCost, feePercent)
		if platformFee > 0 && s.billing != nil && s.billing.Referral() != nil {
			platformFee = s.billing.Referral().DistributeReferralReward(pr.ConsumerKey, platformFee, msg.RequestID)
		}

		// Run provider credit and platform fee credit concurrently —
		// they target different accounts so there is no data dependency.
		var settlementWg sync.WaitGroup

		// Credit the provider's linked account (if any).
		if p != nil {
			p.Mu().Lock()
			accountID := p.AccountID
			publicKey := p.PublicKey
			p.Mu().Unlock()

			// Credit the provider only when there is an actual payout. A zero
			// payout means either free self-route (consumer == provider account)
			// or an uncollected charge (e.g. a self-route paid-fallback whose
			// owner had no balance) — in both cases we must not record a
			// (zero-value) earning row. Mirrors the platformFee > 0 guard below.
			if accountID != "" && !freeSelfRoute && providerPayout > 0 {
				settlementWg.Add(1)
				go func() {
					defer settlementWg.Done()
					start := time.Now()
					if err := s.store.CreditProviderAccount(&store.ProviderEarning{
						AccountID:        accountID,
						ProviderID:       providerID,
						ProviderKey:      publicKey,
						JobID:            msg.RequestID,
						Model:            pr.Model,
						AmountMicroUSD:   providerPayout,
						PromptTokens:     msg.Usage.PromptTokens,
						CompletionTokens: msg.Usage.CompletionTokens,
						CreatedAt:        time.Now(),
					}); err != nil {
						s.logger.Error("failed to credit linked provider account",
							"provider_id", providerID,
							"account_id", accountID,
							"request_id", msg.RequestID,
							"error", err,
						)
					}
					s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:provider_account_credit"})
					s.ddCount("billing.provider_credits_micro_usd", providerPayout, []string{"model:" + pr.Model, "type:account"})
				}()
			}
		}

		// Record platform fee.
		if platformFee > 0 {
			settlementWg.Add(1)
			go func() {
				defer settlementWg.Done()
				start := time.Now()
				_ = s.store.Credit("platform", platformFee, store.LedgerPlatformFee, msg.RequestID)
				s.ddHistogram("store.credit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:platform_fee"})
				s.ddCount("billing.platform_fees_micro_usd", platformFee, []string{"model:" + pr.Model})
			}()
		}

		settlementWg.Wait()
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

	// Record job failure for reputation tracking, but carve out capacity
	// rejections — those are not provider faults, just the provider declining
	// work it cannot currently serve (the coordinator reroutes these). Counting
	// them would unfairly penalise healthy providers shedding load. Capacity
	// signals: HTTP 503 (service unavailable) / 429 (too many requests), an
	// exhausted token budget, or an out-of-memory model-load reject.
	loweredErr := strings.ToLower(msg.Error)
	capacityRejection := msg.StatusCode == http.StatusServiceUnavailable ||
		msg.StatusCode == http.StatusTooManyRequests ||
		strings.Contains(loweredErr, "token_budget_exhausted") ||
		strings.Contains(loweredErr, "insufficient memory")
	if !capacityRejection {
		s.registry.RecordJobFailure(providerID)
	}

	// Mark provider idle.
	s.registry.SetProviderIdle(providerID)

	s.logger.Error("inference error",
		"request_id", msg.RequestID,
		"provider_id", providerID,
		"error", msg.Error,
		"status_code", msg.StatusCode,
	)
}

// verifyProviderAttestation verifies a provider's Secure Enclave attestation
// if one was included in the registration message. If the attestation is valid,
// the provider is marked as attested. If missing or invalid, the provider is
// accepted in Open Mode only when no binary hash policy is configured.
func (s *Server) verifyProviderAttestation(providerID string, provider *registry.Provider, regMsg *protocol.RegisterMessage) {
	policyConfigured, knownBinaryHashes := s.binaryHashPolicySnapshot()
	if len(regMsg.Attestation) == 0 {
		if policyConfigured {
			s.logger.Warn("provider registered without attestation while binary hash policy is configured",
				"provider_id", providerID,
			)
			provider.SetAttestationResult(&attestation.VerificationResult{
				Valid: false,
				Error: "attestation missing",
			})
			s.registry.MarkUntrusted(providerID)
			return
		}
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
		if policyConfigured {
			provider.SetAttestationResult(&attestation.VerificationResult{
				Valid: false,
				Error: "attestation invalid",
			})
			s.registry.MarkUntrusted(providerID)
		}
		return
	}

	provider.SetAttestationResult(&result)

	if !result.Valid {
		s.logger.Warn("provider attestation invalid",
			"provider_id", providerID,
			"error", result.Error,
		)
		if policyConfigured {
			s.registry.MarkUntrusted(providerID)
		}
		return
	}

	// Bind the WebSocket X25519 key used for E2E text encryption to the
	// attested Secure Enclave identity. If a provider wants to serve private
	// text, the attestation must carry the same encryption public key.
	if regMsg.PublicKey != "" {
		if result.EncryptionPublicKey == "" {
			s.logger.Warn("attestation missing encryption key for registered public key",
				"provider_id", providerID,
			)
			result.Valid = false
			result.Error = "attestation missing encryption public key"
			provider.SetAttestationResult(&result)
			if policyConfigured {
				s.registry.MarkUntrusted(providerID)
			}
			return
		}
		if result.EncryptionPublicKey != regMsg.PublicKey {
			s.logger.Warn("attestation encryption key does not match register public key",
				"provider_id", providerID,
				"attestation_key", result.EncryptionPublicKey,
				"register_key", regMsg.PublicKey,
			)
			result.Valid = false
			result.Error = "encryption key mismatch"
			provider.SetAttestationResult(&result)
			if policyConfigured {
				s.registry.MarkUntrusted(providerID)
			}
			return
		}
	}

	// Verify binary hash against known-good hashes. Once a binary hash policy is
	// configured, omission is a policy violation, not an Open Mode downgrade.
	if policyConfigured {
		if result.BinaryHash == "" {
			s.logger.Warn("provider binary hash missing while known-good policy is configured",
				"provider_id", providerID,
			)
			result.Valid = false
			result.Error = "binary hash missing"
			provider.SetAttestationResult(&result)
			s.registry.MarkUntrusted(providerID)
			return
		}
		binaryHash, err := normalizeSHA256Hex(result.BinaryHash, "binary_hash")
		if err != nil || !knownBinaryHashes[binaryHash] {
			s.logger.Warn("provider binary hash not in known-good list",
				"provider_id", providerID,
				"binary_hash", result.BinaryHash,
			)
			result.Valid = false
			result.Error = "binary hash not recognized"
			provider.SetAttestationResult(&result)
			s.registry.MarkUntrusted(providerID)
			return
		}
		s.logger.Info("provider binary hash verified",
			"provider_id", providerID,
			"binary_hash", registry.TruncHash(result.BinaryHash),
		)
	}

	provider.SetAttested(true, registry.TrustSelfSigned)
	s.sendTrustStatus(provider, registry.TrustSelfSigned, "online", "SE attestation verified, awaiting MDM/ACME upgrade")

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
		saferun.Go(s.logger, "verifyProviderViaMDM", func() {
			s.verifyProviderViaMDM(providerID, provider, result)
		})
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
		// A timeout means APN latency or device sleep — not evidence of
		// compromise. Keep the provider at its current trust level (self_signed)
		// instead of marking it untrusted.
		if strings.Contains(mdmResult.Error, "timeout") {
			s.logger.Warn("MDM verification timed out — staying at current trust level",
				"provider_id", providerID,
				"error", mdmResult.Error,
			)
			return
		}
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
	s.sendTrustStatus(provider, registry.TrustHardware, "online", "MDM verification passed")
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

// sendTrustStatus sends the provider its current trust level and status over
// the WebSocket connection. This allows the provider to react — e.g. by
// auto-reporting unified logs when it learns it is self_signed or untrusted.
func (s *Server) sendTrustStatus(provider *registry.Provider, trustLevel registry.TrustLevel, status string, reason string) {
	conn := provider.Conn
	if conn == nil {
		return
	}
	msg := protocol.TrustStatusMessage{
		Type:       protocol.TypeTrustStatus,
		TrustLevel: string(trustLevel),
		Status:     status,
		Reason:     reason,
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = conn.Write(ctx, websocket.MessageText, data)
}
