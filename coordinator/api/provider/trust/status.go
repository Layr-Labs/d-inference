package trust

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const providerAttestationCacheTTL = 2 * time.Second

const providerAttestationCacheKey = "providers:attestation:v1"

// HandleProviderAttestation returns trust status for public providers only.
// Serial numbers, UDIDs and raw MDA certificates stay coordinator-private.
// The legacy SE public key remains public for response signature verification;
// unlike the connection ID, that key can link successive public sessions.
func (s *Owner) HandleProviderAttestation(w http.ResponseWriter, r *http.Request) {
	if body, ok := s.readCache.Get(providerAttestationCacheKey); ok {
		httpx.WriteCachedJSON(w, body)
		return
	}
	type providerAttestation struct {
		ProviderID             string                `json:"provider_id"`
		ChipName               string                `json:"chip_name"`
		HardwareModel          string                `json:"hardware_model"`
		TrustLevel             string                `json:"trust_level"`
		Status                 string                `json:"status"`
		Verification           registry.Verification `json:"verification"`
		AppAttestAuthorized    bool                  `json:"app_attest_authorized"`
		AuthorizationExpiresAt int64                 `json:"authorization_expires_at,omitempty"`

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

		// Apple Device Attestation (MDA), verified coordinator-side. The raw
		// certificate chain is intentionally not part of this public DTO.
		MDAVerified   bool   `json:"mda_verified"`
		MDAOSVersion  string `json:"mda_os_version,omitempty"`
		MDASepVersion string `json:"mda_sepos_version,omitempty"`
	}

	var providers []providerAttestation

	// The registry holds membership and provider locks for the whole row:
	// verification and compatibility fields cannot observe different grants.
	s.registry.ForEachProviderVerification(func(p *registry.Provider, verification registry.Verification, models registry.PublicProviderModelSnapshot) {
		// Match the public stats roster. Private connections must never enter
		// this unauthenticated response or its shared cache.
		if p.PrivateOnly {
			return
		}
		trustLevel := p.TrustLevel
		status := p.Status
		mdaVerified := p.MDAVerified
		attestResult := p.AttestationResult
		mdaResult := p.MDAResult

		// The public proofs (mdm/mda) are reported true ONLY for a connection
		// that currently holds hardware trust. A hardware proof is meaningful for
		// the connection that earned it live; surfacing mda_verified on a
		// self_signed connection (e.g. a stored flag or a late-arriving MDA
		// webhook) is the misleading "mda_verified=true while self_signed"
		// drift. Gating on the live trust level keeps the endpoint internally
		// consistent.
		isHardware := trustLevel == registry.TrustHardware
		pa := providerAttestation{
			ProviderID:   p.ID,
			Verification: verification,
			TrustLevel:   string(trustLevel),
			Status:       string(status),
			MemoryGB:     p.Hardware.MemoryGB,
			GPUCores:     p.Hardware.GPUCores,
			MDMVerified:  isHardware,
			MDAVerified:  mdaVerified && isHardware,
		}

		pa.Models = models.Models
		if verification.AppAttest.State == "verified" {
			pa.AppAttestAuthorized, pa.AuthorizationExpiresAt = true, verification.AppAttest.ExpiresAt
		}

		if attestResult != nil {
			pa.ChipName = attestResult.ChipName
			pa.HardwareModel = attestResult.HardwareModel
			pa.SecureEnclave = attestResult.SecureEnclaveAvailable
			pa.SIPEnabled = attestResult.SIPEnabled
			pa.SecureBootEnabled = attestResult.SecureBootEnabled
			pa.AuthenticatedRoot = attestResult.AuthenticatedRootEnabled
			pa.SystemVolumeHash = attestResult.SystemVolumeHash
			pa.SEPublicKey = attestResult.PublicKey
		}

		if isHardware && mdaResult != nil {
			pa.MDAOSVersion = mdaResult.OSVersion
			pa.MDASepVersion = mdaResult.SepOSVersion
		}

		providers = append(providers, pa)
	})

	resp := map[string]any{"providers": providers}
	body, err := httpx.EncodeCachedJSON(resp)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to encode attestation"))
		return
	}
	s.readCache.Set(providerAttestationCacheKey, body, providerAttestationCacheTTL)
	httpx.WriteCachedJSON(w, body)
}

// sendTrustStatus sends the provider its current trust level and status over
// the WebSocket connection and persist the coordinator's current decision for
// local operator diagnostics. Provider log upload is retired.
func (s *Owner) sendTrustStatus(provider *registry.Provider, trustLevel registry.TrustLevel, status string, reason string) {
	if provider == nil || provider.Conn == nil {
		return
	}
	msg := protocol.TrustStatusMessage{
		Type:          protocol.TypeTrustStatus,
		TrustLevel:    string(trustLevel),
		Status:        status,
		Reason:        reason,
		Authorization: s.providerServingAuthorizationStatus(provider),
	}
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	if err := provider.EnqueueText(context.Background(), data); err != nil {
		s.logger.Debug("failed to enqueue trust status to provider", "provider_id", provider.ID, "error", err)
		s.observation.Incr("provider.enqueue_failed", []string{"msg:trust_status"})
	}
}
