package api

import (
	"encoding/base64"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

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
