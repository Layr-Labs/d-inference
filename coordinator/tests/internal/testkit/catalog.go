package testkit

import (
	"crypto/sha256"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

const ModelHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

// ModelPrefix is independent of the production catalog address builder.
func ModelPrefix(model, version string) string {
	slug := strings.Trim(regexp.MustCompile(`[^a-zA-Z0-9._-]`).ReplaceAllString(model, "-"), "-")
	if slug == "" {
		slug = "model"
	}
	sum := sha256.Sum256([]byte(model))
	return fmt.Sprintf("v2/%s--%x/%s", slug, sum[:6], version)
}

// RegisterBuildsProvider seeds routable capacity for catalog/alias assertions.
// Tests requiring provider traffic instead register over the real WebSocket.
func RegisterBuildsProvider(reg *registry.Registry, id string, builds ...string) *registry.Provider {
	models := make([]protocol.ModelInfo, 0, len(builds))
	slots := make([]protocol.BackendSlotCapacity, 0, len(builds))
	for _, build := range builds {
		models = append(models, protocol.ModelInfo{ID: build, ModelType: "chat", Quantization: "4bit"})
		slots = append(slots, protocol.BackendSlotCapacity{Model: build, State: "running"})
	}
	p := reg.Register(id, nil, &protocol.RegisterMessage{
		Hardware:                protocol.Hardware{MemoryGB: 64, MemoryAvailableGB: 60},
		Models:                  models,
		Backend:                 registry.BackendMLXSwift,
		Version:                 "0.9.9",
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     PrivacyCaps(),
	})
	p.Mu().Lock()
	p.Version = "0.9.9"
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.SystemMetrics = protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.1, ThermalState: "nominal"}
	p.BackendCapacity = &protocol.BackendCapacity{TotalMemoryGB: 64, Slots: slots}
	p.Mu().Unlock()
	return p
}
