package registry_test

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// enablePerModelQualityCap enables the quality cap exactly like
// enableQualityCap (floor 15, fallback 4, default overcommit) and pins the
// per-model solo-TPS envs — seed CSV, kill switch, min-sample floor — so
// ambient operator settings can't leak in. Parsed settings belong to this
// registry's injected policy and cannot affect another registry.
func enablePerModelQualityCap(t *testing.T, reg *qualityFixture,

	seed, killSwitch, minSamples string) {
	t.Helper()
	t.Setenv(modelSoloTPSSeedEnv, seed)
	t.Setenv(qualityCapPerModelTPSEnv, killSwitch)
	t.Setenv(qualityCapSoloMinSamplesEnv, minSamples)
	enableQualityCap(t, reg, "")
}

// mixedBoxProvider builds the postmortem's mixed box: registration benchmark
// taken on gpt-oss (fast), with BOTH a gpt-oss and a gemma token-budget slot.
func mixedBoxProvider(t *testing.T, reg *qualityFixture,

	id string, decodeTPS float64) *production.Provider {
	t.Helper()
	p := qualityProvider(t, reg, id, gptossBuild, decodeTPS, gemmaBuild)
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 500_000
	p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
		Model:                gemmaBuild,
		State:                "running",
		ActiveTokenBudgetMax: 400_000,
	})
	p.Mu().Unlock()
	return p
}

// setChipClass overrides a provider's chip family/tier so tests can drive the
// class-keyed solo resolver (chipClassKey = family|tier).
func setChipClass(p *production.Provider,

	family, tier string) {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	p.Hardware.ChipFamily = family
	p.Hardware.ChipTier = tier
}

// classProvider is a single-model provider on a named chip class whose slot
// reports the production MaxConcurrency of 8 — the `base` operand of the cap's
// MIN, so the numbers here are the ones prod actually grants.
func classProvider(t *testing.T, reg *qualityFixture,

	id, model, family, tier string) *production.Provider {
	t.Helper()
	p := qualityProvider(t, reg, id, model, 0) // no registration benchmark
	p.Mu().Lock()
	p.Hardware.ChipName = family + " " + tier
	p.Hardware.ChipFamily = family
	p.Hardware.ChipTier = tier
	p.BackendCapacity.Slots[0].MaxConcurrency = 8
	p.Mu().Unlock()
	return p
}

// benchClassProvider is classProvider with a real registration benchmark, so
// soloTransferDestBoundLocked has a destination bound to clamp with that is
// distinguishable from the sqrt(400) = 20 fixture default.
func benchClassProvider(t *testing.T, reg *qualityFixture,

	id, model, family, tier string, decodeTPS float64) *production.Provider {
	t.Helper()
	p := classProvider(t, reg, id, model, family, tier)
	p.Mu().Lock()
	p.DecodeTPS = decodeTPS
	p.Mu().Unlock()
	return p
}
