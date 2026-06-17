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

	"github.com/eigeninference/d-inference/coordinator/apns"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/mdm"
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

				// An abrupt read_error under high last-known memory pressure with
				// active inference is very likely a jetsam OOM (the kill leaves no
				// other trace). Require in-flight > 0: a graceful shutdown/update
				// drains first (and may surface here as a frame-less EOF rather
				// than a clean close), so gating on in-flight avoids misreading a
				// drained going-away close as OOM. Idle-box kills are recovered by
				// the provider's crash-log scrape instead.
				if provider != nil {
					memPressure, inFlight := provider.DisconnectDiagnostics()
					if inFlight > 0 && registry.ClassifyDisconnectReason(true, memPressure, inFlight) == registry.DisconnectReasonOOMSuspected {
						if s.metrics != nil {
							s.metrics.IncCounter("provider_oom_suspected_total")
						}
						s.ddIncr("provider.oom_suspected", nil)
						s.emit(context.Background(), protocol.SeverityError, protocol.KindOOM,
							"provider disconnected under memory pressure (suspected OOM)",
							map[string]any{
								"provider_id":     providerID,
								"memory_pressure": memPressure,
								"in_flight":       inFlight,
							})
					}
				}
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

			// Declaratively tell the provider the desired build per alias it
			// already serves, so a fresh/reconnected provider converges without a
			// separate catalog pull. Sent even when EMPTY: a provider that
			// reconnects (same process, prefetch state intact) after the alias it
			// was converging to was deleted/repointed must learn that nothing is
			// desired anymore, or its in-flight prefetch would hard-swap anyway.
			// Gated on Swift backend + feature version: a pre-feature provider's
			// strict decoder throws on unknown types.
			if s.providerSupportsDesiredModels(regMsg.Backend, regMsg.Version) {
				if err := s.registry.SendDesiredModels(providerID, s.registry.DesiredModelsForProvider(providerID)); err != nil {
					s.logger.Warn("failed to send desired_models after register",
						"provider_id", providerID, "error", err)
				}
			}

			// Start challenge loop after registration
			saferun.Go(s.logger, "challengeLoop", func() {
				s.challengeLoop(loopCtx, conn, providerID, provider, tracker)
			})

			// Start the per-connection MDM verification loop. It runs the initial
			// SecurityInfo check + a bounded, push-budget-aware retry, decoupled
			// from the 5-minute challenge ticker. No-op when no MDM client is
			// configured or the attestation carried no serial.
			saferun.Go(s.logger, "mdmVerificationLoop", func() {
				s.mdmVerificationLoop(loopCtx, providerID, provider)
			})

			// v0.6.0: APNs code-identity attestation. Runs only when an attestor is
			// configured; otherwise the provider simply never becomes CodeAttested
			// (fail-closed at the routing chokepoint once enforcement begins). The
			// code-identity proof and the SIP/liveness pillar compose at the routing
			// gate (providerSupportsPrivateTextLocked requires both). The loop pushes
			// (within the per-device budget) and polls; verification of the reply
			// happens in the read-loop delivery path (handleCodeAttestationResponse),
			// so a single dropped/late background push doesn't strand a capable
			// provider, and a reply on a reconnected socket still attests (Fix 1).
			if s.codeAttestor != nil {
				saferun.Go(s.logger, "codeAttest", func() {
					s.codeAttestLoop(loopCtx, providerID, provider)
				})
			}

		case protocol.TypeHeartbeat:
			hbMsg := msg.Payload.(*protocol.HeartbeatMessage)
			s.registry.Heartbeat(providerID, hbMsg)
			// W5 Fix 2 (2a): a late/changed APNs token carried in the heartbeat
			// re-arms a code-identity challenge WITHOUT a reconnect.
			s.maybeRearmCodeAttest(loopCtx, providerID, provider, hbMsg)

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

		case protocol.TypeCodeAttestationResponse:
			respMsg := msg.Payload.(*protocol.CodeAttestationResponseMessage)
			// Verify in the delivery path (Fix 1): a reply attests THIS live
			// connection even if the push round-trip outlived the pushing
			// goroutine or the original connection (reconnect).
			s.handleCodeAttestationResponse(providerID, provider, respMsg)

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
				duration := s.registry.ClearPendingModelLoad(providerID, statusMsg.ModelID)
				s.registry.RecordWarmPoolLoadResult(statusMsg.ModelID, true, duration)
				s.registry.DrainQueuedRequestsForModel(statusMsg.ModelID)
			case protocol.LoadModelStatusFailed:
				duration := s.registry.PendingModelLoadDuration(providerID, statusMsg.ModelID)
				s.registry.RecordWarmPoolLoadResult(statusMsg.ModelID, false, duration)
				if statusMsg.Error == protocol.ProviderDrainingForUpdate {
					// Transient: the provider refused only because it is
					// draining ahead of an auto-update restart. Shorten the
					// cooldown so a failed restart (provider resumes serving)
					// becomes loadable again quickly; queued requests are NOT
					// rejected — the provider is back within the queue window
					// and other providers remain plannable.
					s.registry.BackoffPendingModelLoadForDrain(providerID, statusMsg.ModelID)
				} else {
					// Keep the pending entry (TTL cooldown suppresses retry storms).
					// If no other provider can serve this model, reject queued
					// requests immediately rather than making them wait 120s.
					s.registry.RejectUnservableQueuedRequests(statusMsg.ModelID)
				}
			}
			// "started" status: no action — load is in progress.

		case protocol.TypeModelsUpdate:
			updateMsg := msg.Payload.(*protocol.ModelsUpdateMessage)
			s.handleModelsUpdate(providerID, provider, updateMsg)

		case protocol.TypePrefetchModelStatus:
			statusMsg := msg.Payload.(*protocol.PrefetchModelStatusMessage)
			// Observability only. The terminal "verified" state means the build
			// is on disk and hash-checked but NOT loaded into GPU — the provider
			// then emits an authoritative models_update (handleModelsUpdate) so
			// the registry learns it can serve the build (and drops the old one).
			s.handlePrefetchModelStatus(providerID, provider, statusMsg)

		default:
			s.logger.Warn("unhandled provider message type", "provider_id", providerID, "type", msg.Type)
		}
	}
}

// CodeAttestResponseTimeout bounds how long the coordinator will accept a
// provider's WebSocket reply to an APNs code-identity challenge after the push.
// It is no longer a blocking wait (Fix 1): verification happens in the read-loop
// delivery path (handleCodeAttestationResponse), so this is the acceptance window
// for the pushed nonce. Kept consistent with the APNs apns-expiration window
// (apns.challengeExpirySeconds, Fix 5) — a reply is honored for as long as the
// push could still be delivered. It seeds codeAttestThrottle.challengeValidity.
const CodeAttestResponseTimeout = 300 * time.Second

// codeAttestMetric records a code-identity attestation outcome to both Datadog
// (s.ddIncr) and the in-process registry exposed at /v1/admin/metrics, so the
// APNs code-attest funnel (push_sent → attested vs timeout/verify_failed/no_token)
// is measurable per cohort. Outcomes: no_token, reused, push_sent,
// push_send_failed, attested, nonce_mismatch, verify_failed, timeout,
// max_attempts, rearm_token_arrived, rearm_token_changed (W5 Fix 2 heartbeat
// re-arm). Metadata only — no provider identifiers in the metric.
func (s *Server) codeAttestMetric(outcome string) {
	s.ddIncr("code_attest", []string{"outcome:" + outcome})
	s.metrics.IncCounter("code_attest_total", MetricLabel{"outcome", outcome})
}

// codeAttestLoop drives the APNs code-identity challenge for one connection.
//
// Attestation is PER-CONNECTION: while a WebSocket is alive the provider's binary
// cannot change (a binary swap restarts the process and drops the connection), so
// one successful challenge proves the connection's code identity for its whole
// lifetime — there is NO periodic re-challenge. That also respects Apple's
// background-push budget (~2-3/hour/device); a 5-minute ticker (12/hour) would be
// throttled and dropped.
//
// The loop only PUSHES; it never blocks on the reply. The provider's
// code_attestation_response is verified in the read-loop delivery path
// (handleCodeAttestationResponse), which flips CodeAttested. So:
//   - Reuse: if this device (Secure Enclave key) attested recently with the same
//     binary version, the new connection inherits the proof with NO push.
//   - Reconnect-safe (Fix 1): the pushed nonce is tracked per-device, so a reply
//     that lands on a DIFFERENT (re)connection still attests; this loop just polls
//     GetCodeAttested and exits. A push budget held over from the prior connection
//     means this loop simply waits for that reply instead of burning a new push.
//   - Bounded, jittered retry (Fix 3): if no reply lands within the budget cooldown
//     the loop re-pushes, capped at maxAttempts. The poll/backoff cadence
//     (retryDelay) is decoupled from the push budget; alert delivery uses a far
//     shorter budget than background.
//
// Providers with no APNs device token (legacy <0.6.0, or headless boxes with no
// GUI session) can never attest, so the loop exits immediately — they are derouted
// once enforcement begins, the intended "everyone must update" outcome.
func (s *Server) codeAttestLoop(ctx context.Context, providerID string, provider *registry.Provider) {
	if s.codeAttestor == nil || provider == nil {
		return
	}

	provider.Mu().Lock()
	apnsToken := provider.APNsDeviceToken
	version := provider.Version
	var seKey string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
	}
	provider.Mu().Unlock()
	if apnsToken == "" {
		s.codeAttestMetric("no_token")
		s.logger.Info("code-attest: provider has no APNs device token; cannot attest (will be derouted once enforcement begins)",
			"provider_id", providerID)
		return
	}

	// Reuse a recent, same-version, SAME-TOKEN attestation for this device instead
	// of spending a push — the binary can't have changed (same version), the APNs
	// token is unchanged (Codex #7), and the proof is fresh.
	if s.codeAttestThrottle.reuseAttestation(seKey, version, apnsToken) {
		provider.SetCodeAttested(true)
		s.registry.DrainQueuedRequestsForProvider(provider)
		s.codeAttestMetric("reused")
		s.logger.Info("code-attest: reused a recent attestation for this device (no push)",
			"provider_id", providerID)
		return
	}

	// Alert delivery is not background-throttled, so it may retry on a far shorter
	// push budget than background (Fix 3). Detected via the attestor seam.
	alertMode := false
	if m, ok := s.codeAttestor.(interface{ Mode() apns.Mode }); ok {
		alertMode = m.Mode() == apns.ModeAlert
	}

	pushes := 0
	prevSent := false // the last push was accepted by APNs but not yet answered
	for {
		if provider.GetCodeAttested() {
			return // attested by the delivery path; nothing more to do
		}
		if provider.ChallengeShouldStop() {
			return // hard (non-recoverable) untrust — stop challenging
		}

		// Push when the per-device budget permits. A budget cooldown elapsing
		// without attestation means a delivered push's reply never came (timeout);
		// a budget held over from a prior connection means we simply wait (poll)
		// for that reply rather than burning another push (reconnect-safe).
		if s.codeAttestThrottle.allowPush(seKey, alertMode) {
			if prevSent {
				s.codeAttestMetric("timeout")
				s.logger.Warn("code-attest: no valid reply within the push budget; retrying",
					"provider_id", providerID, "attempt", pushes)
			}
			if pushes >= s.codeAttestThrottle.maxAttempts {
				s.codeAttestMetric("max_attempts")
				s.logger.Warn("code-attest: not attested after max attempts; will retry on a later reconnect (within the push budget)",
					"provider_id", providerID)
				return
			}
			s.codeAttestThrottle.recordPush(seKey)
			prevSent = s.sendCodeIdentityChallenge(ctx, providerID, provider)
			pushes++
		}

		// Poll for the delivery path's verdict on a jittered cadence decoupled from
		// the push budget; bail if the connection ends first.
		select {
		case <-ctx.Done():
			return
		case <-time.After(s.codeAttestThrottle.retryDelay()):
		}
	}
}

// maybeRearmCodeAttest re-arms an APNs code-identity challenge when a provider's
// HEARTBEAT carries a device token the coordinator has not yet acted on (W5 Fix
// 2, 2a): a headless/late-token Mac that only obtained its APNs token AFTER
// registration, or a token that ROTATED mid-connection. The original token
// arrives only in RegisterMessage, so without a heartbeat re-arm such providers
// would never be challenged again short of a full reconnect.
//
// SECURITY — the heartbeat token NEVER grants attestation. It only updates the
// push target so the coordinator can SEND a challenge; CodeAttested is still set
// exclusively by handleCodeAttestationResponse after the full E_K(nonce)
// round-trip is verified against the SE key bound at REGISTRATION. Two cases:
//   - First token on a previously token-less provider: record the token and arm
//     the normal loop. A genuine, same-version recent attestation may still be
//     reused — that is a real prior proof for this Secure-Enclave identity, not
//     the token.
//   - CHANGED token: a material change to the device's identity-binding inputs.
//     Reset CodeAttested (fail-closed — deroute until re-proven) AND force a real
//     challenge with NO reuse bypass (invalidateReuse), so the new token cannot
//     ride a proof earned under the old one.
//
// A token-less heartbeat is ignored (it never clears an existing token), and an
// unchanged token is a no-op, so the steady state adds no churn or pushes.
func (s *Server) maybeRearmCodeAttest(ctx context.Context, providerID string, provider *registry.Provider, hb *protocol.HeartbeatMessage) {
	if s.codeAttestor == nil || provider == nil || hb == nil {
		return
	}
	newTok := hb.APNsDeviceToken
	if newTok == "" {
		return // no token in this heartbeat — nothing to re-arm; never clears one
	}

	provider.Mu().Lock()
	oldTok := provider.APNsDeviceToken
	if oldTok == newTok {
		// Steady state: keep the environment in sync but do not re-challenge.
		if hb.APNsEnvironment != "" {
			provider.APNsEnvironment = hb.APNsEnvironment
		}
		provider.Mu().Unlock()
		return
	}
	changed := oldTok != ""
	provider.APNsDeviceToken = newTok
	if hb.APNsEnvironment != "" {
		provider.APNsEnvironment = hb.APNsEnvironment
	}
	var seKey string
	if provider.AttestationResult != nil {
		seKey = provider.AttestationResult.PublicKey
	}
	if changed {
		// Fail-closed: a changed token must complete a fresh round-trip before it
		// is treated as code-attested (and thus routable) again.
		provider.CodeAttested = false
	}
	provider.Mu().Unlock()

	if changed {
		// No bypass: drop the cached reuse record (in-memory) AND the persisted
		// row, so neither this connection nor a post-restart reseed can short-
		// circuit on a prior (old-token) proof — the loop must run a REAL
		// challenge against the new token (Codex #6). Also drop any outstanding
		// old-token challenge so a stale reply to it can't complete the rotation
		// if the fresh push is delayed/fails (Codex #1, fail-closed). And clear the
		// per-device push cooldown (keyed by SE key, tracking pushes to the OLD
		// token) so the forced re-challenge can reach the new token immediately —
		// the new token has its own Apple budget (Codex #9).
		s.codeAttestThrottle.invalidateReuse(seKey)
		s.codeAttestThrottle.clearChallenge(seKey)
		s.codeAttestThrottle.clearPushBudget(seKey)
		s.invalidatePersistedCodeAttestation(seKey)
		s.codeAttestMetric("rearm_token_changed")
		s.logger.Info("code-attest: APNs device token changed; forcing re-challenge (no reuse bypass)",
			"provider_id", providerID)
	} else {
		s.codeAttestMetric("rearm_token_arrived")
		s.logger.Info("code-attest: APNs device token arrived after registration; arming challenge (no reconnect)",
			"provider_id", providerID)
	}

	saferun.Go(s.logger, "codeAttestRearm", func() {
		s.codeAttestLoop(ctx, providerID, provider)
	})
}

// sendCodeIdentityChallenge pushes one APNs code-identity challenge (v0.6.0) and
// returns WITHOUT waiting for the reply (Fix 1). It generates a fresh nonce,
// records it per-device (keyed by the registration-bound SE key) so the read-loop
// delivery path can match the provider's code_attestation_response — even one that
// arrives on a later (reconnected) WebSocket — then pushes E_K(nonce) to the
// device. The nonce is a base64 string encrypted to the provider's X25519 key K
// via the same E2E path used for inference bodies; the eventual proof is the SE
// P-256 signature over that nonce (K is decrypt-only — there is no Sign_K).
// Fail-closed: a failed push clears the outstanding challenge so a stale reply for
// it can never attest. Returns true iff the push was accepted by APNs (so the loop
// can tell a delivered-but-unanswered push apart from a send failure). See
// docs/apns-code-attestation-design.md.
func (s *Server) sendCodeIdentityChallenge(ctx context.Context, providerID string, provider *registry.Provider) bool {
	if s.codeAttestor == nil || provider == nil {
		return false
	}
	provider.Mu().Lock()
	deviceToken := provider.APNsDeviceToken
	env := provider.APNsEnvironment
	pubKey := provider.PublicKey
	var sePubKey string
	if provider.AttestationResult != nil {
		sePubKey = provider.AttestationResult.PublicKey
	}
	provider.Mu().Unlock()

	if deviceToken == "" || pubKey == "" || sePubKey == "" {
		s.logger.Warn("code-attest skipped: missing device token, encryption key, or SE key",
			"provider_id", providerID,
			"has_token", deviceToken != "",
			"has_pubkey", pubKey != "",
			"has_se_key", sePubKey != "",
		)
		return false
	}

	nonceBytes := make([]byte, 32)
	if _, err := rand.Read(nonceBytes); err != nil {
		s.logger.Error("code-attest nonce generation failed", "provider_id", providerID, "error", err)
		return false
	}
	nonceB64 := base64.StdEncoding.EncodeToString(nonceBytes)

	// Record BEFORE the push so a reply that races back (even on another
	// connection) is matchable. Keyed by SE key, so it survives reconnects.
	s.codeAttestThrottle.recordChallenge(sePubKey, nonceB64)

	sendCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	err := s.codeAttestor.SendCodeChallenge(sendCtx, deviceToken, env, pubKey, nonceB64)
	cancel()
	if err != nil {
		// The push never went out — drop the outstanding challenge so no stale
		// reply for this nonce can attest.
		s.codeAttestThrottle.clearChallengeIf(sePubKey, nonceB64)
		s.codeAttestMetric("push_send_failed")
		s.logger.Warn("code-attest push send failed", "provider_id", providerID, "error", err)
		return false
	}
	s.codeAttestMetric("push_sent")
	// No blocking wait: the reply is verified in handleCodeAttestationResponse on
	// whichever live connection it lands.
	return true
}

// handleCodeAttestationResponse verifies a provider's code_attestation_response in
// the WebSocket read-loop delivery path and marks the connection CodeAttested on
// success (Fix 1). This is the SINGLE fail-closed code-identity chokepoint moved
// off the blocking push goroutine: it attests whatever live connection the reply
// lands on, so a late reply or a reply after a mid-flight reconnect still attests
// (within the pushed nonce's validity window), while every security check is
// byte-for-byte the prior logic:
//   - the reply's nonce must equal the nonce the coordinator pushed to THIS device
//     (looked up by the registration-bound SE key; proves the provider decrypted
//     E_K(nonce) ⟹ holds K), AND
//   - Sign_SE(nonce) must verify against the SE public key bound to THIS connection
//     at registration — never a key supplied in the response.
//
// Any failure leaves CodeAttested false (fail-closed). Runs in the read loop, so
// the (potentially slower) queue drain is dispatched to a goroutine.
func (s *Server) handleCodeAttestationResponse(providerID string, provider *registry.Provider, resp *protocol.CodeAttestationResponseMessage) {
	if provider == nil {
		s.logger.Warn("code-attest response from unregistered provider", "provider_id", providerID)
		return
	}
	if resp == nil {
		return
	}
	if provider.GetCodeAttested() {
		return // already attested on this connection; ignore duplicate/late replies
	}

	provider.Mu().Lock()
	var sePubKey string
	if provider.AttestationResult != nil {
		sePubKey = provider.AttestationResult.PublicKey
	}
	version := provider.Version
	apnsToken := provider.APNsDeviceToken
	provider.Mu().Unlock()

	if sePubKey == "" {
		s.codeAttestMetric("verify_failed")
		s.logger.Warn("code-attest response but provider has no registration-bound SE key",
			"provider_id", providerID)
		return
	}

	// Match against ANY still-valid nonce we pushed to THIS device (survives
	// reconnect, and accepts a reply to an earlier in-flight challenge in alert
	// mode; no/expired match => fail-closed) — Codex #8.
	if resp.Nonce == "" || !s.codeAttestThrottle.matchChallenge(sePubKey, resp.Nonce) {
		s.codeAttestMetric("nonce_mismatch")
		s.logger.Warn("code-attest response nonce mismatch or no outstanding challenge",
			"provider_id", providerID)
		return
	}
	// Verify Sign_SE(nonce) against the SE public key bound to THIS connection at
	// registration — never a key supplied in the response.
	if err := attestation.VerifyChallengeSignature(sePubKey, resp.Signature, resp.Nonce); err != nil {
		s.codeAttestMetric("verify_failed")
		s.logger.Warn("code-attest signature verification failed", "provider_id", providerID, "error", err)
		return
	}

	provider.SetCodeAttested(true)
	s.codeAttestThrottle.recordAttested(sePubKey, version, apnsToken)
	// Persist the same record (incl. the bound APNs token) so the reuse cache
	// survives a coordinator restart/blue-green deploy (W5 Fix 2) yet still forces a
	// re-challenge if the token later rotates (Codex #7). Behind the store seam +
	// off the read loop; written only here, after the full round-trip verified above.
	s.persistCodeAttestation(sePubKey, version, apnsToken)
	s.codeAttestThrottle.clearChallengeIf(sePubKey, resp.Nonce)
	s.codeAttestMetric("attested")
	s.logger.Info("provider code-attested via APNs", "provider_id", providerID)
	// Newly eligible for private routing — drain requests that queued waiting for an
	// attested provider instead of waiting for the next heartbeat tick. Off the read
	// loop so verification stays responsive.
	saferun.Go(s.logger, "codeAttestDrain", func() {
		s.registry.DrainQueuedRequestsForProvider(provider)
	})
}

// handlePrefetchModelStatus records a provider's background-prefetch progress.
// Prefetch downloads + verifies a build on disk without loading it into GPU.
// The authoritative "this build is now servable" signal is the separate
// models_update message (handleModelsUpdate), which carries the weight hash;
// the terminal "verified" status here is just observability/progress.
func (s *Server) handlePrefetchModelStatus(providerID string, provider *registry.Provider, msg *protocol.PrefetchModelStatusMessage) {
	s.logger.Info("provider prefetch_model_status",
		"provider_id", providerID,
		"model_id", msg.ModelID,
		"status", msg.Status,
		"bytes_done", msg.BytesDone,
		"bytes_total", msg.BytesTotal,
		"error", msg.Error,
	)
	s.ddIncr("provider.prefetch_status", []string{"model:" + msg.ModelID, "status:" + msg.Status})
	if msg.BytesTotal > 0 {
		s.ddGauge("provider.prefetch_progress_pct",
			float64(msg.BytesDone)/float64(msg.BytesTotal)*100,
			[]string{"provider_id:" + providerID, "model:" + msg.ModelID})
	}
}

// handleModelsUpdate merges a provider's authoritative model inventory update
// (sent after a verified prefetch) into its advertised models in place. Each
// build's weight hash is cross-checked against the catalog before it becomes
// routable, so a bad/buggy prefetch never takes traffic. This closes the loop
// without waiting for the provider to reconnect or resetting trust/reputation.
func (s *Server) handleModelsUpdate(providerID string, provider *registry.Provider, msg *protocol.ModelsUpdateMessage) {
	merged, dropped := s.registry.MergeProviderModels(providerID, msg.Models)
	for _, id := range merged {
		s.logger.Info("provider now advertises build (models_update)",
			"provider_id", providerID, "model_id", id)
		// Release any requests queued for this build now that a provider can
		// (cold-)serve it.
		s.registry.DrainQueuedRequestsForModel(id)
	}
	for _, id := range dropped {
		s.logger.Info("provider stopped advertising build (models_update)",
			"provider_id", providerID, "model_id", id)
		// Requests may have queued against the concrete previous build while it
		// was still acceptable. Recheck immediately: drain to another provider if
		// one exists, otherwise fail fast instead of waiting for queue timeout.
		s.registry.DrainQueuedRequestsForModel(id)
		s.registry.RejectUnservableQueuedRequests(id)
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
		s.ddIncr("acme.trust", []string{"outcome:nil_or_invalid"})
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
		s.ddIncr("acme.trust", []string{"outcome:not_bound"})
		s.logger.Debug("ACME cert verified but attestation not yet bound — will retry after challenge",
			"provider_id", providerID,
			"acme_serial", acmeResult.SerialNumber,
		)
		return
	}
	if !providerAttestationMatchesACMEKey(provider, acmeResult) {
		s.ddIncr("acme.trust", []string{"outcome:key_mismatch"})
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
	s.ddIncr("acme.trust", []string{"outcome:granted"})
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
	//
	// v0.6.0: binaryHash is self-reported and demoted to drift telemetry — APNs
	// code-identity attestation is the real code-identity signal — so this gate
	// deroutes a provider only when enforcement is explicitly enabled (rollback).
	policyConfigured, knownBinaryHashes := s.binaryHashPolicySnapshot()
	if s.binaryHashEnforce && policyConfigured {
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

	// Verify reported model weight hashes against the catalog. The response's
	// model_hashes map is keyed by model ID, so each entry is compared against
	// the catalog hash for exactly that model — race-free, and strictly
	// stronger than checking only the active model.
	//
	// The previous check compared resp.ActiveModelHash (the hash of whatever
	// model the PROVIDER considered current when it built the response)
	// against the catalog hash of provider.CurrentModel (the model the
	// COORDINATOR believed current, from the last heartbeat — up to a full
	// heartbeat interval stale). On a busy multi-model provider the current
	// model flips between heartbeats, so the two regularly disagreed and a
	// perfectly correct hash of model B was misread as a tampered hash of
	// model A ("possible model swap") → false hard-untrust. Hit in prod by
	// the two busiest dual-model boxes (gemma-4-26b + gpt-oss-20b interleaved).
	for modelID, hash := range resp.ModelHashes {
		if hash == "" {
			continue
		}
		expectedHash := s.registry.CatalogWeightHash(modelID)
		if expectedHash != "" && hash != expectedHash {
			s.logger.Error("provider model weight hash mismatch — possible model swap",
				"provider_id", providerID,
				"model", modelID,
				"expected", registry.TruncHash(expectedHash),
				"got", registry.TruncHash(hash),
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "model weight hash mismatch")
			return
		}
	}

	// The bare active_model_hash names no model, so the strongest race-free
	// statement it admits is membership: when EVERY advertised model has an
	// enforced catalog hash, a hash that matches none of them is tampered.
	// This runs regardless of model_hashes — a map holding only empty or
	// unknown entries must not suppress it — and stays inconclusive (skipped)
	// when any advertised model is unenforced, since the bare hash could
	// legitimately belong to that model. (Comparing against the
	// heartbeat-derived "current model" instead is inherently racy — see
	// above.)
	if resp.ActiveModelHash != "" {
		provider.Mu().Lock()
		models := provider.Models
		provider.Mu().Unlock()
		allEnforced := len(models) > 0
		matched := false
		for _, m := range models {
			expectedHash := s.registry.CatalogWeightHash(m.ID)
			if expectedHash == "" {
				allEnforced = false
				break
			}
			if resp.ActiveModelHash == expectedHash {
				matched = true
			}
		}
		// Alias hot-swap (v0.6.x): a hard-swapped build can stay GPU-resident —
		// and remain the provider's "active" model — AFTER it leaves the
		// advertised set (the retired slot drains via the idle monitor, up to
		// an hour). Its hash still arrives in model_hashes, where the per-model
		// loop above already proved it matches its own catalog entry. Such a
		// validated, registered build is a legitimate alibi for the bare active
		// hash — NOT a swap. Without this, every provider hard-untrusts at its
		// first post-swap challenge until a request lands on the new build.
		// A genuinely tampered hash still matches neither the advertised set
		// nor any catalog-validated reported hash, and still untrusts.
		if !matched {
			for modelID, hash := range resp.ModelHashes {
				if hash == "" || hash != resp.ActiveModelHash {
					continue
				}
				// Scope the alibi to the actual migration case: modelID must be a
				// PREVIOUS/RETIRED member of some alias (a build a hot-swap leaves
				// resident after de-advertising it), not just any catalog model.
				// This keeps the membership check tight — a provider can't name an
				// arbitrary unrelated catalog model as "active" to dodge it.
				if !s.registry.IsAliasLineageBuild(modelID) {
					continue
				}
				if expected := s.registry.CatalogWeightHash(modelID); expected != "" && hash == expected {
					matched = true
					break
				}
			}
		}
		if allEnforced && !matched {
			s.logger.Error("provider active model hash matches no advertised model — possible model swap",
				"provider_id", providerID,
				"got", registry.TruncHash(resp.ActiveModelHash),
			)
			s.registry.MarkUntrusted(providerID)
			s.handleChallengeFailure(providerID, "active model weight hash mismatch")
			return
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

	// Challenge passed. Refresh stored per-model weight hashes BEFORE
	// RecordChallengeSuccess: its queue drain re-enters routing, and queued
	// requests must be admitted against the hashes this verified response just
	// proved — not the registration-time snapshot. The provider recomputes
	// hashes when it (re)loads a model from disk (e.g. after a model
	// re-publish), so the registration-time value can go stale mid-connection,
	// which would silently fail the per-model catalog routing filter until the
	// next reconnect.
	s.registry.UpdateModelWeightHashes(providerID, resp.ModelHashes)

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

	// MDM SecurityInfo re-verification is intentionally NOT driven from the
	// challenge response anymore. It used to re-run on every 5-minute challenge
	// for self_signed providers, which fired an MDM/APNs push each time and got
	// throttled by Apple (~2-3/hr budget) — the throttling itself caused the
	// SecurityInfo timeouts that stranded providers at self_signed. SIP/Secure
	// Boot can't change without a reboot, and a reboot drops this WebSocket, so
	// the per-connection mdmVerificationLoop (spawned alongside challengeLoop)
	// now owns MDM verification with a push-budget-aware backoff. See
	// mdmVerificationLoop.
	provider.Mu().Lock()
	trustLevel := provider.TrustLevel
	provider.Mu().Unlock()

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
		// The provider is still generating into a stream we abandoned (consumer
		// gone / already settled), burning its GPU and token-budget admission.
		// Nudge it to stop — throttled so a chunk-per-token zombie doesn't flood
		// the provider with cancels.
		if s.zombieCanceller.shouldCancel(msg.RequestID, time.Now()) {
			s.sendProviderCancel(provider, msg.RequestID)
			s.ddIncr("inference.zombie_stream_cancel", []string{})
		}
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

// maxPlausibleDecodeTPS is the sanity ceiling applied to the telemetry-only
// ActualDecodeTPS before it is persisted. Real decode throughput on the fleet's
// Apple-silicon hardware is in the tens-to-low-hundreds of tokens/sec; this
// ceiling is far above any genuine value and exists solely to stop a dishonest
// or buggy provider's unbounded CompletionTokens from writing an absurd TPS that
// could skew routing calibration. The value is advisory, never a security gate.
const maxPlausibleDecodeTPS = 10000.0

func (s *Server) handleComplete(providerID string, provider *registry.Provider, msg *protocol.InferenceCompleteMessage) {
	if provider == nil {
		s.logger.Warn("complete from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	// Clear any parked settlement record (consumer disconnected mid-stream):
	// settles the disconnect case and stops the grace timer from no-op-refunding.
	parked := s.claimSettlement(msg.RequestID)
	if pr == nil {
		pr = parked
	}
	if pr == nil {
		s.logger.Warn("complete for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		return
	}
	// A parked record means the consumer handler already returned: there is no
	// channel reader, and registry.Disconnect may have already CLOSED the
	// channels (park-before-remove leaves a window where the record is in both
	// the pending map and the holder) — sending would panic. Billing still
	// settles below; only the consumer signaling is skipped.
	consumerGone := parked != nil

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
	s.reconcileOutputAdmission(pr, msg.Usage.CompletionTokens)

	// Record job success and usage BEFORE closing ChunkCh. Closing
	// ChunkCh unblocks the consumer response handler, and callers may
	// check usage immediately after the HTTP response completes.
	//
	// Only the success COUNT is recorded here. The responsiveness latency is
	// recorded separately by the consumer/dispatch goroutine at commit (see
	// dispatch.writeCommittedResponse), because that goroutine owns pr.Timing;
	// reading it from this provider read-loop goroutine would race the dispatch
	// writes. Passing 0 latency counts the success without touching the EWMA.
	s.registry.RecordJobSuccess(providerID, 0)
	// Serving this model proves the pair can load — lift any cool-down early.
	s.registry.ClearDispatchLoadCooldown(providerID, pr.Model)

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
	if pr.ServiceReservation && pr.ReservedMicroUSD > 0 {
		var chargeErr error
		finalized, _ := pr.FinalizeReservation(func() error {
			if totalCost > 0 {
				start := time.Now()
				chargeErr = s.ledger.Charge(pr.ConsumerKey, totalCost, msg.RequestID)
				s.ddHistogram("store.debit.latency_ms", float64(time.Since(start).Milliseconds()), []string{"op:service_reservation_settle"})
			}
			s.releaseServiceReservation(pr, "finalize")
			return nil
		})
		if !finalized {
			billingFinalized = false
			s.logger.Warn("skipping completion billing for already-finalized service reservation",
				"provider_id", providerID,
				"request_id", msg.RequestID,
			)
		} else if chargeErr != nil {
			if errors.Is(chargeErr, store.ErrInsufficientBalance) {
				s.logger.Warn("service reservation settlement failed (insufficient balance) — zeroing uncollected charge",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
				)
			} else {
				s.logger.Error("service reservation settlement failed (DB error) — zeroing uncollected charge",
					"consumer_key", pr.ConsumerKey,
					"cost_micro_usd", totalCost,
					"error", chargeErr,
				)
			}
			totalCost = 0
			providerPayout = 0
			s.ddIncr("billing.uncollected_zeroed", []string{"model:" + pr.Model, "mode:service_hold"})
		} else {
			s.ddIncr("billing.reservation_finalize", []string{"model:" + pr.Model, "mode:service_hold", "outcome:charged"})
			s.ddHistogram("billing.service_settlement_micro_usd", float64(totalCost), []string{"model:" + pr.Model})
		}
	} else if pr.ReservedMicroUSD > 0 {
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
			Model:            consumerModel(pr),
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
				s.store.RecordUsageFullWithPublicModel(providerID, pr.ConsumerKey, pr.KeyID, pr.Model, consumerModel(pr), msg.RequestID, msg.Usage.PromptTokens, msg.Usage.CompletionTokens, totalCost, pr.ConsumerLocation)
			})
		}

		// Update the routing telemetry outcome with final token counts and timing.
		// handleComplete is the authoritative final writer for a SUCCESSFUL request
		// (UpdateInferenceRouteOutcome overwrites the whole row), so this outcome
		// carries the full coordinator-side latency decomposition and the measured
		// decode throughput in addition to tokens/cost.
		s.submitTelemetry("updateInferenceRoute", func() {
			outcome := &store.InferenceRouteOutcome{
				FinalStatus:      "success",
				PromptTokens:     msg.Usage.PromptTokens,
				CompletionTokens: msg.Usage.CompletionTokens,
				ReasoningTokens:  msg.Usage.ReasoningTokens,
				CostMicroUSD:     totalCost,
			}
			if pr.Timing != nil {
				t := pr.Timing
				// This runs on the provider read-loop goroutine, not the request
				// owner. FirstChunkAt is the one Timing field the dispatch goroutine
				// writes after dispatch (while streaming), so read it via the
				// mutex-guarded accessor to avoid a data race. The remaining fields
				// (DispatchedAt, ReceivedAt, and those used by applyTimingDecomposition)
				// are all stamped before dispatch and are safe to read here via the
				// provider-registration happens-before edge.
				firstChunk := pr.FirstChunkAtSafe()
				if !firstChunk.IsZero() && !t.DispatchedAt.IsZero() {
					ms := float64(firstChunk.Sub(t.DispatchedAt).Milliseconds())
					outcome.ActualTTFTMs = ms
					outcome.DispatchToFirstChunkMs = ms
				}
				if !t.ReceivedAt.IsZero() {
					outcome.TotalDurationMs = float64(time.Since(t.ReceivedAt).Milliseconds())
				}
				// Coordinator-side latency decomposition (ParseMs..DispatchMs).
				applyTimingDecomposition(outcome, t, firstChunk)
				// Measured decode throughput: completion tokens over the decode
				// window (first chunk -> completion). Guard zero/negative
				// durations and zero tokens so unmeasurable requests record 0.
				// CompletionTokens is provider-supplied and untrusted, so clamp the
				// derived TPS to a sanity ceiling: a dishonest/buggy provider must
				// not be able to write an absurd value that would skew routing
				// calibration (threat-model T-007/T-027). Throughput is advisory,
				// never a security gate.
				if msg.Usage.CompletionTokens > 0 && !firstChunk.IsZero() {
					if decodeSecs := time.Since(firstChunk).Seconds(); decodeSecs > 0 {
						tps := float64(msg.Usage.CompletionTokens) / decodeSecs
						if tps > maxPlausibleDecodeTPS {
							tps = maxPlausibleDecodeTPS
						}
						outcome.ActualDecodeTPS = tps
					}
				}
			}
			_ = s.store.UpdateInferenceRouteOutcome(msg.RequestID, pr.Attempt, outcome)
		})

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
	// Skipped when the consumer is gone: no reader, and the channels may
	// already be closed (send would panic).
	if !consumerGone {
		pr.CompleteCh <- msg.Usage
		close(pr.ChunkCh)
		close(pr.CompleteCh)
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

// isModelLoadFailure reports whether a (lowercased) provider error terminal
// indicates the provider could not LOAD the requested model — either a
// capacity reject ("insufficient memory to load model …", provider-side
// fastAdmissionReject/evictUntilAvailable) or a generic load failure ("model
// load failed: …", InferenceError.modelLoadFailed). Both mean the
// provider-model pair will fail identically on immediate retry and should
// cool down in routing.
func isModelLoadFailure(loweredErr string) bool {
	return strings.Contains(loweredErr, "insufficient memory") ||
		strings.Contains(loweredErr, "model load failed")
}

func (s *Server) handleInferenceError(providerID string, provider *registry.Provider, msg *protocol.InferenceErrorMessage) {
	if provider == nil {
		s.logger.Warn("error from unregistered provider", "provider_id", providerID)
		return
	}
	pr := provider.RemovePending(msg.RequestID)
	// Clear any parked settlement record (consumer disconnected mid-stream).
	// Same object as a non-nil pr when the terminal raced the disconnect defer.
	parked := s.claimSettlement(msg.RequestID)
	if pr == nil {
		pr = parked
	}
	if pr == nil {
		s.logger.Warn("error for unknown request", "provider_id", providerID, "request_id", msg.RequestID)
		return
	}
	consumerGone := parked != nil

	// Record a job failure, but not for capacity rejections or consumer
	// cancellations — neither is a provider fault. Capacity = load shedding the
	// coordinator reroutes. Cancel (499 / "request cancelled") = the CONSUMER
	// disconnected; before the settlement holder these terminals died on
	// pr==nil with zero reputation effect, and the old fleet emits one for
	// every mid-stream disconnect — penalizing them would erode the whole
	// fleet's reputation for consumer behavior.
	loweredErr := strings.ToLower(msg.Error)
	capacityRejection := msg.StatusCode == http.StatusServiceUnavailable ||
		msg.StatusCode == http.StatusTooManyRequests ||
		strings.Contains(loweredErr, "token_budget_exhausted") ||
		strings.Contains(loweredErr, "insufficient memory")
	cancelTerminal := msg.StatusCode == 499 ||
		strings.Contains(loweredErr, "request cancelled")
	if !capacityRejection && !cancelTerminal {
		s.registry.RecordJobFailure(providerID)
	}

	// Cool down a load-rejecting pair so retries skip it (see
	// dispatchLoadCooldowns). Covers BOTH flavors: capacity rejects
	// ("insufficient memory", not a fault) and generic load failures ("model
	// load failed": bad weights/metallib/kernel — IS a fault, reputation hit
	// above stands). The cool-down matters most during an alias migration: a
	// build that verifies on disk but cannot GPU-load would otherwise keep
	// attracting 100% of the alias traffic as repeated 500s — cooling the pair
	// makes the desired build unroutable so alias resolution falls back to the
	// previous build.
	if isModelLoadFailure(loweredErr) {
		if s.registry.RecordDispatchLoadFailure(providerID, pr.Model) {
			s.logger.Warn("load-failure cool-down started",
				"provider_id", providerID,
				"model", pr.Model,
			)
			s.ddIncr("routing.load_failure_cooldowns", []string{"model:" + pr.Model})
		}
	}

	s.registry.SetProviderIdle(providerID)

	if consumerGone {
		// Consumer disconnected — no reader for the channels; settle by
		// refunding, OFF the read loop (a store Credit can block for seconds
		// under DB pressure, and blocking this loop stalls heartbeats and
		// challenge responses — the eviction-churn vector). Idempotent vs. the
		// settlement grace timer via FinalizeReservation.
		//
		// Deliberately NOT unconditional: during the dispatch retry window the
		// consumer handler keeps the base reservation alive for the next
		// attempt — refunding/finalizing it here would let a later successful
		// attempt settle against a dead reservation (served for free). Errors
		// with a live consumer are refunded by their channel readers (relay /
		// dispatch-exhaustion paths); the relay-return→park gap is swept by
		// the post-commit defer's last-chance refund in consumer.go.
		refundPr := pr
		refundID := msg.RequestID
		saferun.Go(s.logger, "api.refundAfterDisconnect", func() {
			s.refundReservedBalance(refundPr, "provider_error_after_disconnect:"+refundID)
		})
		return
	}

	pr.ErrorCh <- *msg
	close(pr.ChunkCh)
	close(pr.CompleteCh)
	close(pr.ErrorCh)

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
	//
	// v0.6.0: binaryHash is self-reported and demoted to drift telemetry (APNs
	// code-identity attestation is the real signal); this gate deroutes only when
	// enforcement is explicitly enabled (rollback). The attestation-validity and
	// key-binding checks above remain gated on policyConfigured and are unchanged.
	if s.binaryHashEnforce && policyConfigured {
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

	// MDM verification is NOT spawned here. It runs once per connection in
	// mdmVerificationLoop (started alongside challengeLoop in providerReadLoop),
	// which owns the initial verify + a bounded, push-budget-aware retry. Doing
	// it per-connection instead of per-registration-and-every-challenge is
	// security-equivalent (SIP/Secure Boot can't change without a reboot, which
	// drops the connection) and stops the APNs push throttling that stranded
	// providers at self_signed.
	if s.mdmClient != nil && result.SerialNumber == "" {
		s.logger.Warn("provider attestation has no serial number — cannot verify via MDM",
			"provider_id", providerID,
		)
	}
}

// mdmVerifyOutcome classifies the result of one MDM verification attempt so the
// per-connection mdmVerificationLoop can decide whether to retry.
type mdmVerifyOutcome int

const (
	mdmVerifyGranted   mdmVerifyOutcome = iota // hardware trust granted — stop
	mdmVerifyTransient                         // not-enrolled / not-found / timeout / error — retry
	mdmVerifyTerminal                          // posture mismatch (hard untrust) — stop
)

// verifyProviderViaMDM runs one MDM SecurityInfo verification attempt for a
// provider and, on success, upgrades it to hardware trust + records Apple Device
// Attestation. It records a bucketed MDMFailureReason on the provider and emits
// an outcome metric, then returns an outcome the per-connection loop uses to
// decide whether to retry. It NEVER marks a provider untrusted for a transient
// failure (not-enrolled / timeout) — only for a genuine posture mismatch.
func (s *Server) verifyProviderViaMDM(ctx context.Context, providerID string, provider *registry.Provider, attestResult attestation.VerificationResult) mdmVerifyOutcome {
	// Never let MDM promote a provider whose Secure Enclave attestation is not
	// valid. verifyProviderAttestation stores an AttestationResult even for an
	// invalid attestation (and, in Open Mode, leaves the provider connected), so
	// without this a later SecurityInfo success could grant hardware to a provider
	// whose SE attestation / encryption-key binding failed. result.Valid==true
	// implies both passed (verifyProviderAttestation returns early otherwise). The
	// per-connection loop also gates on this; this is the authoritative backstop.
	if !attestResult.Valid {
		s.logger.Warn("refusing MDM verification — SE attestation not valid",
			"provider_id", providerID, "serial_number", attestResult.SerialNumber)
		return mdmVerifyTransient
	}

	s.logger.Info("starting MDM verification",
		"provider_id", providerID,
		"serial_number", attestResult.SerialNumber,
	)

	mdmResult, err := s.mdmClient.VerifyProvider(
		ctx,
		attestResult.SerialNumber,
		attestResult.SIPEnabled,
		attestResult.SecureBootEnabled,
	)
	if err != nil {
		s.logger.Error("MDM verification error",
			"provider_id", providerID,
			"error", err,
		)
		provider.SetMDMFailureReason("error")
		s.ddIncr("mdm.verification", []string{"outcome:error"})
		return mdmVerifyTransient
	}

	if !mdmResult.DeviceEnrolled {
		// A MicroMDM lookup/transport failure (500, network error) also returns
		// DeviceEnrolled=false — but the device may well be enrolled; we just
		// couldn't ask. Bucket that as "error" (MDM-side outage) so the stuck-cohort
		// gauge doesn't point operators at provider enrollment during an MDM outage.
		// Otherwise distinguish "no record of this serial" (profile never installed /
		// check-in never reached the server) from "record exists but enrollment
		// didn't complete" — different provider-side fixes.
		reason := "found-not-enrolled"
		switch {
		case strings.Contains(mdmResult.Error, "lookup failed"):
			reason = "error"
		case strings.Contains(mdmResult.Error, "not found"):
			reason = "device-not-found"
		}
		s.logger.Warn("provider not MDM-verified — staying at self_signed trust",
			"provider_id", providerID,
			"serial_number", attestResult.SerialNumber,
			"reason", reason,
			"error", mdmResult.Error,
		)
		provider.SetMDMFailureReason(reason)
		s.ddIncr("mdm.verification", []string{"outcome:" + reason})
		return mdmVerifyTransient
	}

	if mdmResult.Error != "" {
		// Hard untrust ONLY for a genuine posture mismatch proven by a received
		// SecurityInfo response (SecurityMismatch). Everything else with a non-empty
		// error — a SecurityInfo timeout, a MicroMDM command-send/transport failure,
		// a decode error, or a context cancellation on disconnect — is a "could not
		// complete the check" condition: keep the provider at its current trust
		// level (self_signed) and let the loop retry. Treating a transient MicroMDM
		// API hiccup as a posture mismatch would wrongly hard-untrust an enrolled,
		// genuinely-secure box.
		if !mdmResult.SecurityMismatch {
			reason := "error"
			if strings.Contains(mdmResult.Error, "timeout") {
				reason = "securityinfo-timeout"
			}
			s.logger.Warn("MDM verification did not complete — staying at current trust level",
				"provider_id", providerID,
				"reason", reason,
				"error", mdmResult.Error,
			)
			provider.SetMDMFailureReason(reason)
			s.ddIncr("mdm.verification", []string{"outcome:" + reason})
			return mdmVerifyTransient
		}
		// A real posture mismatch (SIP disabled, Secure Boot not full, attestation
		// disagrees with MDM) IS evidence of a problem — hard untrust, no retry.
		s.logger.Warn("MDM verification failed — marking provider untrusted",
			"provider_id", providerID,
			"error", mdmResult.Error,
			"mdm_sip", mdmResult.MDMSIPEnabled,
			"mdm_secure_boot", mdmResult.MDMSecureBootFull,
			"sip_match", mdmResult.SIPMatch,
			"secure_boot_match", mdmResult.SecureBootMatch,
		)
		provider.SetMDMFailureReason("posture-mismatch")
		s.ddIncr("mdm.verification", []string{"outcome:posture-mismatch"})
		s.registry.MarkUntrusted(providerID)
		return mdmVerifyTerminal
	}

	// If the connection went away while we were waiting on SecurityInfo, do NOT
	// mutate/persist trust for a provider that is no longer here — the next
	// connection re-verifies from scratch (RestoreProviderState caps to
	// self_signed). Treat as transient; the loop's ctx.Done will end it.
	if ctx.Err() != nil {
		provider.SetMDMFailureReason("securityinfo-timeout")
		return mdmVerifyTransient
	}

	// MDM SecurityInfo verification passed — atomically upgrade to hardware trust,
	// but NOT while the provider is currently untrusted. A missed-challenge deroute
	// can race this in-flight MDM verify; granting would leave the registry in
	// hardware/untrusted (routing still rejects it on Status) while telling the
	// provider it is "online". The atomic check-and-grant closes the TOCTOU between
	// the status check and the trust write. Recovery from a transient untrust flows
	// through a passing SE challenge that restores Status, after which a later loop
	// iteration grants cleanly. (A hard untrust already stops the loop via
	// ChallengeShouldStop.)
	if !provider.GrantHardwareIfNotUntrusted() {
		s.ddIncr("mdm.verification", []string{"outcome:deferred-untrusted"})
		return mdmVerifyTransient
	}
	provider.SetMDMFailureReason("")
	s.sendTrustStatus(provider, registry.TrustHardware, "online", "MDM verification passed")
	s.ddIncr("mdm.verification", []string{"outcome:granted"})
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
	s.verifyAppleDeviceAttestation(ctx, providerID, provider, attestResult, mdmResult.UDID)
	return mdmVerifyGranted
}

// ApplyLateSecurityInfo retroactively upgrades a self_signed provider to hardware
// when its SecurityInfo arrives AFTER the synchronous verify timed out (slow APNs
// / Power Nap). It mirrors verifyProviderViaMDM's success path so the late path
// doesn't drift from it: confirm posture (SIP on + Secure Boot full), match the
// device by UDID, require a valid SE attestation, skip a provider that has since
// become untrusted (granting would leave hardware/untrusted), and on success grant
// hardware, clear the MDM failure reason, send a fresh hardware/online
// trust_status (so the provider's daemon + doctor stop reporting MDM-pending), and
// persist. Wired as the mdm.Client late-SecurityInfo callback.
func (s *Server) ApplyLateSecurityInfo(udid string, info *mdm.SecurityInfoResponse) {
	if s.mdmClient == nil || info == nil {
		return
	}
	// Posture must be good — a late response that reports SIP off / Secure Boot
	// not full is not a basis for promotion (and the sync path would have hard-
	// untrusted it; here we simply don't upgrade).
	if !info.SystemIntegrityProtectionEnabled || info.SecureBootLevel != "full" {
		return
	}
	// Collect self_signed, valid-attestation candidates under the lock, then do
	// MDM lookups outside it to avoid blocking heartbeats/routing.
	type candidate struct {
		provider *registry.Provider
		serial   string
	}
	var candidates []candidate
	s.registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		trust := p.TrustLevel
		valid := p.AttestationResult != nil && p.AttestationResult.Valid
		serial := ""
		if p.AttestationResult != nil {
			serial = p.AttestationResult.SerialNumber
		}
		p.Mu().Unlock()
		if trust == registry.TrustSelfSigned && valid && serial != "" {
			candidates = append(candidates, candidate{provider: p, serial: serial})
		}
	})
	for _, c := range candidates {
		dev, _ := s.mdmClient.LookupDevice(context.Background(), c.serial)
		if dev == nil || dev.UDID != udid {
			continue
		}
		// Atomically grant unless the provider became untrusted while the response
		// was in flight — granting then would leave hardware/untrusted (routing
		// rejects on Status) and falsely tell the provider it's online. The
		// check-and-grant is a single lock (closes the TOCTOU); recovery from a
		// transient untrust flows through a passing SE challenge. Mirrors
		// verifyProviderViaMDM.
		if !c.provider.GrantHardwareIfNotUntrusted() {
			continue
		}
		c.provider.SetMDMFailureReason("")
		// Notify the connection, exactly like the synchronous success path —
		// otherwise the daemon stays self_signed and doctor keeps warning
		// MDM-pending even though the coordinator now routes it as hardware.
		s.sendTrustStatus(c.provider, registry.TrustHardware, "online", "MDM verification passed (late SecurityInfo)")
		if s.metrics != nil {
			s.metrics.IncCounter("mdm_late_securityinfo_upgrade_total")
		}
		// Also emit on the shared Datadog grant-rate metric so the late path is
		// visible alongside synchronous grants (not just the in-process counter).
		s.ddIncr("mdm.verification", []string{"outcome:granted-late"})
		s.logger.Info("late SecurityInfo arrival — upgraded provider to hardware trust",
			"provider_id", c.provider.ID,
			"serial", c.serial,
			"udid", udid,
		)
		s.registry.PersistProvider(c.provider)
	}
}

// mdmVerificationLoop owns MDM SecurityInfo verification for one provider
// connection. It replaces the old model where verification ran at registration
// and then re-ran on every 5-minute challenge for self_signed providers — which
// fired an MDM/APNs push each time and got throttled by Apple, so the
// SecurityInfo checks timed out and stranded providers at self_signed.
//
// Why per-connection is sufficient (not weaker than polling): SIP and Secure
// Boot cannot change at runtime — both require a reboot into Recovery — and a
// reboot drops this WebSocket, which ends this loop and forces a fresh
// connection that re-verifies. So we don't need to re-poll; we only need the one
// check to LAND. The backoff below retries within the connection to survive APNs
// / Power-Nap delivery delays and to catch a provider that finishes enrollment
// mid-connection, while staying well under Apple's push budget.
//
// It stops as soon as hardware trust is earned (here or via ACME concurrently),
// on a terminal posture mismatch, or when the connection closes (ctx done).
func (s *Server) mdmVerificationLoop(ctx context.Context, providerID string, provider *registry.Provider) {
	if s.mdmClient == nil {
		return
	}
	provider.Mu().Lock()
	var result *attestation.VerificationResult
	if provider.AttestationResult != nil {
		r := *provider.AttestationResult
		result = &r
	}
	provider.Mu().Unlock()
	// Require a VALID Secure Enclave attestation before MDM can promote to
	// hardware. verifyProviderAttestation sets AttestationResult even when the SE
	// attestation is invalid (and, in Open Mode, leaves the provider connected),
	// so gating only on a serial would let a later MDM SecurityInfo success
	// promote a provider whose SE attestation / encryption-key binding FAILED.
	// result.Valid==true implies both the SE attestation and the X25519↔SE binding
	// passed (verifyProviderAttestation returns early otherwise).
	if result == nil || !result.Valid || result.SerialNumber == "" {
		return
	}

	// One attempt up front, then a gentle cadence. The initial push (with the
	// SecurityInfo waiter registered first) wakes an awake-or-reachable device and
	// usually lands; retries exist only for genuine APNs/Power-Nap delivery delay,
	// so they're spaced to stay within Apple's MDM push budget (the throttling this
	// change exists to avoid) while still catching a provider that finishes
	// enrollment later in the same connection.
	backoff := []time.Duration{2 * time.Minute, 6 * time.Minute}
	const steadyInterval = 15 * time.Minute

	for attempt := 0; ; attempt++ {
		// Stop if hardware was already earned — by this loop on a prior iteration,
		// or by the ACME leg (retryACMETrust) concurrently.
		if provider.GetTrustLevel() == registry.TrustHardware {
			return
		}
		// Stop if the provider was HARD-untrusted out-of-band (e.g. the challenge
		// loop saw SIP disabled or a binary-hash change). Re-granting hardware to a
		// hard-untrusted provider would leave TrustLevel=hardware while
		// Status=untrusted — an inconsistent state. A hard untrust recovers only by
		// reconnect, which restarts this loop. A *transient* untrust (missed-
		// challenge timeouts) is intentionally NOT a stop: it can recover on a later
		// passing challenge, after which MDM should still be able to grant hardware.
		if provider.ChallengeShouldStop() {
			return
		}
		switch s.verifyProviderViaMDM(ctx, providerID, provider, *result) {
		case mdmVerifyGranted, mdmVerifyTerminal:
			return
		}
		// Transient (not-enrolled / not-found / timeout / error) — schedule retry.
		d := steadyInterval
		if attempt < len(backoff) {
			d = backoff[attempt]
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(d):
		}
	}
}

// verifyAppleDeviceAttestation sends a DeviceInformation command requesting
// DevicePropertiesAttestation and verifies the Apple-signed certificate chain.
func (s *Server) verifyAppleDeviceAttestation(ctx context.Context, providerID string, provider *registry.Provider, attestResult attestation.VerificationResult, udid string) {
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
	_, err := s.mdmClient.SendDeviceAttestationCommand(ctx, udid, seKeyNonce)
	if err != nil {
		s.logger.Warn("failed to send DeviceInformation attestation command",
			"provider_id", providerID,
			"error", err,
		)
		return
	}

	// Wait for Apple's response (device contacts Apple's servers — may take longer)
	attestResp, err := s.mdmClient.WaitForDeviceAttestation(ctx, udid, 60*time.Second)
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
		// p.Models is replaced copy-on-write by UpdateModelWeightHashes on the
		// challenge goroutine, so its slice header must be read under p.mu. Copy
		// the IDs out within this same locked section rather than ranging the
		// field after unlock.
		modelIDs := make([]string, 0, len(p.Models))
		for _, m := range p.Models {
			modelIDs = append(modelIDs, m.ID)
		}
		p.Mu().Unlock()

		// The public proofs (mdm/mda/acme) are reported true ONLY for a connection
		// that currently holds hardware trust. A hardware proof is meaningful for
		// the connection that earned it live; surfacing mda_verified/acme_verified
		// on a self_signed connection (e.g. a stored flag, an early-set ACME flag
		// before binding, or a late-arriving MDA webhook) is the misleading
		// "mda_verified=true while self_signed" drift. Gating all three on the
		// live trust level keeps the endpoint internally consistent.
		isHardware := trustLevel == registry.TrustHardware
		pa := providerAttestation{
			ProviderID:   p.ID,
			TrustLevel:   string(trustLevel),
			Status:       string(status),
			MemoryGB:     p.Hardware.MemoryGB,
			GPUCores:     p.Hardware.GPUCores,
			MDMVerified:  isHardware,
			MDAVerified:  mdaVerified && isHardware,
			ACMEVerified: acmeVerified && isHardware,
		}

		pa.Models = append(pa.Models, modelIDs...)

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

		// Include the MDA cert chain + parsed fields for independent verification
		// ONLY for a connection currently holding hardware trust — same gate as the
		// mda_verified boolean above. The late-MDA callback (main.go) can attach a
		// cert chain to a provider that has since reconnected as self_signed; without
		// this gate the endpoint would emit mda_verified=false alongside a non-empty
		// mda_cert_chain_b64/serial/udid, which is exactly the drift this fix removes.
		if isHardware {
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
