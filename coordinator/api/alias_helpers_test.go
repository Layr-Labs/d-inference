package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// registerBuildsProvider registers a fully ROUTABLE provider (in-process, nil
// conn) advertising the given builds — trust + fresh challenge + runtime
// verified + private-text caps — so it passes the same gate real routing
// applies. Used by alias/routing tests that need routable capacity without a live
// WebSocket. Version is set to the desired_models feature floor so version-gated
// fan-out includes it (the nil conn just means an actual send is a no-op error).
func registerBuildsProvider(srv *Server, id string, builds ...string) {
	models := make([]protocol.ModelInfo, 0, len(builds))
	slots := make([]protocol.BackendSlotCapacity, 0, len(builds))
	for _, b := range builds {
		models = append(models, protocol.ModelInfo{ID: b, ModelType: "chat", Quantization: "4bit"})
		slots = append(slots, protocol.BackendSlotCapacity{Model: b, State: "running"})
	}
	p := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Hardware:                protocol.Hardware{MemoryGB: 64, MemoryAvailableGB: 60},
		Models:                  models,
		Backend:                 registry.BackendMLXSwift,
		Version:                 minProviderVersionForDesiredModels,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess:    true,
			TextProxyDisabled:       true,
			PythonRuntimeLocked:     true,
			DangerousModulesBlocked: true,
			SIPEnabled:              true,
			AntiDebugEnabled:        true,
			CoreDumpsDisabled:       true,
			EnvScrubbed:             true,
		},
	})
	p.Mu().Lock()
	p.Version = minProviderVersionForDesiredModels
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: slots}
	p.Mu().Unlock()
}
