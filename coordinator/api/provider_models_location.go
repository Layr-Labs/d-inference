package api

import (
	"encoding/base64"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

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
