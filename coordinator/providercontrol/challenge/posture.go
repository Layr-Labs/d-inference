package challenge

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Verifier) verifyPosture(providerID string, provider *registry.Provider, resp *protocol.AttestationResponseMessage) bool {
	// Verify fresh SIP status. This signal is mandatory for private text:
	// an omitted value is not evidence of safety, so fail closed.
	if resp.SIPEnabled == nil {
		s.RecordFailure(providerID, "SIP status not reported")
		return false
	}
	// If the provider reports SIP disabled, they've rebooted since
	// registration and are no longer trustworthy. SIP cannot be disabled at
	// runtime — a reboot into Recovery Mode is required.
	if !*resp.SIPEnabled {
		s.deps.Logger().Error("provider SIP disabled in challenge response — marking untrusted",
			"provider_id", providerID,
		)
		s.deps.Registry().MarkUntrusted(providerID)
		s.RecordFailure(providerID, "SIP disabled")
		return false
	}

	// Verify fresh Secure Boot status.
	if resp.SecureBootEnabled != nil && !*resp.SecureBootEnabled {
		s.deps.Logger().Error("provider Secure Boot disabled in challenge response — marking untrusted",
			"provider_id", providerID,
		)
		s.deps.Registry().MarkUntrusted(providerID)
		s.RecordFailure(providerID, "Secure Boot disabled")
		return false
	}

	// Verify fresh RDMA status. Reporting remains mandatory so routing and
	// trust policy can distinguish single-node providers from RDMA-aware
	// cluster runtimes. RDMA enablement is not itself a challenge failure:
	// Apple Silicon Thunderbolt RDMA is IOMMU-scoped to registered buffers,
	// so the security boundary is the signed runtime's buffer-registration
	// discipline.
	if resp.RDMADisabled == nil {
		s.RecordFailure(providerID, "RDMA status not reported — provider must update to v0.2.0+")
		return false
	}
	if !*resp.RDMADisabled {
		s.deps.Logger().Info("provider RDMA enabled — accepting under registered-buffer RDMA policy",
			"provider_id", providerID,
			"backend", provider.Backend,
		)
	}

	return true
}
