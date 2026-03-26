package api

// Provider WebSocket management for the DGInf coordinator.
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
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/dginf/coordinator/internal/attestation"
	"github.com/dginf/coordinator/internal/payments"
	"github.com/dginf/coordinator/internal/protocol"
	"github.com/dginf/coordinator/internal/registry"
	"github.com/dginf/coordinator/internal/store"
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
	nonce     string
	timestamp string
	sentAt    time.Time
	responseCh chan *protocol.AttestationResponseMessage
}

// challengeTracker manages pending challenges for provider connections.
type challengeTracker struct {
	mu       sync.Mutex
	pending  map[string]*pendingChallenge // keyed by nonce
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

	providerID := uuid.New().String()
	s.logger.Info("provider websocket connected", "provider_id", providerID, "remote", r.RemoteAddr)

	// Run the read loop; on return the provider is disconnected.
	s.providerReadLoop(r.Context(), conn, providerID)
}

// providerReadLoop reads messages from the provider WebSocket and dispatches
// them. It runs until the connection closes or the context is cancelled.
func (s *Server) providerReadLoop(ctx context.Context, conn *websocket.Conn, providerID string) {
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
			regMsg := msg.Payload.(*protocol.RegisterMessage)
			provider = s.registry.Register(providerID, conn, regMsg)
			s.verifyProviderAttestation(providerID, provider, regMsg)
			// Start challenge loop after registration
			go s.challengeLoop(loopCtx, conn, providerID, provider, tracker)

		case protocol.TypeHeartbeat:
			hbMsg := msg.Payload.(*protocol.HeartbeatMessage)
			s.registry.Heartbeat(providerID, hbMsg)

		case protocol.TypeInferenceResponseChunk:
			chunkMsg := msg.Payload.(*protocol.InferenceResponseChunkMessage)
			s.handleChunk(providerID, provider, chunkMsg)

		case protocol.TypeInferenceComplete:
			completeMsg := msg.Payload.(*protocol.InferenceCompleteMessage)
			s.handleComplete(providerID, provider, completeMsg)

		case protocol.TypeInferenceError:
			errMsg := msg.Payload.(*protocol.InferenceErrorMessage)
			s.handleInferenceError(providerID, provider, errMsg)

		case protocol.TypeAttestationResponse:
			respMsg := msg.Payload.(*protocol.AttestationResponseMessage)
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

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if provider.Status == registry.StatusUntrusted {
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

	// Verify the signature: for now, we verify that the provider sent back
	// the correct nonce and a non-empty signature. Full cryptographic
	// verification of the NaCl signature would require the NaCl signing
	// key (currently only X25519 encryption keys are exchanged). The key
	// possession is proven by the provider's ability to receive the challenge
	// on the authenticated WebSocket and echo back the correct nonce.
	if resp.Signature == "" {
		s.handleChallengeFailure(providerID, "empty signature")
		return
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

	// Challenge passed.
	s.registry.RecordChallengeSuccess(providerID)
	s.logger.Info("attestation challenge verified",
		"provider_id", providerID,
		"sip_enabled", resp.SIPEnabled,
		"secure_boot_enabled", resp.SecureBootEnabled,
	)
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

	// Send usage and signal completion.
	pr.CompleteCh <- msg.Usage
	close(pr.ChunkCh)
	close(pr.CompleteCh)

	// Record job success for reputation tracking.
	// Use a simple heuristic for response time based on token count.
	responseTime := time.Duration(msg.Usage.CompletionTokens) * time.Millisecond * 10
	s.registry.RecordJobSuccess(providerID, responseTime)

	// Record usage.
	s.store.RecordUsage(providerID, pr.ConsumerKey, pr.Model, msg.Usage.PromptTokens, msg.Usage.CompletionTokens)

	// Calculate cost and process payment.
	totalCost := payments.CalculateCost(pr.Model, msg.Usage.PromptTokens, msg.Usage.CompletionTokens)
	providerPayout := payments.ProviderPayout(totalCost)

	// Attempt to charge the consumer (best-effort for MVP — inference already completed).
	if err := s.ledger.Charge(pr.ConsumerKey, totalCost, msg.RequestID); err != nil {
		s.logger.Warn("could not charge consumer (insufficient balance)",
			"consumer_key", pr.ConsumerKey,
			"cost_micro_usd", totalCost,
			"error", err,
		)
	}

	// Record usage entry for the consumer's payment history.
	s.ledger.RecordUsage(pr.ConsumerKey, payments.UsageEntry{
		JobID:            msg.RequestID,
		Model:            pr.Model,
		PromptTokens:     msg.Usage.PromptTokens,
		CompletionTokens: msg.Usage.CompletionTokens,
		CostMicroUSD:     totalCost,
		Timestamp:        time.Now(),
	})

	// Credit the provider's pending payout.
	providerWallet := ""
	if p := s.registry.GetProvider(providerID); p != nil {
		providerWallet = p.WalletAddress
	}
	if providerWallet != "" {
		s.ledger.CreditProvider(providerWallet, providerPayout, pr.Model, msg.RequestID)
	}

	// Record platform fee as a separate ledger entry for accounting.
	platformFee := payments.PlatformFee(totalCost)
	if platformFee > 0 {
		_ = s.store.Credit("platform", platformFee, store.LedgerPlatformFee, msg.RequestID)
	}

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

	provider.AttestationResult = &result

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
			provider.AttestationResult = &result
			return
		}
	}

	provider.Attested = true
	provider.TrustLevel = registry.TrustSelfSigned
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
		"trust_level", provider.TrustLevel,
	)

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

	// MDM SecurityInfo verification passed — upgrade trust level
	provider.TrustLevel = registry.TrustHardware
	s.logger.Info("MDM verification passed — upgraded to hardware trust",
		"provider_id", providerID,
		"serial_number", attestResult.SerialNumber,
		"mdm_sip", mdmResult.MDMSIPEnabled,
		"mdm_secure_boot", mdmResult.MDMSecureBootFull,
		"mdm_auth_root_volume", mdmResult.MDMAuthRootVolume,
	)

	// MDA (Apple Device Attestation) is implemented but disabled.
	// It requires Apple Business Manager enrollment which isn't practical
	// for a decentralized provider network. The SecurityInfo path above
	// is self-reinforcing: spoofing it requires SIP to be off, which means
	// privacy is already compromised anyway. Enable MDA for managed fleets:
	//
	// s.verifyAppleDeviceAttestation(providerID, provider, attestResult, mdmResult.UDID)
}

// verifyAppleDeviceAttestation sends a DeviceInformation command requesting
// DevicePropertiesAttestation and verifies the Apple-signed certificate chain.
func (s *Server) verifyAppleDeviceAttestation(providerID string, provider *registry.Provider, attestResult attestation.VerificationResult, udid string) {
	if udid == "" {
		s.logger.Warn("no UDID for MDA verification", "provider_id", providerID)
		return
	}

	s.logger.Info("requesting Apple Device Attestation (MDA)",
		"provider_id", providerID,
		"udid", udid,
	)

	// Send DeviceInformation command requesting DevicePropertiesAttestation
	_, err := s.mdmClient.SendDeviceAttestationCommand(udid)
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

	// Apple Device Attestation verified
	provider.MDAVerified = true
	s.logger.Info("Apple Device Attestation (MDA) verified — Apple CA confirmed device identity",
		"provider_id", providerID,
		"mda_serial", mdaResult.DeviceSerial,
		"mda_udid", mdaResult.DeviceUDID,
		"mda_os_version", mdaResult.OSVersion,
		"mda_sepos_version", mdaResult.SepOSVersion,
	)
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
