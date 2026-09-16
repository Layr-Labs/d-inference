package session

import (
	"context"
	"encoding/json"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/releasepolicy"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
	"nhooyr.io/websocket"
)

// MaxVersionLength bounds the provider-reported binary version accepted
// at registration. The Swift provider sends the compile-time constant
// ProviderCore.version ("0.8.15"; release tags must equal it, dev builds are
// published with the same exact-version contract), and the longest shape the
// coordinator has ever handled is "0.8.15-rc.1+build" (17 bytes). 128 leaves
// an order of magnitude of margin while keeping provider-controlled bytes out
// of the registry's parse memos, metric tags and logs. Raising this must be
// paired with the registry's memo bound (maxMemoizedVersionLen), which stops
// caching above 64 bytes.
const MaxVersionLength = 128

func (s *Session) register(regMsg *protocol.RegisterMessage) bool {
	// The version string is provider-controlled and flows into semver
	// parsing memos, metric tags and logs; a legitimate build id is a
	// few dozen bytes. Reject anything larger before it reaches the
	// registry so a hostile client cannot retain multi-MiB keys.
	if len(regMsg.Version) > MaxVersionLength {
		s.deps.Logger().Warn("rejecting provider registration with oversized version",
			"provider_id", s.providerID, "version_len", len(regMsg.Version))
		s.deps.Telemetry.Incr("providers.registration_rejected", []string{"reason:oversized_version"})
		_ = s.conn.Close(websocket.StatusPolicyViolation, "version string too long")
		return false
	}
	if err := s.deps.Registry().ValidatePrefixCacheRegistration(regMsg); err != nil {
		// Validation errors can quote provider-controlled model IDs.
		s.deps.Logger().Warn("rejecting malformed provider cache capabilities",
			"provider_id", s.providerID)
		s.deps.Telemetry.Incr("routing.cache_capability_rejected", []string{"source:register"})
		_ = s.conn.Close(websocket.StatusPolicyViolation, "invalid prefix-cache capabilities")
		return false
	}
	s.provider = s.deps.Registry().Register(s.providerID, s.conn, regMsg)
	s.deps.Location(s.providerID, s.provider, s.request)
	if err := s.deps.Verifier().VerifyRegistration(s.loopCtx, s.providerID, s.provider, regMsg); err != nil {
		// No duplicate eviction or account/MDM continuation after failed
		// recovery. Pending state remains unroutable through teardown.
		s.deps.Logger().Warn("provider registration recovery failed", "provider_id", s.providerID, "error", err)
		_ = s.conn.Close(websocket.StatusTryAgainLater, "provider state temporarily unavailable")
		return false
	}

	// Record registration outcome metrics + telemetry.
	if s.deps.Telemetry.Metrics() != nil {
		s.deps.Telemetry.Metrics().IncCounter("provider_registrations_total",
			metrics.Label{Name: "trust_level", Value: string(s.provider.TrustLevel)},
		)
	}
	s.deps.Telemetry.Incr("providers.registrations", []string{"trust_level:" + string(s.provider.TrustLevel)})
	s.deps.Telemetry.Emit(context.Background(), protocol.SeverityInfo, protocol.KindLog,
		"provider registered",
		map[string]any{
			"provider_id":   s.providerID,
			"trust_level":   string(s.provider.TrustLevel),
			"hardware_chip": regMsg.Hardware.ChipName,
			"memory_gb":     regMsg.Hardware.MemoryGB,
		})

	// Resolve auth token → account linkage.
	if regMsg.AuthToken != "" {
		pt, err := s.deps.Store().GetProviderToken(regMsg.AuthToken)
		if err != nil {
			s.deps.Logger().Warn("provider auth token invalid",
				"provider_id", s.providerID,
				"error", err,
			)
		} else {
			s.provider.Mu().Lock()
			s.provider.AccountID = pt.AccountID
			s.provider.Mu().Unlock()
			// Account linkage can be the provider's ONLY stable identity
			// (Open Mode / invalid attestation → the acct: fallback), and
			// it lands after the attestation-time bind — re-bind so fault
			// state keys by identity instead of the session UUID.
			s.provider.RebindStableFaultKey()
			s.deps.Logger().Info("provider linked to account",
				"provider_id", s.providerID,
				"account_id", pt.AccountID,
				"token_label", pt.Label,
			)
		}
	}

	// Store provider version. SetVersion also runs the version-changed
	// reconnect reset for the session's stable identity, which the
	// attestation bind above could not (the version was not stored
	// yet) — see registry/fault_binding.go (Provider.SetVersion) and
	// registry/faultstate/version_reset.go.
	if regMsg.Version != "" {
		s.provider.SetVersion(regMsg.Version)
	}

	// Verify runtime integrity against the known-good manifest. Swift
	// providers omit Python/vllm hashes, but they still report external
	// runtime assets such as mlx.metallib under template_hashes.
	s.provider.Mu().Lock()
	manifest := s.deps.ReleasePolicy().RuntimeManifest()
	if manifest != nil {
		runtimeOK, mismatches := s.deps.ReleasePolicy().VerifyRuntimeHashesForBackendWithManifest(
			manifest, regMsg.Backend, regMsg.PythonHash, regMsg.RuntimeHash, regMsg.TemplateHashes)
		s.provider.RuntimeVerified = runtimeOK
		s.provider.RuntimeManifestChecked = runtimeOK
		s.provider.MetallibVerified = runtimeOK &&
			releasepolicy.RuntimeManifestApprovesMetallib(
				manifest, regMsg.TemplateHashes)
		if !runtimeOK || !s.provider.MetallibVerified {
			s.provider.RuntimeCapabilities = nil
			s.provider.FreshCodeAttested = false
		}
		s.provider.PythonHash = regMsg.PythonHash
		s.provider.RuntimeHash = regMsg.RuntimeHash
		s.provider.TemplateHashes = registry.CloneStringMap(regMsg.TemplateHashes)
		s.provider.Mu().Unlock()

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
				if err := s.provider.EnqueueText(s.loopCtx, statusData); err != nil {
					s.deps.Logger().Debug("failed to enqueue runtime status to provider", "provider_id", s.provider.ID, "error", err)
					s.deps.Telemetry.Incr("provider.enqueue_failed", []string{"msg:runtime_status"})
				}
			}
			s.deps.Logger().Warn("provider runtime integrity mismatch — excluded from routing",
				"provider_id", s.providerID,
				"mismatches", len(mismatches),
			)
		} else {
			s.deps.Logger().Info("provider runtime integrity verified",
				"provider_id", s.providerID,
				"python_hash", regMsg.PythonHash,
				"runtime_hash", regMsg.RuntimeHash,
			)
		}
	} else {
		// No manifest configured — fail-closed for routing.
		s.provider.RuntimeVerified = true
		s.provider.RuntimeManifestChecked = false
		s.provider.MetallibVerified = false
		s.provider.RuntimeCapabilities = nil
		s.provider.FreshCodeAttested = false
		s.provider.Mu().Unlock()
	}

	// Version cutoff check — runs AFTER runtime check so it takes precedence.
	// If version is below minimum, override RuntimeVerified to false.
	if s.deps.MinimumVersion() != "" && regMsg.Version != "" && releasepolicy.VersionLess(regMsg.Version, s.deps.MinimumVersion()) {
		s.deps.Logger().Warn("provider version below minimum — excluded from routing",
			"provider_id", s.providerID,
			"version", regMsg.Version,
			"min_version", s.deps.MinimumVersion(),
		)
		s.deps.Telemetry.Incr("provider_version_below_minimum", []string{"gate:registration", "version:" + regMsg.Version})
		s.provider.Mu().Lock()
		s.provider.RuntimeVerified = false
		s.provider.RuntimeManifestChecked = false
		s.provider.MetallibVerified = false
		s.provider.RuntimeCapabilities = nil
		s.provider.FreshCodeAttested = false
		s.provider.Mu().Unlock()
	}

	if err := s.deps.Registry().ReconcileAttestedRuntimeCapabilities(s.providerID); err != nil {
		s.deps.Logger().Warn("provider attested runtime claims rejected",
			"provider_id", s.providerID,
			"reason", err.Error(),
		)
		s.deps.Registry().MarkUntrusted(s.providerID)
		_ = s.conn.Close(websocket.StatusPolicyViolation, "attested runtime claims mismatch")
		return false
	}

	// Declaratively tell the provider the desired build per alias it
	// already serves, so a fresh/reconnected provider converges without a
	// separate catalog pull. Sent even when EMPTY: a provider that
	// reconnects (same process, prefetch state intact) after the alias it
	// was converging to was deleted/repointed must learn that nothing is
	// desired anymore, or its in-flight prefetch would hard-swap anyway.
	// Gated on Swift backend + feature version: a pre-feature provider's
	// strict decoder throws on unknown types.
	if s.deps.SupportsDesiredModels(regMsg.Backend, regMsg.Version) {
		if err := s.deps.Registry().SendDesiredModels(s.providerID, s.deps.Registry().DesiredModelsForProvider(s.providerID)); err != nil {
			s.deps.Logger().Warn("failed to send desired_models after register",
				"provider_id", s.providerID, "error", err)
		}
	}

	// Submit stable device work to the shared MDM scheduler. No
	// goroutine is created for this provider.
	if s.deps.Scheduler() != nil {
		if ar := s.provider.GetAttestationResult(); ar != nil && ar.Valid {
			priority := s.VerificationPriority(ar.PublicKey, ar.SerialNumber)
			s.schedulerSEKey = ar.PublicKey
			s.schedulerGeneration = s.deps.Scheduler().Submit(s.loopCtx, s.providerID, s.provider, priority)
		}
	}
	// Start challenge loop after registration
	saferun.Go(s.deps.Logger(), "challengeLoop", func() {
		s.challenges.Run(s.loopCtx, s.providerID, s.provider)
	})

	// v0.6.0: APNs code-identity attestation. Runs only when an attestor is
	// configured; otherwise the provider simply never becomes CodeAttested
	// (fail-closed at the routing chokepoint once enforcement begins). The
	// code-identity proof and the SIP/liveness pillar compose at the routing
	// gate (providerSupportsPrivateTextLocked requires both). The loop pushes
	// (within the per-device budget) and polls; verification of the reply
	// happens in codeidentity.Manager.HandleResponse on the read-loop delivery path,
	// so a single dropped/late background push doesn't strand a capable
	// provider, and a reply on a reconnected socket still attests.
	if s.deps.CodeIdentity().Enabled() {
		saferun.Go(s.deps.Logger(), "codeAttest", func() {
			s.deps.CodeLoop(s.loopCtx, s.providerID, s.provider)
		})
	}
	return true
}

// VerificationPriority classifies this connection's durable SecurityInfo
// submission. A record currently admissible for the fast-skip — via window
// freshness OR connection continuity — schedules as a routine refresh (full
// spread); anything else is first/expired (immediate due). The classification
// is optimistic: if the fast-skip later DECLINES despite it, the read path
// promotes the job back to first/expired (PromoteFailedFastSkip).
func (s *Session) VerificationPriority(seKey, serial string) store.VerificationPriority {
	if s.deps.TrustReuse().HasFreshRecord(seKey, serial) {
		return store.VerificationPriorityRefresh
	}
	return store.VerificationPriorityFirstOrExpired
}
