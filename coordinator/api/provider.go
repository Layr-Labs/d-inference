package api

// Provider HTTP upgrade, public attestation listing and trust-message composition.
// Connections live in providercontrol/session; inference frames live in
// inference/providerframe. The two API binders supply current dependencies.

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/challenge"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/codeidentity"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/verification"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/google/uuid"
	"nhooyr.io/websocket"
)

const (
	// DefaultChallengeInterval is how often the coordinator challenges providers.
	DefaultChallengeInterval = challenge.DefaultInterval

	// ChallengeResponseTimeout is how long to wait for a challenge response.
	ChallengeResponseTimeout = challenge.ResponseTimeout
	// RegistrationAttestationMaxAge bounds replay of a previously valid signed
	// registration claim. Challenge nonces provide ongoing liveness afterward.
	RegistrationAttestationMaxAge = verification.RegistrationMaxAge
	// RegistrationAttestationMaxFutureSkew is the corresponding positive clock
	// skew accepted by attestation.CheckTimestamp. Keep the age and future-skew
	// windows equal while that shared validator uses a symmetric bound.
	RegistrationAttestationMaxFutureSkew = RegistrationAttestationMaxAge

	// minProviderVersionForReconnectAttestation is the first provider release
	// that rebuilds and re-signs its registration attestation on every
	// reconnect. The same release introduced signed protected-runtime claims;
	// older providers retain challenge-based liveness but cannot receive
	// effective protected capabilities.
	minProviderVersionForReconnectAttestation = verification.ReconnectFreshnessVersion

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
	MaxConsecutiveChallengeTimeoutsBeforeReconnect = challenge.MaxConsecutiveTimeoutsBeforeReconnect
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

	// Run the read loop; on return the provider is disconnected.
	s.providerReadLoop(r.Context(), conn, providerID, r)
}

// CodeAttestResponseTimeout bounds how long the coordinator will accept a
// provider's WebSocket reply to an APNs code-identity challenge after the push.
// It is no longer a blocking wait (Fix 1): verification happens in the read-loop
// delivery path (handleCodeAttestationResponse), so this is the acceptance window
// for the pushed nonce. Kept consistent with the APNs apns-expiration window
// (apns.challengeExpirySeconds, Fix 5) — a reply is honored for as long as the
// push could still be delivered. It seeds codeidentity.Config.ChallengeValidity.
const CodeAttestResponseTimeout = codeidentity.CodeAttestResponseTimeout

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
	// The stats:v1 read-cache entry is owned by the stats refresher (network/stats.go)
	// and is NOT evicted here. Evicting it on every registration (~1,400/hour
	// in production) turned its 60 s TTL into ~2.6 s and made every /v1/stats
	// request rerun the multi-second usage analytics statements.
	s.logger.Info("provider location resolved",
		"provider_id", providerID,
		"city", loc.City,
		"country", loc.CountryCode,
		"source", loc.Source,
	)
}

// providerAttestationCacheTTL bounds staleness of the public trust listing. It
// reflects live connection state (trust level, status, models), so it uses the
// same 2s window as GET /v1/models/capacity. The response is the same for every
// caller (unauthenticated, no query parameters).
const providerAttestationCacheTTL = 2 * time.Second

const providerAttestationCacheKey = "providers:attestation:v1"

// handleProviderAttestation returns privacy-redacted trust status for all providers.
// Device identity and raw MDA certificates stay coordinator-private because
// Apple's leaf certificate embeds the hardware serial number and UDID.
func (s *Server) handleProviderAttestation(w http.ResponseWriter, r *http.Request) {
	if body, ok := s.readCacheGet(providerAttestationCacheKey); ok {
		writeCachedJSON(w, body)
		return
	}
	type providerAttestation struct {
		ProviderID    string `json:"provider_id"`
		ChipName      string `json:"chip_name"`
		HardwareModel string `json:"hardware_model"`
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

		// Apple Device Attestation (MDA), verified coordinator-side. The raw
		// certificate chain is intentionally not part of this public DTO.
		MDAVerified   bool   `json:"mda_verified"`
		MDAOSVersion  string `json:"mda_os_version,omitempty"`
		MDASepVersion string `json:"mda_sepos_version,omitempty"`
	}

	var providers []providerAttestation

	publicProviderModels := s.registry.PublicProviderModels()
	s.registry.ForEachProvider(func(p *registry.Provider) {
		// Snapshot mutable fields under provider lock to avoid racing
		// with background MDA verification and challenge goroutines.
		p.Mu().Lock()
		trustLevel := p.TrustLevel
		status := p.Status
		mdaVerified := p.MDAVerified
		attestResult := p.AttestationResult
		mdaResult := p.MDAResult
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

		pa.Models = append(pa.Models, publicProviderModels[p.ID].Models...)

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
	body, err := encodeCachedJSON(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode attestation"))
		return
	}
	s.readCacheSet(providerAttestationCacheKey, body, providerAttestationCacheTTL)
	writeCachedJSON(w, body)
}

// sendTrustStatus sends the provider its current trust level and status over
// the WebSocket connection and persist the coordinator's current decision for
// local operator diagnostics. Provider log upload is retired.
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
