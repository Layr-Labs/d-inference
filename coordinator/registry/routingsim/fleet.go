// Package routingsim is a trace-driven routing simulation harness that
// exercises the REAL coordinator scheduler/admission code in
// coordinator/registry. It builds a fleet of fully-routable synthetic
// providers, replays an arrival trace through the same preflight admission the
// consumer uses (registry.QuickCapacityCheckWithTTFTForRequest), and reports
// accept/reject outcomes bucketed by prompt size.
//
// The harness is additive and test-only in spirit: it imports the registry
// package through its public API exactly the way the production consumer does,
// so a routing change can be replayed against realistic demand in CI without
// any live providers, WebSockets, or Postgres.
//
// Design note (why a homogeneous fleet reproduces the prod cliff): the
// preflight reports bestTTFT as the MINIMUM time-to-first-token across every
// candidate provider. A request is rejected as "ttft_too_slow" only when even
// the single fastest provider misses the deadline. When the whole fleet runs at
// roughly the same decode speed (Apple Silicon today is ~25 tok/s), the cliff
// is therefore fleet-wide: idle capacity does not help because the fastest
// provider is no faster than the rest. This is the exact prod failure the
// calibration test pins.
package routingsim

import (
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// simProviderPublicKey is a valid base64 X25519 key (reused from the registry
// test helpers) so providerSupportsPrivateText passes. The bytes are never used
// for real encryption in the simulation.
const simProviderPublicKey = "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw="

// DecodeTPSDist returns the static decode tokens/sec for provider index i of n.
// It must be deterministic in i so a simulation run is reproducible.
type DecodeTPSDist func(i, n int) float64

// ConstantDecodeTPS returns a distribution where every provider has the same
// static decode tokens/sec. Because the preflight's bestTTFT is the minimum
// across all candidates, a homogeneous fleet produces a hard, fleet-wide TTFT
// cliff — the prod failure mode this harness reproduces.
func ConstantDecodeTPS(tps float64) DecodeTPSDist {
	return func(i, n int) float64 { return tps }
}

// ClusteredDecodeTPS returns a deterministic distribution centered on median
// with a bounded symmetric integer spread, i.e. values cycle through
// [median-spread, median+spread]. The median is preserved and the fastest
// provider is only spread tok/s above the median, so the cliff stays
// representative of a homogeneous fleet while still exercising a real spread.
// Values are floored at 1 tok/s.
func ClusteredDecodeTPS(median float64, spread int) DecodeTPSDist {
	if spread < 0 {
		spread = 0
	}
	period := 2*spread + 1
	return func(i, n int) float64 {
		offset := (i % period) - spread
		v := median + float64(offset)
		if v < 1 {
			v = 1
		}
		return v
	}
}

// FleetConfig describes a synthetic provider fleet for a single model.
type FleetConfig struct {
	// Model is the model id every provider advertises (required).
	Model string
	// Providers is the number of synthetic providers to register (required, >0).
	Providers int
	// WarmFraction in [0,1] is the share of providers with the model resident
	// (warm). The remainder are cold: they advertise the model but it is not
	// loaded, so the scheduler sees an "unknown" slot with the cold-load penalty.
	WarmFraction float64
	// DecodeTPS supplies the per-provider static decode tokens/sec (required).
	DecodeTPS DecodeTPSDist
	// MemoryGB is the unified memory per provider. Default 64.
	MemoryGB int
	// MemoryBandwidthGBs feeds the sqrt() TPS fallback when DecodeTPS yields 0.
	// Default 400 (M-series Max-class). Irrelevant when DecodeTPS is positive.
	MemoryBandwidthGBs int
	// WarmSlotState is the slot state used for warm providers: "running" or
	// "idle". Both mean the model is loaded (penalty 0). Default "running".
	WarmSlotState string
	// IDPrefix prefixes generated provider ids. Default "sim".
	IDPrefix string
}

func (c FleetConfig) withDefaults() FleetConfig {
	if c.MemoryGB <= 0 {
		c.MemoryGB = 64
	}
	if c.MemoryBandwidthGBs <= 0 {
		c.MemoryBandwidthGBs = 400
	}
	if c.WarmSlotState == "" {
		c.WarmSlotState = "running"
	}
	if c.IDPrefix == "" {
		c.IDPrefix = "sim"
	}
	if c.WarmFraction < 0 {
		c.WarmFraction = 0
	}
	if c.WarmFraction > 1 {
		c.WarmFraction = 1
	}
	return c
}

// BuildFleet constructs a real registry.Registry populated with cfg.Providers
// fully-routable synthetic providers for cfg.Model. Each provider is made
// routable the same way the registry/api test helpers do: TrustHardware,
// RuntimeVerified, RuntimeManifestChecked, a fresh challenge (via
// RecordChallengeSuccess, which also sets ChallengeVerifiedSIP), nominal system
// metrics, full private-text privacy capabilities, and a BackendCapacity with a
// per-model slot. The registry uses the default in-memory store (nil) and the
// default MinTrustLevel (TrustHardware).
func BuildFleet(logger *slog.Logger, cfg FleetConfig) (*registry.Registry, error) {
	if cfg.Model == "" {
		return nil, errors.New("routingsim: FleetConfig.Model is required")
	}
	if cfg.Providers <= 0 {
		return nil, errors.New("routingsim: FleetConfig.Providers must be > 0")
	}
	if cfg.DecodeTPS == nil {
		return nil, errors.New("routingsim: FleetConfig.DecodeTPS is required")
	}
	cfg = cfg.withDefaults()
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	}

	reg := registry.New(logger)
	warmCount := int(math.Round(cfg.WarmFraction * float64(cfg.Providers)))
	for i := 0; i < cfg.Providers; i++ {
		warm := i < warmCount
		decode := cfg.DecodeTPS(i, cfg.Providers)
		id := fmt.Sprintf("%s-%04d", cfg.IDPrefix, i)
		registerSimProvider(reg, id, cfg, decode, warm)
	}
	return reg, nil
}

// registerSimProvider registers and arms one synthetic provider.
func registerSimProvider(reg *registry.Registry, id string, cfg FleetConfig, decodeTPS float64, warm bool) *registry.Provider {
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			ChipFamily:         "M3",
			ChipTier:           "Max",
			MemoryGB:           cfg.MemoryGB,
			MemoryAvailableGB:  float64(cfg.MemoryGB),
			MemoryBandwidthGBs: float64(cfg.MemoryBandwidthGBs),
			CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
		},
		Models: []protocol.ModelInfo{
			{ID: cfg.Model, ModelType: "chat", Quantization: "4bit"},
		},
		Backend:                 registry.BackendMLXSwift,
		DecodeTPS:               decodeTPS,
		PublicKey:               simProviderPublicKey,
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
	}

	p := reg.Register(id, nil, msg)

	// Warm providers have the model resident (slot state "running"/"idle",
	// penalty 0). Cold providers advertise the model but have no resident slot,
	// so the scheduler sees the default "unknown" state and the cold-load
	// penalty applies.
	var slots []protocol.BackendSlotCapacity
	if warm {
		slots = []protocol.BackendSlotCapacity{{
			Model:      cfg.Model,
			State:      cfg.WarmSlotState,
			NumRunning: 0,
			NumWaiting: 0,
		}}
	}

	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB: float64(cfg.MemoryGB),
		Slots:         slots,
	}
	p.Mu().Unlock()

	// Public API path for challenge freshness + coordinator-verified SIP. This
	// sets LastChallengeVerified=now and ChallengeVerifiedSIP=true, the final
	// two routing gates. Safe with the default nil store/empty queue.
	reg.RecordChallengeSuccess(id)
	return p
}
