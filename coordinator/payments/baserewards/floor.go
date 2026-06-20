// Package baserewards implements the provider earnings-floor subsidy
// (design: docs/base-rewards.md). The floor is a per-machine, per-epoch base
// reward that is reduced dollar-for-dollar by what the provider already earns
// from real inference:
//
//	payout_i = earned_i + max(0, floor_i - k*earned_i)   // k=1 => max(earned, floor)
//
// floor_i is set by verified memory tier (µUSD/mo), scaled by availability and a
// taper, capped by a fleet-wide pool, and settled once per monthly epoch via an
// idempotent row per (provider_key, epoch_id).
//
// This file holds the pure floor math (tier table, availability ramp, scaled
// floor, draw). No I/O — see engine.go for the only store/registry touch.
package baserewards

import "math"

// DefaultReductionK is the recommended launch reduction rate (k=1): the base is
// a pure backstop that vanishes exactly when earned == floor
// (payout = max(earned, floor)). See design §2.
const DefaultReductionK float64 = 1.0

// MinUptimeForAvail is the uptime fraction below which availability is 0, and
// FullUptimeForAvail is where it reaches 1.0. avail ramps linearly between them.
const (
	MinUptimeForAvail  = 0.90
	FullUptimeForAvail = 1.00
)

// floorTiers maps verified unified-memory size (GB) to a monthly floor in
// micro-USD, highest tier first. A machine is paid the floor of the largest
// tier whose MinGB it meets; sub-24GB machines get $0 (they can't hold even the
// 20B baseline model or run useful specialist work — design §3). The 24GB and
// 32GB tiers exist to incentivize the common mid-range Macs that can serve the
// gpt-oss-20B baseline plus specialist tasks (STT, embeddings); they still earn
// only when actually serving (the work gate). Policy constants, not deployment
// config.
var floorTiers = []struct {
	MinGB int
	Floor int64
}{
	{512, 40_000_000}, // $40/mo
	{192, 30_000_000}, // $30/mo
	{128, 26_000_000}, // $26/mo
	{96, 22_000_000},  // $22/mo
	{64, 18_000_000},  // $18/mo — the "Netflix Standard" anchor
	{48, 16_000_000},  // $16/mo
	{32, 12_000_000},  // $12/mo
	{24, 10_000_000},  // $10/mo — entry tier (20B baseline + specialist work)
}

// TierFloor returns the µUSD/mo floor for a verified memory size (GB).
// Sub-24GB → 0. Tiers are inclusive of their MinGB boundary and extend upward
// until the next tier, so 47GB sits in the 32GB tier and 48GB jumps to the 48GB
// tier.
func TierFloor(memGB int) int64 {
	for _, t := range floorTiers {
		if memGB >= t.MinGB {
			return t.Floor
		}
	}
	return 0
}

// Avail returns the availability multiplier for a monthly uptime fraction:
// clamp((uptimeFrac-0.90)/0.10, 0, 1). It is 0 at or below 90% uptime and 1.0
// at 100%, ramping linearly in between. This is the "stay online" incentive
// (design §3).
func Avail(uptimeFrac float64) float64 {
	v := (uptimeFrac - MinUptimeForAvail) / (FullUptimeForAvail - MinUptimeForAvail)
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

// ScaledFloor returns the per-machine floor in µUSD after applying availability
// and the program taper: TierFloor(memGB) * Avail(uptimeFrac) * taper, rounded
// to the nearest µUSD. Rounding (not truncation) avoids a systematic 1µUSD
// underpay from float64 representation error when avail*taper is exactly 1.
// taper is 1.0 in Phase 0.
func ScaledFloor(memGB int, uptimeFrac, taper float64) int64 {
	return int64(math.Round(float64(TierFloor(memGB)) * Avail(uptimeFrac) * taper))
}

// Draw returns the new money to print for one machine this epoch:
// max(0, floor - int64(k*earned)). With k=1 this is max(0, floor-earned) — the
// base shrinks dollar-for-dollar with organic earnings and never goes negative
// (design §2).
func Draw(floor, earned int64, k float64) int64 {
	reduced := floor - int64(k*float64(earned))
	if reduced < 0 {
		return 0
	}
	return reduced
}
