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
	"math"

	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

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

	// Run the read loop; on return the provider is disconnected.
	s.providerReadLoop(r.Context(), conn, providerID, r)
}

// sessionDisconnectReason maps a provider read-loop exit to the disconnect
// reason recorded on its provider_sessions row. Kept to a small, fixed
// vocabulary so the column stays aggregatable:
//   - "oom_suspected"   — abrupt drop under memory pressure with in-flight work
//     (same classification as the provider.oom_suspected metric);
//   - "ws_close_<code>" — the peer sent a WebSocket close frame (1000 = normal
//     shutdown, 1001 = going away, 1006/close codes from intermediaries, ...);
//   - "read_error"      — the socket died without a close frame (TCP reset,
//     NAT/LB teardown, machine went to sleep mid-write).
//
// The registry's own generic "disconnect" remains the reason for closes the
// read loop did NOT observe first — in practice the stale-eviction sweep —
// so post-fix, lingering "disconnect" rows ≈ silent drops reaped by eviction.
func sessionDisconnectReason(closeStatus websocket.StatusCode, oomSuspected bool) string {
	switch {
	case oomSuspected:
		return string(registry.DisconnectReasonOOMSuspected)
	case closeStatus != -1:
		return "ws_close_" + strconv.Itoa(int(closeStatus))
	default:
		return "read_error"
	}
}

// closeSessionWithReason closes this connection's provider_sessions row with a
// specific disconnect reason. Synchronous with a short timeout: it must land
// before the deferred registry.Disconnect issues its generic "disconnect"
// close (first close wins in the store), and a bounded wait means a stalled DB
// delays only this connection's teardown by at most the timeout — the store's
// upsert semantics make the registry's later write a safe fallback if this one
// times out. The caller marks the provider StatusOffline before calling, so
// the wait is never routing-critical: the dead provider cannot be selected
// while the write is in flight.
func (s *Server) closeSessionWithReason(providerID, reason string) {
	if s.store == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := s.store.CloseProviderSession(ctx, providerID, reason, time.Now()); err != nil {
		s.logger.Warn("failed to close provider session with reason",
			"provider_id", providerID, "reason", reason, "error", err)
	}
}

// providerReadLoop reads messages from the provider WebSocket and dispatches
// them. It runs until the connection closes or the context is cancelled.
func (s *Server) providerReadLoop(ctx context.Context, conn *websocket.Conn, providerID string, r *http.Request) {
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
			closeStatus := websocket.CloseStatus(err)
			oomSuspected := false
			if closeStatus != -1 {
				s.logger.Info("provider websocket closed",
					"provider_id", providerID, "close_code", int(closeStatus))
				// Peer-initiated closes were previously unmetered — only
				// read_error incremented ws_disconnects_total — so dashboards
				// could not split graceful closes (update/shutdown) from drops.
				if s.metrics != nil {
					s.metrics.IncCounter("ws_disconnects_total",
						MetricLabel{"reason", "peer_close"},
					)
				}
				s.ddIncr("ws.disconnects", []string{
					"reason:peer_close",
					"code:" + strconv.Itoa(int(closeStatus)),
				})
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
						oomSuspected = true
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

			// Stamp this connection's session row with the observed socket
			// outcome. Every registry.Disconnect path writes the catch-all
			// "disconnect", which made 97% of provider_sessions rows carry a
			// single indistinguishable reason (2026-07-03 churn analysis). The
			// stamp is written synchronously BEFORE the deferred
			// registry.Disconnect so the store's first-close-wins semantics keep
			// the specific reason; the registry's later generic close becomes a
			// no-op. Skipped when:
			//   - provider == nil: never registered, so no session row exists
			//     (writing would fabricate a zero-duration row);
			//   - ctx.Err() != nil: coordinator shutdown — the next instance's
			//     startup reconcile labels these "coordinator_restart";
			//   - the registry no longer has the provider: registry.Disconnect
			//     already ran (stale eviction, duplicate-serial kick) and owns
			//     the reason for that path.
			if provider != nil && ctx.Err() == nil && s.registry.GetProvider(providerID) != nil {
				// The socket is dead, but the deferred registry.Disconnect
				// only runs after the stamp lands (first close wins requires
				// that order). Flip the provider offline first — StatusOffline
				// fails every routing-eligibility gate — so a slow store write
				// can never leave a dead provider selectable. Untrusted stays
				// untrusted: it is equally unroutable, and overwriting it would
				// make Disconnect's status-gated online/model decrements run a
				// second time after markUntrusted already decremented.
				provider.Mu().Lock()
				if provider.Status != registry.StatusUntrusted {
					provider.Status = registry.StatusOffline
				}
				provider.Mu().Unlock()
				s.closeSessionWithReason(providerID, sessionDisconnectReason(closeStatus, oomSuspected))
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
			if err := s.registry.ValidatePrefixCacheRegistration(regMsg); err != nil {
				s.logger.Warn("rejecting malformed provider cache capabilities",
					"provider_id", providerID, "error", err)
				s.ddIncr("routing.cache_capability_rejected", []string{"source:register"})
				_ = conn.Close(websocket.StatusPolicyViolation, "invalid prefix-cache capabilities")
				return
			}
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
					// Account linkage can be the provider's ONLY stable identity
					// (Open Mode / invalid attestation → the acct: fallback), and
					// it lands after the attestation-time bind — re-bind so fault
					// state keys by identity instead of the session UUID.
					provider.RebindStableFaultKey()
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
						if err := provider.EnqueueText(loopCtx, statusData); err != nil {
							s.logger.Debug("failed to enqueue runtime status to provider", "provider_id", provider.ID, "error", err)
							s.ddIncr("provider.enqueue_failed", []string{"msg:runtime_status"})
						}
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
				s.challengeLoop(loopCtx, providerID, provider, tracker)
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
			replaceCacheCapabilities :=
				hbMsg.PrefixCacheProtocol != 0 || hbMsg.PrefixCacheV2Models != nil
			if replaceCacheCapabilities ||
				hbMsg.PrefixCacheStatuses != nil ||
				hbMsg.PrefixCacheDonationOutcomes != nil {
				var capabilities []protocol.PrefixCacheV2Capability
				if hbMsg.PrefixCacheV2Models != nil {
					capabilities = *hbMsg.PrefixCacheV2Models
				}
				_, err := s.registry.UpdatePrefixCacheSnapshot(
					providerID,
					replaceCacheCapabilities,
					hbMsg.PrefixCacheProtocol,
					capabilities,
					hbMsg.PrefixCacheStatuses,
					hbMsg.PrefixCacheDonationOutcomes,
				)
				if err != nil && replaceCacheCapabilities {
					s.logger.Warn("rejecting malformed heartbeat cache capabilities",
						"provider_id", providerID, "error", err)
					s.ddIncr("routing.cache_capability_rejected", []string{"source:heartbeat"})
					// Malformed refreshes cannot leave stale v2 evidence live.
					_, _ = s.registry.UpdatePrefixCacheSnapshot(
						providerID,
						true,
						1,
						nil,
						hbMsg.PrefixCacheStatuses,
						hbMsg.PrefixCacheDonationOutcomes,
					)
				} else if err != nil {
					s.logger.Warn("failed to apply heartbeat cache telemetry",
						"provider_id", providerID, "error", err)
					s.ddIncr("routing.cache_telemetry_rejected", []string{"source:heartbeat"})
				}
			}
			s.registry.Heartbeat(providerID, hbMsg)
			// First-token-wedge observability (measurement only): surface the
			// provider-reported engine-health signal as a Datadog counter so a
			// wedged box is visible fleet-wide straight from heartbeats.
			s.recordBackendWedgeTelemetry(hbMsg)
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

		case protocol.TypePrefixCacheLookup:
			lookupMsg := msg.Payload.(*protocol.PrefixCacheLookupMessage)
			if s.registry.ApplyPrefixCacheLookup(providerID, lookupMsg) {
				s.ddIncr("routing.cache_lookup_receipt", []string{"outcome:" + lookupMsg.Outcome, "tier:" + lowCardinalityCacheTier(lookupMsg.Tier)})
				s.emitExactCacheSSDLookup("v1", lookupMsg.Outcome, lookupMsg.StageMs)
			} else {
				s.ddIncr("routing.cache_receipt_rejected", []string{"type:lookup"})
			}

		case protocol.TypePrefixCacheReady:
			readyMsg := msg.Payload.(*protocol.PrefixCacheReadyMessage)
			if s.registry.ApplyPrefixCacheReady(providerID, readyMsg) {
				s.ddIncr("routing.cache_ready_receipt", []string{"tier:" + lowCardinalityCacheTier(readyMsg.Tier)})
				s.emitExactCacheSSDDonation("v1", readyMsg.StageMs, readyMsg.ReadyTokens)
			} else {
				s.ddIncr("routing.cache_receipt_rejected", []string{"type:ready"})
			}

		case protocol.TypePrefixCacheLookupV2:
			lookupMsg := msg.Payload.(*protocol.PrefixCacheLookupV2Message)
			if s.registry.ApplyPrefixCacheLookupV2(providerID, lookupMsg) {
				s.ddIncr("routing.cache_lookup_receipt", []string{
					"protocol:v2",
					"outcome:" + lookupMsg.Outcome,
					"tier:" + lowCardinalityCacheTier(lookupMsg.Tier),
				})
				s.emitExactCacheSSDLookup("v2", lookupMsg.Outcome, lookupMsg.StageMs)
			} else {
				s.ddIncr("routing.cache_receipt_rejected", []string{"type:lookup_v2"})
			}

		case protocol.TypePrefixCacheReadyV2:
			readyMsg := msg.Payload.(*protocol.PrefixCacheReadyV2Message)
			if s.registry.ApplyPrefixCacheReadyV2(providerID, readyMsg) {
				s.ddIncr("routing.cache_ready_receipt", []string{
					"protocol:v2",
					"tier:" + lowCardinalityCacheTier(readyMsg.Tier),
				})
				donatedTokens := 0
				if len(readyMsg.ReadyAnchors) > 0 {
					donatedTokens = readyMsg.ReadyAnchors[len(readyMsg.ReadyAnchors)-1].TokenCount
				}
				s.emitExactCacheSSDDonation("v2", readyMsg.StageMs, donatedTokens)
			} else {
				s.ddIncr("routing.cache_receipt_rejected", []string{"type:ready_v2"})
			}

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
				// Quantify WHY proactive loads are rejected. The reason
				// is derived only from the existing error string (no new wire
				// field). The proactive path's string is often a generic
				// Foundation bridge ("other"), but dashboards still get the
				// draining vs descriptive classes, and the short backoff below
				// does NOT depend on this classification.
				reason := classifyLoadFailure(statusMsg.Error)
				s.ddIncr("routing.load_model_rejects", []string{
					"model:" + statusMsg.ModelID,
					"reason:" + reason,
				})
				switch {
				case statusMsg.Error == protocol.ProviderDrainingForUpdate:
					// Transient: the provider refused only because it is
					// draining ahead of an auto-update restart. Shorten the
					// cooldown so a failed restart (provider resumes serving)
					// becomes loadable again quickly; queued requests are NOT
					// rejected — the provider is back within the queue window
					// and other providers remain plannable.
					s.registry.BackoffPendingModelLoadForDrain(providerID, statusMsg.ModelID)
					s.ddIncr("routing.pending_load_backoff", []string{
						"model:" + statusMsg.ModelID, "kind:drain",
					})
				case loadFailureIsPermanent(reason):
					// Permanent: the provider does not have this model, so a
					// fast retry just re-fails. Keep the full TTL cooldown set
					// when the load was planned (do NOT apply the short memory
					// backoff) so TriggerModelSwaps does not re-attempt the
					// unservable load every ~30s within the 120s queue window.
					// Still reject queued waiters that nothing can serve.
					s.registry.RejectUnservableQueuedRequests(statusMsg.ModelID)
				default:
					// A non-draining, non-permanent load failure is dominated by
					// transient memory pressure that frees in seconds. Re-stamp
					// the pending entry to the short memory backoff (~30s)
					// instead of leaving the full 2-min TTL — that window ≈ the
					// 120s queue timeout, so a request queued right after the
					// failure would time out before this provider (whose memory
					// may already have freed) is reconsidered by
					// TriggerModelSwaps. The ~10s warm-pool sweep reaps the short
					// entry deterministically.
					s.registry.BackoffPendingModelLoadForMemory(providerID, statusMsg.ModelID)
					s.ddIncr("routing.pending_load_backoff", []string{
						"model:" + statusMsg.ModelID, "kind:memory",
					})
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

func cacheSelectionTerminalTags(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid, usagePresent bool) []string {
	mode := "none"
	if pr != nil && pr.CacheSelectionMode == "active" {
		mode = pr.CacheSelectionMode
	}
	result := "unreported"
	lookupOutcome := "unreported"
	read := false
	if usagePresent && !usageValid {
		result = "invalid"
		lookupOutcome = "invalid"
	} else if usageValid {
		lookupOutcome = usage.CacheOutcome
		if usage.CacheOutcome == "hit" {
			result = "hit"
			read = true
		} else {
			result = "non_hit"
		}
	}
	tier := "none"
	selected := false
	if pr != nil {
		tier = lowCardinalityCacheTier(pr.CacheSelectionTier)
		selected = pr.CacheSelectionSelected
	}
	return []string{
		"mode:" + mode,
		"tier:" + tier,
		"selected:" + strconv.FormatBool(selected),
		"result:" + result,
		"lookup_outcome:" + lookupOutcome,
		"cache_read:" + strconv.FormatBool(read),
	}
}

func (s *Server) emitCacheSelectionTerminal(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid, usagePresent bool) bool {
	if pr == nil || !pr.CacheRoutingTelemetryEligible() {
		return false
	}
	if !pr.MarkCacheTerminalTelemetryEmitted() {
		return false
	}
	tags := cacheSelectionTerminalTags(pr, usage, usageValid, usagePresent)
	s.ddIncr("routing.cache_selection_terminal", tags)
	if pr.CacheSelectionDiscountMs > 0 {
		s.ddHistogram("routing.cache_selection_discount_ms", pr.CacheSelectionDiscountMs, tags)
		if pr.CacheSelectionMode == "active" && pr.CacheSelectionSelected {
			s.ddIncr("routing.cache_selection_precision", tags)
		}
	}
	s.emitExactCacheEstimatedTTFTSaved(pr, tags)
	return true
}

func cacheSelectionTTFTSample(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid bool, actualTTFTMs float64) (float64, []string, bool) {
	if pr == nil || !usageValid || actualTTFTMs <= 0 || math.IsNaN(actualTTFTMs) || math.IsInf(actualTTFTMs, 0) {
		return 0, nil, false
	}
	if pr.CacheSelectionMode != "active" {
		return 0, nil, false
	}
	return actualTTFTMs, cacheSelectionTerminalTags(pr, usage, true, true), true
}

func (s *Server) emitCacheSelectionTTFT(pr *registry.PendingRequest, usage protocol.UsageInfo, usageValid bool, actualTTFTMs float64) {
	value, tags, ok := cacheSelectionTTFTSample(pr, usage, usageValid, actualTTFTMs)
	if !ok {
		return
	}
	s.ddHistogram("routing.cache_selection_ttft_ms", value, tags)
}

// CodeAttestResponseTimeout bounds how long the coordinator will accept a
// provider's WebSocket reply to an APNs code-identity challenge after the push.
// It is no longer a blocking wait (Fix 1): verification happens in the read-loop
// delivery path (handleCodeAttestationResponse), so this is the acceptance window
// for the pushed nonce. Kept consistent with the APNs apns-expiration window
// (apns.challengeExpirySeconds, Fix 5) — a reply is honored for as long as the
// push could still be delivered. It seeds codeAttestThrottle.challengeValidity.
const CodeAttestResponseTimeout = 300 * time.Second

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
	merged, dropped := s.registry.MergeProviderModelsWithCapabilities(
		providerID,
		msg.Models,
		msg.ToolConstraintProtocol,
		msg.ToolConstraintModels,
	)
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

// challengeLoop periodically sends attestation challenges to a provider.
func (s *Server) challengeLoop(ctx context.Context, providerID string, provider *registry.Provider, tracker *challengeTracker) {
	if s.skipChallenge {
		return
	}

	interval := s.challengeInterval
	if interval == 0 {
		interval = DefaultChallengeInterval
	}

	// Send initial challenge immediately so the provider is routable
	// without waiting for the first ticker interval.
	s.sendChallenge(ctx, providerID, provider, tracker)

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
			s.sendChallenge(ctx, providerID, provider, tracker)
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
func (s *Server) sendChallenge(ctx context.Context, providerID string, provider *registry.Provider, tracker *challengeTracker) {
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
	// Control lane: a challenge must not queue behind multi-MiB inference
	// frames — a congested data lane would turn transport backpressure into
	// "attestation timeout" reputation events.
	if err := provider.WriteTextControl(writeCtx, data); err != nil {
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
			s.handleTransientChallengeFailure(provider.Conn, providerID, "no response")
			return
		}
		s.verifyChallengeResponse(providerID, provider, pc, resp)
	case <-time.After(timeout):
		tracker.remove(nonce)
		s.handleTransientChallengeFailure(provider.Conn, providerID, "timeout")
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
			Nonce:     pc.nonce,
			Timestamp: pc.timestamp,
			// Legacy fleet compat only: old providers (< v0.6.31) sign
			// hypervisor_active into the canonical status, so it must be
			// carried into the reconstruction when reported. New providers
			// omit it (nil). See attestation.StatusCanonicalInput.
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
	// discipline.
	if resp.RDMADisabled == nil {
		s.handleChallengeFailure(providerID, "RDMA status not reported — provider must update to v0.2.0+")
		return
	}
	if !*resp.RDMADisabled {
		s.logger.Info("provider RDMA enabled — accepting under registered-buffer RDMA policy",
			"provider_id", providerID,
			"backend", provider.Backend,
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
					if err := provider.EnqueueText(context.Background(), statusData); err != nil {
						s.logger.Debug("failed to enqueue runtime status to provider", "provider_id", provider.ID, "error", err)
						s.ddIncr("provider.enqueue_failed", []string{"msg:runtime_status"})
					}
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

	// Override the self-reported SIP capability with the coordinator-verified
	// value from the challenge response. The coordinator independently checks
	// SIP during each attestation challenge.
	provider.Mu().Lock()
	if provider.PrivacyCapabilities != nil {
		if resp.SIPEnabled != nil {
			provider.PrivacyCapabilities.SIPEnabled = *resp.SIPEnabled
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

	if trustLevel == registry.TrustSelfSigned {
		// DAR-326 Phase 0: trust-reuse fast-skip. The live SE challenge above just
		// re-proved this connection's identity + posture. If this device recently
		// passed a FULL live MDM verification (a fresh trust-reuse record) and the
		// fresh SIGNED challenge re-proves the SAME identity, an unchanged binary,
		// and good posture within the window, grant hardware now — letting the
		// per-connection mdmVerificationLoop SKIP its live MDM SecurityInfo
		// round-trip. This is what avoids a fleet-wide MDM/APNs herd on a planned
		// coordinator restart/swap. SECURITY: the live SE challenge always ran
		// first; any gate miss (no record, binary changed, posture bad/unsigned,
		// window elapsed, hard-untrusted) returns false and falls through to the
		// unchanged full live MDM verify.
		if s.tryTrustReuseFastSkip(providerID, provider, resp, statusFieldsTrusted) {
			// The fast-skip granted hardware WITHOUT running the full live MDM verify,
			// so verifyAppleDeviceAttestation never ran on this connection. Reuse the
			// durable MDA proof (re-verified locally against Apple's root + re-bound to
			// this SE key) so a restart keeps mda_verified green with zero MDM/APNs
			// traffic — the whole point of the fast-skip is to avoid that round-trip.
			if ar := provider.GetAttestationResult(); ar != nil {
				s.attachCachedMDAProof(providerID, provider, *ar)
			}
			// DAR-326 FIX 3: the fast-skip just granted hardware, so this provider is
			// freshly routable — drain any queued requests now instead of waiting for
			// the next heartbeat / 120s queue timeout. Off the challenge goroutine,
			// mirroring the code-attest / MDM hardware-grant drain.
			saferun.Go(s.logger, "trustReuseDrain", func() {
				s.registry.DrainQueuedRequestsForProvider(provider)
			})
		} else {
			// Fast-skip missed. Nudge the mdmVerificationLoop
			// (SignalChallengeSettled, so it stops deferring and runs the live
			// verify) — hardware trust is earned via MDM SecurityInfo.
			provider.SignalChallengeSettled()
		}
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
	chunkData, err := s.decryptTextResponseChunk(provider, pr, msg)
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
	// Fast path: non-blocking send — this is the provider's single read
	// goroutine, so it must not stall behind one slow consumer. A full channel
	// means the consumer is ≥256 chunks behind; silently dropping the chunk
	// (the old behavior) would deliver a corrupted stream with missing tokens
	// that is still billed. Instead, give a healthy-but-bursty consumer a
	// bounded grace window to free one slot (sendChunkWithGrace), and only
	// then fail the request: cancel the provider's generation and surface a
	// terminal error to the consumer goroutine.
	select {
	case pr.ChunkCh <- chunkData:
	default:
		if sendChunkWithGrace(pr, chunkData) {
			return
		}
		s.logger.Error("chunk buffer overflow — failing request instead of corrupting stream",
			"provider_id", providerID,
			"request_id", msg.RequestID,
		)
		s.ddIncr("inference.chunk_overflow_abort", []string{})
		s.sendProviderCancel(provider, msg.RequestID)
		// 499 + "request cancelled" classifies as a consumer-side terminal in
		// handleInferenceError: no provider reputation hit for our backpressure.
		s.handleInferenceError(providerID, provider, &protocol.InferenceErrorMessage{
			Type:       protocol.TypeInferenceError,
			RequestID:  msg.RequestID,
			Error:      "request cancelled: consumer stream stalled (chunk buffer overflow)",
			StatusCode: 499,
		})
	}
}

// chunkOverflowGrace is how long handleChunk will block the provider read loop
// waiting for a full ChunkCh to free one slot before failing the request. It
// trades a bounded head-of-line stall for this provider's OTHER streams
// against killing a healthy consumer that is merely catching up after a TCP
// burst (WS stall recovery, engine batch flush, slow mobile links). A stuck
// consumer costs one grace window and is then failed; a consumer that drains
// at least one chunk per window keeps its stream alive.
const chunkOverflowGrace = 250 * time.Millisecond

// sendChunkWithGrace blocks up to chunkOverflowGrace for a slot on pr.ChunkCh
// and reports whether the chunk was delivered. The recover guard mirrors
// registry.Disconnect's own channel idiom: Disconnect can close ChunkCh from
// another goroutine while we are blocked in the send, and a closed channel
// here simply means the request is already torn down (delivered=false; the
// caller's terminal path degrades to a no-op warn).
func sendChunkWithGrace(pr *registry.PendingRequest, chunk string) (delivered bool) {
	defer func() {
		if recover() != nil {
			delivered = false
		}
	}()
	wait := time.NewTimer(chunkOverflowGrace)
	defer wait.Stop()
	select {
	case pr.ChunkCh <- chunk:
		return true
	case <-wait.C:
		return false
	}
}

func (s *Server) decryptTextResponseChunk(provider *registry.Provider, pr *registry.PendingRequest, msg *protocol.InferenceResponseChunkMessage) (string, error) {
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
	// The X25519 shared key is derived once per request and memoized; the
	// per-chunk cost is a single symmetric open. The sender-key check above
	// guarantees the cached key matches this chunk's ephemeral key.
	shared, err := s.chunkKeys.sharedKey(pr.SessionPrivKey, provider.PublicKey)
	if err != nil {
		return "", err
	}
	plaintext, err := e2e.DecryptWithSharedKey(payload, shared)
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
	// The request is terminal — drop its memoized chunk-decryption key.
	s.chunkKeys.forget(pr.SessionPrivKey)
	// A parked record means the consumer handler already returned: there is no
	// channel reader, and registry.Disconnect may have already CLOSED the
	// channels (park-before-remove leaves a window where the record is in both
	// the pending map and the holder) — sending would panic. Billing still
	// settles below; only the consumer signaling is skipped.
	consumerGone := parked != nil
	// After-commit client cancellation telemetry. The provider finished
	// but the consumer had already disconnected mid-stream (partial_success /
	// client_gone_after_commit). Metric-emit only — billing/settlement below is
	// unchanged.
	if consumerGone {
		s.emitClientGone(pr.Model, pr.EstimatedPromptTokens, providerChipFamily(provider), phaseAfterCommit)
		// A parked (after-commit client-gone) completion is still a SERVED
		// provider dispatch, so it owes its one capacity-503 rate-window outcome
		// (capacity_rate.go denominator). On the clean-completion path
		// noteInferenceSuccess re-offers it, but that never runs here — the
		// consumer handler already returned. Re-offer it now, keyed on the
		// recorded outcome exactly as noteInferenceSuccess does. Commit-time
		// accepts are retained even before the first reject; a commit that already
		// recorded passes countRateOutcome=false and cannot double-count. A path
		// without a recorded commit contributes its sole outcome here. Uses
		// pr.ProviderID (the committed attempt's provider) to match the commit key.
		s.registry.RecordCapacityAcceptOutcome(pr.ProviderID, pr.Model, !pr.RateOutcomeCountedSafe())
	}

	// Store SE signature for the consumer response headers.
	pr.SESignature = msg.SESignature
	pr.ResponseHash = msg.ResponseHash
	pr.MatchedStopSequence = allowedMatchedStopSequence(
		pr.RequestedStopSequences, msg.StopSequence)
	if msg.StopSequence != "" && pr.MatchedStopSequence == "" {
		s.logger.Warn("provider reported an unrequested stop sequence",
			"provider_id", providerID,
			"request_id", msg.RequestID,
		)
		s.ddIncr("inference.invalid_stop_sequence", nil)
	}

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
	cacheUsagePresent := hasCacheUsage(msg.Usage)
	cacheUsageValid := validCacheUsage(msg.Usage)
	if cacheUsagePresent && !cacheUsageValid {
		s.ddIncr("routing.cache_usage_rejected", nil)
		clearCacheUsage(&msg.Usage)
	}
	if cacheUsageValid {
		tags := []string{"outcome:" + msg.Usage.CacheOutcome, "tier:" + lowCardinalityCacheTier(msg.Usage.CacheTier)}
		s.ddIncr("routing.cache_usage", tags)
		s.ddCount("routing.cache_tokens", int64(msg.Usage.CachedTokens), tags)
		s.ddCount("routing.cache_prefill_tokens_saved", int64(msg.Usage.PrefillTokensSaved), tags)
		s.ddHistogram("routing.cache_stage_ms", msg.Usage.CacheStageMs, tags)
		s.emitExactCacheUsage(msg.Usage.CacheOutcome, lowCardinalityCacheTier(msg.Usage.CacheTier),
			msg.Usage.CachedTokens, msg.Usage.PrefillTokensSaved, msg.Usage.CacheStageMs)
	}
	cacheTerminalClaimed := s.emitCacheSelectionTerminal(pr, msg.Usage, cacheUsageValid, cacheUsagePresent)
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
			// Financial: a failed refund over-charges the consumer. Never swallow it.
			if err := s.store.Credit(pr.ConsumerKey, refund, store.LedgerRefund, msg.RequestID); err != nil {
				s.logger.Error("failed to credit settlement refund to consumer",
					"request_id", msg.RequestID, "refund_micro_usd", refund, "error", err)
				s.ddIncr("billing.credit_failed", []string{"op:settlement_refund"})
			}
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

		// Fallback actual_ttft_ms anchor for the COMMITTED attempt only. The
		// dispatch/handler goroutine normally stamps FirstContentAt at the
		// content-commit site (commitFirstContent / the generic stamp); this
		// fallback covers the fast single-chunk case where TypeInferenceComplete
		// reaches this provider read-loop goroutine before that stamp runs. It is
		// gated on ContentCommittedSafe so it ONLY ever stamps for the attempt that
		// actually committed content: an abandoned/retried attempt that completes
		// late (it never committed) must NOT stamp the SHARED Timing, or its stale
		// timestamp would clamp/zero the real committed retry's actual_ttft_ms
		// (FirstContentAt is first-write-wins). MarkFirstContentArrived is
		// idempotent, so for the committed attempt this is a no-op when the
		// dispatch goroutine already stamped.
		if pr.ContentCommittedSafe() && msg.Usage.CompletionTokens > 0 {
			pr.MarkFirstContentArrived()
		}

		// Update the routing telemetry outcome with final token counts and timing.
		// handleComplete is the authoritative final writer for provider completion;
		// when the consumer already disconnected this is a partial success because
		// the provider completed and billing settled, but the client did not receive
		// the full response.
		outcome := completeRouteOutcome(pr, msg.Usage, totalCost, consumerGone)
		// Join only after both inputs are authoritative: cacheUsageValid was
		// established from the terminal usage above, and completeRouteOutcome read
		// the committed attempt's mutex-guarded first-content timestamp after the
		// fallback stamp. No request, provider, route, or scope identifier is tagged.
		if cacheTerminalClaimed {
			s.emitCacheSelectionTTFT(pr, msg.Usage, cacheUsageValid, outcome.ActualTTFTMs)
		}
		if pr.Timing != nil {
			// completeRouteOutcome already applied the per-attempt timing via
			// applyPendingRouteTelemetry — actual_ttft_ms (from FirstContentAt),
			// dispatch_to_first_chunk_ms (from FirstChunkAt), total_duration_ms,
			// and the ParseMs..DispatchMs decomposition — all using the
			// mutex-guarded timing accessors, which are race-free on this provider
			// read-loop goroutine. This block only ADDS the measured decode
			// throughput, which needs FirstChunkAt read via the same guarded
			// accessor.
			firstChunk := pr.FirstChunkAtSafe()
			// Measured decode throughput: completion tokens over the decode
			// window (first chunk -> completion). Guard zero/negative durations
			// and zero tokens so unmeasurable requests record 0.
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
		s.updateInferenceRouteOutcomeWithModel(msg.RequestID, pr.Attempt, pr.Model, outcome)

		s.ddIncr("inference.completions", []string{"model:" + pr.Model})
		// Split the partial case out of the (intentionally unchanged) completions
		// counter: the provider completed and billing settled, but the consumer had
		// already disconnected after commit. Same money path as a clean success, so
		// it is NOT a provider failure — but operationally distinct, and invisible on
		// dashboards without its own counter.
		if consumerGone {
			s.recordPartialSuccessCompletion(pr.Model, errorClassClientGoneAfterCommitCompleted)
		}
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
				// Financial: a failed platform-fee credit drops revenue accounting. Never swallow it.
				if err := s.store.Credit("platform", platformFee, store.LedgerPlatformFee, msg.RequestID); err != nil {
					s.logger.Error("failed to credit platform fee",
						"request_id", msg.RequestID, "platform_fee_micro_usd", platformFee, "error", err)
					s.ddIncr("billing.credit_failed", []string{"op:platform_fee"})
				}
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
	// The request is terminal — drop its memoized chunk-decryption key.
	s.chunkKeys.forget(pr.SessionPrivKey)
	consumerGone := parked != nil
	// Provider errors carry no validated cache usage, but still close the
	// selection/outcome correlation denominator as an unreported result.
	s.emitCacheSelectionTerminal(pr, protocol.UsageInfo{}, false, false)

	// Record a job failure, but not for capacity rejections or consumer
	// cancellations — neither is a provider fault. Capacity = load shedding the
	// coordinator reroutes. Cancel (499 / "request cancelled") = the CONSUMER
	// disconnected; before the settlement holder these terminals died on
	// pr==nil with zero reputation effect, and the old fleet emits one for
	// every mid-stream disconnect — penalizing them would erode the whole
	// fleet's reputation for consumer behavior.
	//
	// A structured NON-provider-fault error_reason is exempt too
	// (isNonProviderFaultErrorReason): jinja_* template-render failures (E4 —
	// the model's chat template could not render the REQUEST's tool schemas
	// or message history, a request-shape fault that fails identically on
	// every provider; prod: jinja requests averaged 1.57 dispatch rows, each
	// one erasing reputation fleet-wide for a body the provider never
	// controlled) and tool_noncompliance (E5 — the MODEL's sampled output
	// broke a forced tool_choice contract; the 422 stays on the bounded
	// failover path precisely because a re-sample can comply, so each
	// attempted provider must not eat a reputation strike for what the model
	// generated). A plain 422 with no structured reason still counts —
	// only the typed vocabulary exonerates.
	loweredErr := strings.ToLower(msg.Error)
	capacityRejection := msg.StatusCode == http.StatusServiceUnavailable ||
		msg.StatusCode == http.StatusTooManyRequests ||
		strings.Contains(loweredErr, "token_budget_exhausted") ||
		strings.Contains(loweredErr, "insufficient memory")
	cancelTerminal := msg.StatusCode == 499 ||
		strings.Contains(loweredErr, "request cancelled")
	nonProviderFault := isNonProviderFaultErrorReason(msg.ErrorReason)
	if !capacityRejection && !cancelTerminal && !nonProviderFault {
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
		status := "partial_success"
		errorClass := "client_gone_after_commit_provider_error"
		if cancelTerminal {
			errorClass = "client_gone_after_commit_provider_cancelled"
		} else if providerDisconnectedError(msg.Error, msg.StatusCode) {
			errorClass = "client_gone_after_commit_provider_disconnected"
		}
		// After-commit client cancellation: the provider terminated (error /
		// cancel / disconnect) after the consumer had already gone. Count it on
		// routing.client_gone so the after_commit phase reflects ALL post-commit
		// disconnects, not just provider-completed ones (handleComplete). A
		// no-terminal disconnect is counted by the settlement grace path.
		s.emitClientGone(pr.Model, pr.EstimatedPromptTokens, providerChipFamily(provider), phaseAfterCommit)
		outcome := pendingRouteOutcomeWithReason(pr, status, errorClass, msg.StatusCode, msg.ErrorReason, msg.Error)
		if !cancelTerminal {
			outcome.AdmittedButFailed = true
		}
		s.updateInferenceRouteOutcomeForPending(pr, outcome)
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
	s.sendTrustStatus(provider, registry.TrustSelfSigned, "online", "SE attestation verified, awaiting MDM verification")

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

	// Stage the durable Apple MDA cert chain from a LIVE store read. storedProviders
	// above is a one-time startup snapshot — empty for the coordinator's whole life
	// under the in-memory store used in prod — so it cannot surface a chain earned
	// during this coordinator's lifetime. The store record survives provider
	// disconnect, so a serial lookup recovers a chain a previous connection earned,
	// letting attachCachedMDAProof reuse it (re-verified + SE-key-bound) instead of
	// forcing a fresh, Apple-rate-limited DevicePropertiesAttestation round-trip.
	s.stageDurableMDAChain(provider, result.SerialNumber)

	// Deduplicate: if another provider connection exists from the same physical
	// device (same serial number), disconnect it. This prevents multiple
	// provider processes on the same machine from registering independently
	// and competing for a single shared vllm-mlx backend.
	if result.SerialNumber != "" && !s.allowDuplicateProviderSerials {
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

	// DAR-326 Phase 0: record this FULL live MDM verification in the trust-reuse
	// cache (in-memory + durable) so a planned coordinator restart/swap can
	// fast-skip this device's live MDM round-trip — once a fresh live SE challenge
	// re-proves the same identity, unchanged binary, and good posture within the
	// window. Written only here, AFTER the verified MDM pass + hardware grant.
	s.recordTrustReuse(
		provider,
		attestResult.PublicKey,
		attestResult.SerialNumber,
		attestResult.BinaryHash,
		mdmResult.MDMSIPEnabled,
		mdmResult.MDMSecureBootFull,
		mdmResult.UDID,
	)

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

		// DAR-326 FIX B: cache this late grant in the trust-reuse cache too, so it
		// gets the same restart-survivable fast-skip as the synchronous MDM path.
		// Posture was confirmed good above (SIP on + Secure Boot full). Uses the
		// same epoch-checked synchronous write-through (recordTrustReuse) — a
		// concurrent hard untrust is detected and not persisted. seKey + binary hash
		// come from the registration-bound SE attestation.
		//
		// FIX 1: nil-guard the derivation. The candidate set guaranteed a valid
		// attestation + non-empty serial, but NOT a non-empty SE key or binary hash
		// (Swift providers may omit the self-reported binary hash). Skip caching
		// rather than call recordTrustReuse with empty values (which it would reject
		// anyway) — keeps the intent explicit and avoids a useless call.
		c.provider.Mu().Lock()
		var seKey, binaryHash string
		if c.provider.AttestationResult != nil {
			seKey = c.provider.AttestationResult.PublicKey
			binaryHash = c.provider.AttestationResult.BinaryHash
		}
		c.provider.Mu().Unlock()
		if seKey != "" && binaryHash != "" {
			s.recordTrustReuse(c.provider, seKey, c.serial, binaryHash, true /*sip*/, true /*secureBootFull*/, udid)
		}

		// The late grant earned hardware WITHOUT the synchronous MDM verify (which
		// runs the MDA leg via verifyAppleDeviceAttestation), so attach the durable
		// MDA proof here too — otherwise a provider upgraded via late SecurityInfo
		// stays mda_verified=false despite a valid cached chain.
		if ar := c.provider.GetAttestationResult(); ar != nil {
			s.attachCachedMDAProof(c.provider.ID, c.provider, *ar)
		}
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
// It stops as soon as hardware trust is earned, on a terminal posture
// mismatch, or when the connection closes (ctx done).
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

	// DAR-326 Phase 0: if this device has a fresh trust-reuse record (it recently
	// passed a FULL live MDM verification), give the live SE challenge a brief head
	// start to re-prove identity + posture and grant hardware via the trust-reuse
	// fast-skip BEFORE we run the (herd-causing) live MDM SecurityInfo round-trip.
	// Without this, this loop's immediate first attempt would race ahead of the
	// challenge and re-run the full verify anyway, recreating the fleet-wide MDM/APNs
	// herd on a planned coordinator restart/swap. Only candidates wait; a first-ever
	// / expired device proceeds straight to the full live verify (unchanged). If the
	// challenge does not grant within the window (slow / gate miss / hard untrust),
	// we fall through to the unchanged full live MDM verify below.
	if s.trustReuseCache.hasFreshRecord(result.PublicKey, result.SerialNumber) {
		if s.awaitTrustReuseGrant(ctx, provider) {
			return // fast-skip granted hardware — no live MDM round-trip needed
		}
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
		// Stop if hardware was already earned — by this loop on a prior
		// iteration, or by the trust-reuse fast-skip concurrently.
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

// stageDurableMDAChain recovers a previously-earned Apple MDA cert chain from the
// store (by serial) and stages it on the provider as a reuse candidate for this
// reconnect. The store record survives provider disconnect, so this works under
// the in-memory store used in prod — where the startup storedProviders snapshot is
// empty — as well as a durable store. Best-effort: a missing record / chain or a
// read error simply stages nothing, and a fresh attestation is requested.
func (s *Server) stageDurableMDAChain(provider *registry.Provider, serial string) {
	if s.store == nil || serial == "" {
		return
	}
	// Bound the store read: this runs on the attestation path, so a slow or
	// unavailable Postgres must not stall it — on timeout we skip staging and fall
	// back to a fresh attestation.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	// Newest NON-EMPTY chain for this serial: a reconnect persists a new row that
	// may briefly carry an empty chain (async persists race the reattach), which
	// would shadow a still-valid chain via a plain by-serial lookup. This looks
	// past those empty rows.
	chain, err := s.store.GetMDAChainBySerial(ctx, serial)
	if err != nil || len(chain) == 0 {
		return
	}
	provider.StageMDAChainFromJSON(chain)
}

// attachCachedMDAProof tries to satisfy the Apple Device Attestation (MDA) leg
// from the durable cert chain restored on reconnect, WITHOUT a fresh
// DevicePropertiesAttestation round-trip. Apple rate-limits a fresh attestation to
// ≈1/device/7d and it rides the same throttled MicroMDM→APNs channel as
// SecurityInfo, so re-fetching on every reconnect is the reason restarted
// providers show "Apple Device Attestation incomplete". The cached chain is
// re-verified here against Apple's pinned Enterprise Attestation Root CA (an
// expired or tampered chain is rejected) and re-bound to THIS connection's SE key
// via the FreshnessCode OID (anti-relay). Returns true if a valid, bound proof was
// attached — which requires the provider to already hold hardware trust.
func (s *Server) attachCachedMDAProof(providerID string, provider *registry.Provider, attestResult attestation.VerificationResult) bool {
	chain := provider.StagedMDAChain()
	if len(chain) == 0 {
		return false
	}
	mdaResult, err := attestation.VerifyMDADeviceAttestation(chain)
	if err != nil || mdaResult == nil || !mdaResult.Valid {
		// Chain no longer verifies (expired / not Apple-signed) — fall through to a
		// fresh request.
		return false
	}

	// Cached reuse REQUIRES the strong SE-key binding: the FreshnessCode OID in the
	// Apple-signed chain must equal SHA-256 of THIS connection's SE public key. A
	// serial-only match is deliberately NOT sufficient to reuse a stored chain — if
	// the SE key rotated (re-image / keychain reset) the old chain no longer binds
	// this key, so we fall through to a fresh attestation rather than letting a new
	// key inherit the prior device's Apple proof. (A live challenge has already
	// proven possession of this SE key, so the binding is meaningful.)
	if attestResult.PublicKey == "" || len(mdaResult.FreshnessCode) == 0 {
		return false
	}
	// INVARIANT: this must use the exact same input as the fresh path's nonce
	// (verifyAppleDeviceAttestation computes expectedFreshness = sha256([]byte(
	// attestResult.PublicKey)) and sends its base64 as the DeviceAttestationNonce).
	// Apple echoes the decoded nonce as the FreshnessCode, so a chain earned fresh
	// has FreshnessCode == this digest. Keep the two formulas identical.
	want := sha256.Sum256([]byte(attestResult.PublicKey))
	if !bytes.Equal(mdaResult.FreshnessCode, want[:]) {
		return false
	}
	// Defense in depth: when Apple included a serial, it must match this machine's
	// attested serial (privacy-enrolled chains omit the serial — the SE-key binding
	// above carries the proof in that case).
	if mdaResult.DeviceSerial != "" && mdaResult.DeviceSerial != attestResult.SerialNumber {
		return false
	}

	if !provider.SetMDAProofIfHardwareBound(chain, mdaResult, true) {
		// Not hardware-trusted (yet) — nothing to attach the proof to.
		return false
	}
	// Persist immediately under THIS connection's record. The grant-path
	// PersistProvider ran before this attach, so without this write the new
	// session's row would carry an empty mda_cert_chain until the next throttled
	// heartbeat — and a disconnect in that window would lose the chain (serial now
	// indexes this session's row), forcing a fresh, rate-limited refetch on the
	// next reconnect. Mirrors the fresh-MDA path's immediate persist.
	s.registry.PersistProvider(provider)
	s.logger.Info("MDA reused from durable cert chain — skipped fresh DevicePropertiesAttestation",
		"provider_id", providerID,
		"mda_serial", mdaResult.DeviceSerial,
		"se_key_bound", true,
	)
	s.ddIncr("mda.verification", []string{"outcome:reused"})
	return true
}

// verifyAppleDeviceAttestation sends a DeviceInformation command requesting
// DevicePropertiesAttestation and verifies the Apple-signed certificate chain.
func (s *Server) verifyAppleDeviceAttestation(ctx context.Context, providerID string, provider *registry.Provider, attestResult attestation.VerificationResult, udid string) {
	// Fast path: reuse a still-valid, SE-key-bound Apple attestation recovered from
	// the durable store instead of requesting a fresh one. This skips the
	// rate-limited APNs round-trip entirely on reconnect/restart and is what keeps
	// mda_verified green across a provider restart.
	if s.attachCachedMDAProof(providerID, provider, attestResult) {
		return
	}

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

	// Persist the freshly-earned chain NOW so it is durable for reuse. The
	// hardware-grant PersistProvider ran before this MDA leg, so without an explicit
	// write here the chain would only reach the store on the next throttled
	// heartbeat persist — and would be lost (and re-fetched, hitting Apple's
	// ~1/device/7d rate limit) if the provider disconnects in that window. With a
	// durable (Postgres) store this is what makes the proof recoverable across a
	// coordinator restart.
	s.registry.PersistProvider(provider)

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

		// Deprecated: the ACME device-attest-01 leg was removed (it was never
		// wired end-to-end; hardware trust is earned via MDM SecurityInfo).
		// The key is kept, always false, because shipped provider builds decode
		// it as a required field.
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

		// The public proofs (mdm/mda) are reported true ONLY for a connection
		// that currently holds hardware trust. A hardware proof is meaningful for
		// the connection that earned it live; surfacing mda_verified on a
		// self_signed connection (e.g. a stored flag or a late-arriving MDA
		// webhook) is the misleading "mda_verified=true while self_signed"
		// drift. Gating on the live trust level keeps the endpoint internally
		// consistent.
		isHardware := trustLevel == registry.TrustHardware
		pa := providerAttestation{
			ProviderID:  p.ID,
			TrustLevel:  string(trustLevel),
			Status:      string(status),
			MemoryGB:    p.Hardware.MemoryGB,
			GPUCores:    p.Hardware.GPUCores,
			MDMVerified: isHardware,
			MDAVerified: mdaVerified && isHardware,
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
	if provider == nil || provider.Conn == nil {
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
	if err := provider.EnqueueText(context.Background(), data); err != nil {
		s.logger.Debug("failed to enqueue trust status to provider", "provider_id", provider.ID, "error", err)
		s.ddIncr("provider.enqueue_failed", []string{"msg:trust_status"})
	}
}
