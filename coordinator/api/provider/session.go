package provider

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/api/provider/trust"
	attestservice "github.com/eigeninference/d-inference/coordinator/appattest/service"
	inventory "github.com/eigeninference/d-inference/coordinator/internal/provider/inventory"
	session "github.com/eigeninference/d-inference/coordinator/internal/provider/session"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"nhooyr.io/websocket"
)

func (s *Owner) providerReadLoop(ctx context.Context, conn *websocket.Conn, providerID string, r *http.Request) {
	var provider *registry.Provider
	var terminalWork session.CompletionBarrier
	var drainAcks session.DrainAcker
	var appAttestShadow *attestservice.Session
	tracker := trust.NewChallengeTracker()
	var schedulerSEKey string
	var schedulerGeneration uint64

	// peerCloseStatus is the close code the peer sent, captured by the read
	// loop so the deferred teardown can flush pending requests with the
	// health-neutral restart cause on a graceful 1000/1001 close and the
	// striking abrupt cause otherwise (registry.ClassifyPeerClose). -1 = no
	// close frame observed.
	peerCloseStatus := websocket.StatusCode(-1)
	// Cancel context for cleanup of the challenge loop goroutine.
	loopCtx, loopCancel := context.WithCancel(ctx)
	defer func() {
		loopCancel()
		s.trust.UnbindConnection(providerID, schedulerSEKey, schedulerGeneration)
		// End connection-continuity coverage with the EXACT coordinator-
		// observed disconnect time (before registry.Disconnect tears the
		// provider down), so the measured reconnect gap starts here rather
		// than at the last periodic coverage pass.
		s.trust.StopTrustCoverageForProvider(providerID)
		s.trust.StopCodeAttestCoverageForProvider(providerID)
		s.registry.DisconnectWithReason(providerID, registry.ClassifyPeerClose(peerCloseStatus, false))
		conn.Close(websocket.StatusNormalClosure, "goodbye")
	}()

	for {
		_, data, err := conn.Read(loopCtx)
		if err != nil {
			closing := s.providerSocketsClosing()
			closeStatus := session.ShutdownCloseStatus(websocket.CloseStatus(err), closing)
			oomSuspected := false
			readReason := session.ReadErrorReasonGeneric
			if closeStatus != -1 {
				peerCloseStatus = closeStatus
				s.logger.Info("provider websocket closed",
					"provider_id", providerID, "close_code", int(closeStatus))
				s.countCloseDisconnect(closeStatus)
			} else {
				readReason = session.ReadErrorDisconnectReason(err)
				s.logger.Error("provider websocket read error",
					"provider_id", providerID, "error", err, "reason", readReason)
				s.observation.Emit(context.Background(), protocol.SeverityWarn, protocol.KindConnectivity,
					"provider websocket read error",
					map[string]any{
						"provider_id": providerID,
						"ws_state":    "read_error",
						"reason":      readReason,
						"last_error":  err.Error(),
					})
				if s.observation.Metrics() != nil {
					s.observation.Metrics().IncCounter("ws_disconnects_total",
						observation.MetricLabel{Name: "reason", Value: readReason},
					)
				}
				s.observation.Incr("ws.disconnects", []string{"reason:" + readReason})

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
						if s.observation.Metrics() != nil {
							s.observation.Metrics().IncCounter("provider_oom_suspected_total")
						}
						s.observation.Incr("provider.oom_suspected", nil)
						s.observation.Emit(context.Background(), protocol.SeverityError, protocol.KindOOM,
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
			//   - ctx.Err() != nil: the loop's context was cancelled (a
			//     hijacked socket's request context is not cancelled by
			//     httpServer.Shutdown; a socket the coordinator closed for
			//     shutdown reads as going-away and is stamped
			//     coordinator_shutdown above);
			//   - the registry no longer has the provider: registry.Disconnect
			//     already ran (stale eviction, duplicate-serial kick) and owns
			//     the reason for that path.
			if provider != nil && ctx.Err() == nil && s.registry.GetProvider(providerID) != nil {
				s.closeSessionOffline(providerID, provider, session.DisconnectReason(closeStatus, oomSuspected, readReason, closing))
			}
			return
		}

		var msg protocol.ProviderMessage
		// DecodeProviderMessage is json.Unmarshal minus its redundant outer
		// validation pass; per-token chunk frames take a hand-written decoder.
		if err := protocol.DecodeProviderMessage(data, &msg); err != nil {
			if errors.Is(err, protocol.ErrAppAttestShadowFrameTooLarge) {
				if appAttestShadow != nil {
					// Inventory periodically persists this same atomic counter,
					// including on disconnect. No proof or database work here.
					appAttestShadow.RejectOversized()
				}
				s.observation.Incr("app_attest.shadow.frames_rejected", []string{"reason:oversized"})
			}
			// Decoder errors may quote provider-controlled fields (notably an
			// unknown message type). Never reflect the detail into logs.
			s.logger.Warn("invalid provider message", "provider_id", providerID)
			continue
		}

		switch msg.Type {
		case protocol.TypeRegister:
			if provider != nil {
				s.logger.Warn("rejecting second register on provider connection",
					"provider_id", providerID)
				_ = conn.Close(websocket.StatusPolicyViolation, "provider already registered")
				return
			}
			regMsg := msg.Payload.(*protocol.RegisterMessage)
			// The version string is provider-controlled and flows into semver
			// parsing memos, metric tags and logs; a legitimate build id is a
			// few dozen bytes. Reject anything larger before it reaches the
			// registry so a hostile client cannot retain multi-MiB keys.
			if len(regMsg.Version) > maxProviderVersionLength {
				s.logger.Warn("rejecting provider registration with oversized version",
					"provider_id", providerID, "version_len", len(regMsg.Version))
				s.observation.Incr("providers.registration_rejected", []string{"reason:oversized_version"})
				_ = conn.Close(websocket.StatusPolicyViolation, "version string too long")
				return
			}
			if err := s.registry.ValidatePrefixCacheRegistration(regMsg); err != nil {
				// Validation errors can quote provider-controlled model IDs.
				s.logger.Warn("rejecting malformed provider cache capabilities",
					"provider_id", providerID)
				s.observation.Incr("routing.cache_capability_rejected", []string{"source:register"})
				_ = conn.Close(websocket.StatusPolicyViolation, "invalid prefix-cache capabilities")
				return
			}
			// Resolve the token once before choosing the identity rollout path.
			// Keep linkage after attestation restoration, as with legacy clients;
			// only this validated account may select the App Attest cohort.
			authenticatedAccountID, authenticatedTokenLabel := "", ""
			accountResolved := false
			resolveAccount := func() {
				accountResolved = true
				pt, err := s.store.GetProviderToken(regMsg.AuthToken)
				if err != nil || pt == nil {
					s.logger.Warn("provider auth token invalid", "provider_id", providerID, "error", err)
				} else {
					authenticatedAccountID, authenticatedTokenLabel = pt.AccountID, pt.Label
				}
			}
			if regMsg.AuthToken != "" && s.trust.AppAttestFeature().NeedsIdentityAccount(regMsg) {
				resolveAccount()
			}
			provider = s.registry.Register(providerID, conn, regMsg)
			if s.providerSocketsClosing() {
				// Registered after shutdown began closing sockets; the
				// socket is being closed, so leave before reading anything,
				// with the same restart-neutral classification a closed
				// socket gets. The session row this registration opens is
				// stamped coordinator_shutdown here, as the read-error path
				// stamps its row: the deferred registry teardown only knows
				// the generic reason. The open is asynchronous, and a close
				// that lands first records the closed row itself (first
				// close wins), so the stamp holds either way.
				peerCloseStatus = websocket.StatusGoingAway
				s.logger.Info("provider registered during shutdown; closing", "provider_id", providerID)
				s.countCloseDisconnect(peerCloseStatus)
				if ctx.Err() == nil && s.registry.GetProvider(providerID) != nil {
					s.closeSessionOffline(providerID, provider, session.DisconnectReasonCoordinatorShutdown)
				}
				return
			}
			if s.trust.AppAttestIdentityCandidate(regMsg, authenticatedAccountID) {
				provider.RequireVerifiedMachineIdentity()
			}
			s.attachProviderLocation(providerID, provider, r)
			if err := s.trust.VerifyProviderAttestation(loopCtx, providerID, provider, regMsg, authenticatedAccountID); err != nil {
				// No duplicate eviction or account/MDM continuation after failed
				// recovery. Pending state remains unroutable through teardown.
				s.logger.Warn("provider registration recovery failed", "provider_id", providerID, "error", err)
				_ = conn.Close(websocket.StatusTryAgainLater, "provider state temporarily unavailable")
				return
			}

			// Record registration outcome metrics + telemetry.
			provider.Mu().Lock()
			trustLevel := string(provider.TrustLevel)
			provider.Mu().Unlock()
			if s.observation.Metrics() != nil {
				s.observation.Metrics().IncCounter("provider_registrations_total",
					observation.MetricLabel{Name: "trust_level", Value: trustLevel},
				)
			}
			s.observation.Incr("providers.registrations", []string{"trust_level:" + trustLevel})
			s.observation.Emit(context.Background(), protocol.SeverityInfo, protocol.KindLog,
				"provider registered",
				map[string]any{
					"provider_id":   providerID,
					"trust_level":   trustLevel,
					"hardware_chip": regMsg.Hardware.ChipName,
					"memory_gb":     regMsg.Hardware.MemoryGB,
				})

			// Legacy-only providers keep their original post-restoration lookup.
			// A structurally eligible App Attest registration already resolved
			// this token; never reroll its cohort through a second store read.
			if regMsg.AuthToken != "" && !accountResolved {
				resolveAccount()
			}
			if authenticatedAccountID != "" {
				provider.Mu().Lock()
				provider.AccountID = authenticatedAccountID
				provider.Mu().Unlock()
				provider.RebindStableFaultKey()
				s.logger.Info("provider linked to account", "provider_id", providerID,
					"account_id", authenticatedAccountID, "token_label", authenticatedTokenLabel)
			}

			// Store provider version. SetVersion also runs the version-changed
			// reconnect reset for the session's stable identity, which the
			// attestation bind above could not (the version was not stored
			// yet) — see registry/version_reset.go.
			if regMsg.Version != "" {
				provider.SetVersion(regMsg.Version)
			}

			// Verify runtime integrity against the known-good manifest. Swift
			// providers omit Python/vllm hashes, but they still report external
			// runtime assets such as mlx.metallib under template_hashes.
			if s.releases.RuntimeManifest() != nil {
				runtimeOK, mismatches := s.releases.VerifyRuntimeHashesForBackend(
					regMsg.Backend, regMsg.TemplateHashes)
				provider.Mu().Lock()
				provider.RuntimeVerified = runtimeOK
				provider.RuntimeManifestChecked = runtimeOK
				provider.MetallibVerified = runtimeOK &&
					s.releases.RuntimeApprovesMetallib(regMsg.TemplateHashes)
				if !runtimeOK || !provider.MetallibVerified {
					provider.RuntimeCapabilities = nil
					provider.FreshCodeAttested = false
				}
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
							s.observation.Incr("provider.enqueue_failed", []string{"msg:runtime_status"})
						}
					}
					s.logger.Warn("provider runtime integrity mismatch — excluded from routing",
						"provider_id", providerID,
						"mismatches", len(mismatches),
					)
				} else {
					s.logger.Info("provider runtime integrity verified",
						"provider_id", providerID,
					)
				}
			} else {
				// No manifest configured — fail-closed for routing.
				provider.Mu().Lock()
				provider.RuntimeVerified = true
				provider.RuntimeManifestChecked = false
				provider.MetallibVerified = false
				provider.RuntimeCapabilities = nil
				provider.FreshCodeAttested = false
				provider.Mu().Unlock()
			}

			// Version cutoff check — runs AFTER runtime check so it takes precedence.
			// If version is below minimum (or missing while a floor is set),
			// override RuntimeVerified to false.
			if s.trust.BelowMinProviderVersion(regMsg.Version) {
				s.logger.Warn("provider version below minimum — excluded from routing",
					"provider_id", providerID,
					"version", regMsg.Version,
					"min_version", s.trust.MinProviderVersion(),
				)
				s.observation.Incr("provider_version_below_minimum", []string{"gate:registration", trust.VersionMetricTag(regMsg.Version)})
				provider.Mu().Lock()
				provider.RuntimeVerified = false
				provider.RuntimeManifestChecked = false
				provider.MetallibVerified = false
				provider.RuntimeCapabilities = nil
				provider.FreshCodeAttested = false
				provider.Mu().Unlock()
			}

			if err := s.registry.ReconcileAttestedRuntimeCapabilities(providerID); err != nil {
				s.logger.Warn("provider attested runtime claims rejected",
					"provider_id", providerID,
					"reason", err.Error(),
				)
				s.registry.MarkUntrusted(providerID)
				_ = conn.Close(websocket.StatusPolicyViolation, "attested runtime claims mismatch")
				return
			}

			// Declaratively tell the provider the desired build per alias it
			// already serves, so a fresh/reconnected provider converges without a
			// separate catalog pull. Sent even when EMPTY: a provider that
			// reconnects (same process, prefetch state intact) after the alias it
			// was converging to was deleted/repointed must learn that nothing is
			// desired anymore, or its in-flight prefetch would hard-swap anyway.
			// Gated on the Swift backend, the only runtime that understands it.
			if s.catalog.ProviderSupportsDesiredModels(regMsg.Backend) {
				if err := s.registry.SendDesiredModels(providerID, s.registry.DesiredModelsForProvider(providerID)); err != nil {
					s.logger.Warn("failed to send desired_models after register",
						"provider_id", providerID, "error", err)
				}
			}

			// Submit stable device work to the Server-owned bounded scheduler. No
			// goroutine is created for this provider.
			schedulerSEKey, schedulerGeneration = s.trust.SubmitRegistrationVerification(loopCtx, providerID, provider)
			saferun.Go(s.logger, "providerTransportLoop", func() {
				s.providerTransportLoop(loopCtx, provider)
			})
			// Start challenge loop after registration
			saferun.Go(s.logger, "challengeLoop", func() {
				s.trust.ChallengeLoop(loopCtx, providerID, provider, tracker)
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
			if s.trust.CodeAttestorConfigured() {
				saferun.Go(s.logger, "codeAttest", func() {
					s.trust.CodeAttestLoop(loopCtx, providerID, provider)
				})
			}

			appAttestShadow = s.trust.StartAppAttestShadow(loopCtx, provider, regMsg, authenticatedAccountID)

		case protocol.TypeAppAttestShadow:
			if appAttestShadow != nil {
				appAttestShadow.Offer(msg.Payload.(*protocol.AppAttestShadowMessage).Payload)
			}

		case protocol.TypeProviderDrain:
			if provider == nil {
				_ = conn.Close(websocket.StatusPolicyViolation, "register before drain")
				return
			}
			barrier := msg.Payload.(*protocol.ProviderDrainMessage)
			if barrier.RequestID == "" || len(barrier.RequestID) > 64 {
				_ = conn.Close(websocket.StatusPolicyViolation, "invalid drain barrier")
				return
			}
			if !drainAcks.Offer(loopCtx, s.registry, s.logger, provider, &terminalWork, barrier.RequestID) {
				return
			}

		case protocol.TypeModelsReplace:
			if provider == nil {
				_ = conn.Close(websocket.StatusPolicyViolation, "register before models_replace")
				return
			}
			s.inventory.Replace(loopCtx, provider, msg.Payload.(*protocol.ModelsReplaceMessage))

		case protocol.TypeModelsReplaceReady:
			if provider == nil {
				_ = conn.Close(websocket.StatusPolicyViolation, "register before models_replace_ready")
				return
			}
			s.inventory.Ready(loopCtx, provider, msg.Payload.(*protocol.ModelsReplaceReadyMessage))

		case protocol.TypeHeartbeat:
			if provider == nil {
				// Heartbeats are meaningful only after this connection has
				// registered. Reject the protocol violation before touching any
				// provider snapshot or other per-registration state.
				s.logger.Warn("heartbeat from unregistered provider", "provider_id", providerID)
				_ = conn.Close(websocket.StatusPolicyViolation, "register before heartbeat")
				return
			}
			hbMsg := msg.Payload.(*protocol.HeartbeatMessage)
			replaceCacheCapabilities :=
				hbMsg.PrefixCacheProtocol != 0 || hbMsg.PrefixCacheV2Models != nil
			if replaceCacheCapabilities ||
				hbMsg.PrefixCacheMemoryModels != nil ||
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
					hbMsg.PrefixCacheMemoryModels,
					hbMsg.PrefixCacheStatuses,
					hbMsg.PrefixCacheDonationOutcomes,
				)
				if err != nil && (replaceCacheCapabilities || hbMsg.PrefixCacheMemoryModels != nil) {
					s.logger.Warn("rejecting malformed heartbeat cache capabilities",
						"provider_id", providerID)
					s.observation.Incr("routing.cache_capability_rejected", []string{"source:heartbeat"})
					// Malformed refreshes cannot leave stale v2 evidence live.
					_, _ = s.registry.UpdatePrefixCacheSnapshot(
						providerID,
						true,
						1,
						nil,
						nil,
						hbMsg.PrefixCacheStatuses,
						hbMsg.PrefixCacheDonationOutcomes,
					)
				} else if err != nil {
					s.logger.Warn("failed to apply heartbeat cache telemetry",
						"provider_id", providerID)
					s.observation.Incr("routing.cache_telemetry_rejected", []string{"source:heartbeat"})
				}
			}
			if s.heartbeat.Apply(providerID, provider, hbMsg) {
				s.inventory.Heartbeat(loopCtx, provider)
			}
			// W5 Fix 2 (2a): a late/changed APNs token carried in the heartbeat
			// re-arms a code-identity challenge WITHOUT a reconnect.
			s.trust.MaybeRearmCodeAttest(loopCtx, providerID, provider, hbMsg)

		case protocol.TypeCapacityQuote:
			if provider == nil {
				// A quote answers a coordinator-sent probe, and probes are only
				// sent to registered providers — a quote on an unregistered
				// connection is a protocol violation, same posture as heartbeat.
				s.logger.Warn("capacity quote from unregistered provider",
					"provider_id", providerID)
				continue
			}
			quoteMsg := msg.Payload.(*protocol.CapacityQuoteMessage)
			// Correlation (quote_id → outstanding probe, provider binding,
			// window expiry) and plan confirm/demote all live registry-side
			// with the probe state; the read loop only delivers. Synchronous
			// like heartbeat ingest — no DB or lock-heavy work on this path.
			s.registry.HandleCapacityQuote(providerID, quoteMsg)

		case protocol.TypeServiceReservationReleased:
			released := msg.Payload.(*protocol.ServiceReservationReleasedMessage)
			s.registry.ReleaseServiceReservation(provider, released.ServiceReservationID)

		case protocol.TypeInferenceAccepted:
			acceptMsg := msg.Payload.(*protocol.InferenceAcceptedMessage)
			s.inference.Accepted(provider, acceptMsg)

		case protocol.TypeInferenceResponseChunk:
			chunkMsg := msg.Payload.(*protocol.InferenceResponseChunkMessage)
			s.inference.Chunk(providerID, provider, chunkMsg)

		case protocol.TypeInferenceComplete:
			completeMsg := msg.Payload.(*protocol.InferenceCompleteMessage)
			_, receivedAt := provider.MarkPendingCompletionIngressNow(completeMsg.RequestID)
			if receivedAt.IsZero() {
				receivedAt = time.Now()
			}
			// Run completion handling (billing settlement) off the read loop.
			// Billing does synchronous DB calls (GetModelPrice, Credit, Charge)
			// that can block for seconds under DB pressure. If the read loop is
			// blocked, attestation challenge responses can't be read from the
			// WebSocket, causing challenge timeouts and provider derouting.
			terminalDone := terminalWork.Begin()
			saferun.Go(s.logger, "handleComplete", func() {
				defer terminalDone()
				s.inference.CompleteAt(providerID, provider, completeMsg, receivedAt)
			})

		case protocol.TypeInferenceError:
			errMsg := msg.Payload.(*protocol.InferenceErrorMessage)
			var terminalDone func()
			if drainAcks.Started() && s.registry.ProviderDraining(providerID) {
				terminalDone = terminalWork.Begin()
			}
			s.inference.Error(providerID, provider, errMsg)
			if terminalDone != nil {
				terminalDone()
			}

		case protocol.TypePrefixCacheLookup:
			lookupMsg := msg.Payload.(*protocol.PrefixCacheLookupMessage)
			if s.registry.ApplyPrefixCacheLookup(providerID, lookupMsg) {
				s.observation.Incr("routing.cache_lookup_receipt", []string{"outcome:" + lookupMsg.Outcome, "tier:" + observation.LowCardinalityCacheTier(lookupMsg.Tier)})
				s.observation.EmitExactCacheSSDLookup("v1", lookupMsg.Outcome, lookupMsg.StageMs)
			} else {
				s.observation.Incr("routing.cache_receipt_rejected", []string{"type:lookup"})
			}

		case protocol.TypePrefixCacheReady:
			readyMsg := msg.Payload.(*protocol.PrefixCacheReadyMessage)
			if s.registry.ApplyPrefixCacheReady(providerID, readyMsg) {
				s.observation.Incr("routing.cache_ready_receipt", []string{"tier:" + observation.LowCardinalityCacheTier(readyMsg.Tier)})
				s.observation.EmitExactCacheSSDDonation("v1", readyMsg.StageMs, readyMsg.ReadyTokens)
			} else {
				s.observation.Incr("routing.cache_receipt_rejected", []string{"type:ready"})
			}

		case protocol.TypePrefixCacheLookupV2:
			lookupMsg := msg.Payload.(*protocol.PrefixCacheLookupV2Message)
			receipt := s.registry.ApplyPrefixCacheLookupV2Result(providerID, lookupMsg)
			s.observation.EmitCacheReceiptResult("lookup_v2", receipt)
			s.observation.EmitModelCacheReceipt(lookupMsg.ModelID, lookupMsg.Tier, "lookup_v2", receipt)
			if receipt.Accepted {
				s.observation.EmitModelCacheLookup(lookupMsg, receipt)
				s.observation.Incr("routing.cache_lookup_receipt", []string{
					"protocol:v2",
					"outcome:" + lookupMsg.Outcome,
					"tier:" + observation.LowCardinalityCacheTier(lookupMsg.Tier),
				})
				if lookupMsg.Tier == "ssd" {
					s.observation.EmitExactCacheSSDLookup("v2", lookupMsg.Outcome, lookupMsg.StageMs)
				}
			} else {
				s.observation.Incr("routing.cache_receipt_rejected", []string{"type:lookup_v2", "reason:" + string(receipt.Reason)})
			}

		case protocol.TypePrefixCacheReadyV2:
			readyMsg := msg.Payload.(*protocol.PrefixCacheReadyV2Message)
			receipt := s.registry.ApplyPrefixCacheReadyV2Result(providerID, readyMsg)
			s.observation.EmitCacheReceiptResult("ready_v2", receipt)
			s.observation.EmitModelCacheReceipt(readyMsg.ModelID, readyMsg.Tier, "ready_v2", receipt)
			if receipt.Accepted {
				s.observation.EmitModelCacheDonation(readyMsg, receipt)
				s.observation.Incr("routing.cache_ready_receipt", []string{
					"protocol:v2",
					"tier:" + observation.LowCardinalityCacheTier(readyMsg.Tier),
				})
				if readyMsg.Tier == "ssd" {
					donatedTokens := 0
					if len(readyMsg.ReadyAnchors) > 0 {
						donatedTokens = readyMsg.ReadyAnchors[len(readyMsg.ReadyAnchors)-1].TokenCount
					}
					s.observation.EmitExactCacheSSDDonation("v2", readyMsg.StageMs, donatedTokens)
				}
			} else {
				s.observation.Incr("routing.cache_receipt_rejected", []string{"type:ready_v2", "reason:" + string(receipt.Reason)})
			}

		case protocol.TypeAttestationResponse:
			respMsg := msg.Payload.(*protocol.AttestationResponseMessage)
			s.trust.HandleAttestationResponse(providerID, provider, respMsg, tracker)

		case protocol.TypeCodeAttestationResponse:
			respMsg := msg.Payload.(*protocol.CodeAttestationResponseMessage)
			// Verify in the delivery path (Fix 1): a reply attests THIS live
			// connection even if the push round-trip outlived the pushing
			// goroutine or the original connection (reconnect).
			s.trust.HandleCodeAttestationResponse(providerID, provider, respMsg)

		case protocol.TypeModelAutopilotStatus:
			statusMsg := msg.Payload.(*protocol.ModelAutopilotStatusMessage)
			if s.registry.HandleAutopilotStatus(providerID, provider, statusMsg) {
				s.observation.Incr("provider.model_autopilot_status", []string{"status:" + statusMsg.Status})
			} else {
				s.observation.Incr("provider.model_autopilot_status_rejected", nil)
			}

		case protocol.TypeLoadModelStatus:
			statusMsg := msg.Payload.(*protocol.LoadModelStatusMessage)
			if !inventory.ValidLoadModelStatus(statusMsg.Status) {
				// Both fields are provider-controlled until they pass the closed
				// status vocabulary and pending-command match below.
				s.logger.Warn("rejecting invalid load_model_status", "provider_id", providerID)
				s.observation.Incr("provider.load_model_status_rejected", []string{"reason:invalid_status"})
				continue
			}
			if !s.registry.HasPendingModelLoad(providerID, statusMsg.ModelID) {
				s.logger.Warn("rejecting unsolicited load_model_status", "provider_id", providerID)
				s.observation.Incr("provider.load_model_status_rejected", []string{"reason:no_pending_command"})
				continue
			}
			// The exact provider/model pair now names a live coordinator-issued
			// command, and Status is one of three fixed constants. Only canonical
			// values may cross into logs, metrics, or registry state.
			s.logger.Info("provider load_model_status",
				"provider_id", providerID,
				"model_id", statusMsg.ModelID,
				"status", statusMsg.Status,
			)
			switch statusMsg.Status {
			case protocol.LoadModelStatusSucceeded:
				// Mark the model warm on this provider BEFORE draining so
				// the scheduler sees it as a candidate. Without this, the
				// provider still looks cold until the next heartbeat.
				s.registry.MarkModelWarm(providerID, statusMsg.ModelID)
				duration := s.registry.ClearPendingModelLoad(providerID, statusMsg.ModelID)
				s.registry.RecordWarmPoolLoadResult(statusMsg.ModelID, true, duration)
				s.registry.DrainQueuedRequestsForModelWithReason(statusMsg.ModelID, registry.DrainTriggerLoad)
			case protocol.LoadModelStatusFailed:
				duration := s.registry.PendingModelLoadDuration(providerID, statusMsg.ModelID)
				s.registry.RecordWarmPoolLoadResult(statusMsg.ModelID, false, duration)
				// Quantify WHY proactive loads are rejected. The reason
				// is derived only from the existing error string (no new wire
				// field). The proactive path's string is often a generic
				// Foundation bridge ("other"), but dashboards still get the
				// draining vs descriptive classes, and the short backoff below
				// does NOT depend on this classification.
				reason := inventory.ClassifyLoadFailure(statusMsg.Error)
				s.observation.Incr("routing.load_model_rejects", []string{
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
					s.observation.Incr("routing.pending_load_backoff", []string{
						"model:" + statusMsg.ModelID, "kind:drain",
					})
				case inventory.LoadFailureIsPermanent(reason):
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
					s.observation.Incr("routing.pending_load_backoff", []string{
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
			// This frame is advisory progress for a provider-autonomous download;
			// it has no coordinator-issued pending-command identity and no state
			// effect. Ignore it entirely. A later catalog-validated models_update
			// remains the authoritative servability signal.
			continue

		default:
			// Provider message types are untrusted strings until explicitly handled.
			s.logger.Warn("unhandled provider message type", "provider_id", providerID)
		}
	}
}
