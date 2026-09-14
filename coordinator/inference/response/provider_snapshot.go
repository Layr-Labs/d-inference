package response

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// committedProviderInfo is the consumer-safe provider snapshot taken at
// dispatch commit — the same values written to X-Provider-* headers.
type ProviderInfo struct {
	ProviderID    string
	Attested      bool
	TrustLevel    registry.TrustLevel
	Encrypted     bool
	Chip          string
	MachineModel  string
	SecureEnclave *bool
	MDAVerified   bool
	SEPublicKey   string
	Location      *types.ProviderApproxLocation
}

func CollectCommittedProviderInfo(provider *registry.Provider) ProviderInfo {
	if provider == nil {
		return ProviderInfo{}
	}
	provider.Mu().Lock()
	pubKey := provider.PublicKey
	attested := provider.Attested
	trustLevel := provider.TrustLevel
	attestResult := provider.AttestationResult
	mdaVerified := provider.MDAVerified
	var locCopy *store.ProviderLocation
	if provider.Location != nil {
		cp := *provider.Location
		locCopy = &cp
	}
	provider.Mu().Unlock()

	info := ProviderInfo{
		ProviderID:   provider.ID,
		Attested:     attested,
		TrustLevel:   trustLevel,
		Encrypted:    pubKey != "",
		Chip:         provider.Hardware.ChipName,
		MachineModel: provider.Hardware.MachineModel,
		MDAVerified:  mdaVerified,
		Location:     consumerSafeLocation(locCopy),
	}
	if attestResult != nil {
		se := attestResult.SecureEnclaveAvailable
		info.SecureEnclave = &se
		info.SEPublicKey = attestResult.PublicKey
	}
	return info
}

func WriteCommittedProviderHeaders(w http.ResponseWriter, info ProviderInfo) {
	if info.Encrypted {
		w.Header().Set("X-Provider-Encrypted", "true")
	}
	if info.Attested {
		w.Header().Set("X-Provider-Attested", "true")
	} else {
		w.Header().Set("X-Provider-Attested", "false")
	}
	w.Header().Set("X-Provider-Trust-Level", string(info.TrustLevel))
	w.Header().Set("X-Provider-Id", info.ProviderID)
	w.Header().Set("X-Provider-Chip", info.Chip)
	w.Header().Set("X-Provider-Model", info.MachineModel)
	if info.SecureEnclave != nil {
		if *info.SecureEnclave {
			w.Header().Set("X-Provider-Secure-Enclave", "true")
		} else {
			w.Header().Set("X-Provider-Secure-Enclave", "false")
		}
	}
	if info.MDAVerified {
		w.Header().Set("X-Provider-Mda-Verified", "true")
	}
	if info.SEPublicKey != "" {
		w.Header().Set("X-Attestation-Se-Public-Key", info.SEPublicKey)
	}
}

func consumerSafeLocation(loc *store.ProviderLocation) *types.ProviderApproxLocation {
	if loc == nil {
		return nil
	}
	if loc.Region == "" && loc.RegionCode == "" && loc.Country == "" && loc.CountryCode == "" && loc.Timezone == "" {
		return nil
	}
	return &types.ProviderApproxLocation{
		Region:      loc.Region,
		RegionCode:  loc.RegionCode,
		Country:     loc.Country,
		CountryCode: loc.CountryCode,
		Timezone:    loc.Timezone,
	}
}
