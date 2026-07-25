package registry

import (
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Config holds registry-level configuration.
type Config struct {
	MinTrustLevel string
	WarmPool      WarmPoolConfig
	CacheRouting  CacheRoutingConfig
	QualityCap    QualityCapConfig

	// DevInsecure enables dev-only "all security disabled" routing
	// (EIGENINFERENCE_DEV_INSECURE). When set, the coordinator fail-opens every
	// attestation/hardening routing gate (runtime manifest, coordinator-verified
	// SIP, code-identity, privacy-capabilities, runtime-verified, and
	// challenge-freshness) while KEEPING the end-to-end crypto requirements
	// (per-provider X25519 public key, mlx-swift backend, encrypted response
	// chunks) — prompts stay encrypted on the wire. main.go additionally forces
	// MIN_TRUST=none, requires the in-memory store, and REFUSES to start against a
	// durable database, so this can never silently weaken a production deployment.
	DevInsecure bool
}

type CacheRoutingConfig struct {
	Mode            string
	ActivationPct   float64
	MaxPlanQPS      float64
	TTL             time.Duration
	MaxHolders      int
	MaxDiscountMs   float64
	MaxCostFraction float64
	MasterKey       string
}

// QualityCapConfig governs the per-provider admission concurrency cap derived
// from each model's quality_concurrency (the largest batch that keeps every
// request at/above the decode floor), replacing the flat-24 fallback. Universal:
// it caps slow/saturated models tightly while leaving fast, over-provisioned
// models effectively unchanged. See concurrency_cap.go.
type QualityCapConfig struct {
	// Enabled turns the cap on. When false the legacy flat per-provider cap
	// (maxConcurrencyForModelLocked) applies unchanged.
	Enabled bool
	// Overcommit multiplies the strict quality batch. 1.0 = the exact
	// decode-floor-preserving batch; 2.0 (default) allows double that, trading a
	// little per-request TPS for ~double pool capacity. The decode floor + load
	// factor are shared with the warm-pool target math (WarmPool.DecodeFloorTPS,
	// effectiveTPSLoadFactor) so admission and planning cannot drift.
	//
	// Settable via EIGENINFERENCE_QUALITY_CONCURRENCY_OVERCOMMIT (parsed below).
	// The TTFT-contention plan stages this DOWN 2.0 -> 1.5 -> 1.0 (one step per
	// observation window) once the occupancy estimate + shadow are validated:
	// 2.0 lets a fast model's quality cap reach ~4 (the gpt-oss cancel knee), so
	// tightening toward 1.0 is the existing occupancy SHEDDER for the high-b tail.
	// Kept at 2.0 by default here — no behavior change until an operator stages it.
	Overcommit float64
}

type WarmPoolConfig struct {
	Enabled     bool
	ObserveOnly bool

	Interval time.Duration
	MinDwell time.Duration

	QueueAgeThreshold         time.Duration
	CapacityRejectThreshold   int
	WarmSaturationThreshold   float64
	TTFTMissThreshold         int
	SpeculativeStartThreshold int
	SpeculativeWinThreshold   int
	ColdDispatchThreshold     int
	LoadDurationThreshold     time.Duration

	// Little's Law target inputs (see warm_pool_target.go).
	//
	// DecodeFloorTPS is the per-request sustained-decode quality floor used to
	// derive per-provider quality concurrency (the max batch before decode drops
	// below the floor). <= 0 disables the quality constraint. BurstBuffer adds
	// spare warm providers on top of the demand-derived target. The Assumed*Tokens
	// size the representative request for the E[S] service-time estimate, and
	// FallbackQualityConcurrency is the per-provider concurrency used when the
	// floor/rates/caps are unknown.
	DecodeFloorTPS             float64
	BurstBuffer                int
	FallbackQualityConcurrency int
	AssumedPromptTokens        int
	AssumedCompletionTokens    int
	// MinWarmByModel is an operator floor for concrete model IDs, e.g.
	// EIGENINFERENCE_WARM_POOL_MIN_WARM="gpt-oss-20b=4,gemma-4-26b-qat-4bit=2".
	// Floors are capped by warm+eligibleCold and still obey load throttles.
	MinWarmByModel map[string]int

	// Ramp shaping. MaxLoadsPerTick is the baseline per-tick load burst;
	// RampGapFraction scales the burst up with the remaining target gap, bounded
	// by MaxLoadsPerTickCeiling (a sane hard maximum). MaxGlobalPendingLoads caps
	// total in-flight loads across the fleet.
	MaxLoadsPerTick        int
	MaxLoadsPerTickCeiling int
	RampGapFraction        float64
	MaxGlobalPendingLoads  int
}

// perTickCeiling is the hard per-tick load cap after demand scaling. It is the
// larger of MaxLoadsPerTick and MaxLoadsPerTickCeiling, and 0 when per-tick loads
// are disabled (MaxLoadsPerTick <= 0), which keeps the controller in observe-only
// behavior for the load-issuing path.
func (c WarmPoolConfig) perTickCeiling() int {
	if c.MaxLoadsPerTick <= 0 {
		return 0
	}
	if c.MaxLoadsPerTickCeiling > c.MaxLoadsPerTick {
		return c.MaxLoadsPerTickCeiling
	}
	return c.MaxLoadsPerTick
}

// ReadConfig reads registry configuration from environment variables.
func ReadConfig() Config {
	return Config{
		MinTrustLevel: os.Getenv(env.EnvPrefix + "_MIN_TRUST"),
		DevInsecure:   env.EnvBool(env.EnvPrefix+"_DEV_INSECURE", false),
		WarmPool: WarmPoolConfig{
			Enabled:                   env.EnvBool(env.EnvPrefix+"_WARM_POOL_ENABLED", true),
			ObserveOnly:               env.EnvBool(env.EnvPrefix+"_WARM_POOL_OBSERVE_ONLY", false),
			Interval:                  envDuration(env.EnvPrefix+"_WARM_POOL_INTERVAL", 10*time.Second),
			MinDwell:                  envDuration(env.EnvPrefix+"_WARM_POOL_MIN_DWELL", 5*time.Minute),
			QueueAgeThreshold:         envDuration(env.EnvPrefix+"_WARM_POOL_QUEUE_AGE_THRESHOLD", 0),
			CapacityRejectThreshold:   env.EnvInt(env.EnvPrefix+"_WARM_POOL_CAPACITY_REJECT_THRESHOLD", 1),
			WarmSaturationThreshold:   env.EnvFloat(env.EnvPrefix+"_WARM_POOL_WARM_SATURATION_THRESHOLD", 0.8),
			TTFTMissThreshold:         env.EnvInt(env.EnvPrefix+"_WARM_POOL_TTFT_MISS_THRESHOLD", 1),
			SpeculativeStartThreshold: env.EnvInt(env.EnvPrefix+"_WARM_POOL_SPECULATIVE_START_THRESHOLD", 2),
			SpeculativeWinThreshold:   env.EnvInt(env.EnvPrefix+"_WARM_POOL_SPECULATIVE_WIN_THRESHOLD", 1),
			ColdDispatchThreshold:     env.EnvInt(env.EnvPrefix+"_WARM_POOL_COLD_DISPATCH_THRESHOLD", 1),
			LoadDurationThreshold:     envDuration(env.EnvPrefix+"_WARM_POOL_LOAD_DURATION_THRESHOLD", 20*time.Second),

			DecodeFloorTPS:             env.EnvFloat(env.EnvPrefix+"_WARM_POOL_DECODE_FLOOR_TPS", 15),
			BurstBuffer:                env.EnvInt(env.EnvPrefix+"_WARM_POOL_BURST_BUFFER", 1),
			FallbackQualityConcurrency: env.EnvInt(env.EnvPrefix+"_WARM_POOL_FALLBACK_QUALITY_CONCURRENCY", 4),
			AssumedPromptTokens:        env.EnvInt(env.EnvPrefix+"_WARM_POOL_ASSUMED_PROMPT_TOKENS", 512),
			AssumedCompletionTokens:    env.EnvInt(env.EnvPrefix+"_WARM_POOL_ASSUMED_COMPLETION_TOKENS", 256),
			MinWarmByModel:             envModelIntMap(env.EnvPrefix + "_WARM_POOL_MIN_WARM"),

			MaxLoadsPerTick:        env.EnvInt(env.EnvPrefix+"_WARM_POOL_MAX_LOADS_PER_TICK", 4),
			MaxLoadsPerTickCeiling: env.EnvInt(env.EnvPrefix+"_WARM_POOL_MAX_LOADS_PER_TICK_CEILING", 16),
			RampGapFraction:        env.EnvFloat(env.EnvPrefix+"_WARM_POOL_RAMP_GAP_FRACTION", 0.5),
			MaxGlobalPendingLoads:  env.EnvInt(env.EnvPrefix+"_WARM_POOL_MAX_GLOBAL_PENDING_LOADS", 16),
		},
		CacheRouting: CacheRoutingConfig{
			Mode:            strings.ToLower(strings.TrimSpace(os.Getenv(env.EnvPrefix + "_CACHE_ROUTING_MODE"))),
			ActivationPct:   envStrictFloat(env.EnvPrefix+"_CACHE_ROUTING_PERCENT", defaultCacheRoutingActivationPct),
			MaxPlanQPS:      envStrictFloat(env.EnvPrefix+"_CACHE_ROUTING_MAX_PLAN_QPS", defaultCacheRoutingMaxPlanQPS),
			TTL:             envDuration(env.EnvPrefix+"_CACHE_ROUTING_TTL", defaultCacheRoutingTTL),
			MaxHolders:      env.EnvInt(env.EnvPrefix+"_CACHE_ROUTING_MAX_HOLDERS", defaultCacheRoutingMaxHolders),
			MaxDiscountMs:   env.EnvFloat(env.EnvPrefix+"_CACHE_ROUTING_MAX_DISCOUNT_MS", defaultCacheRoutingMaxDiscountMs),
			MaxCostFraction: env.EnvFloat(env.EnvPrefix+"_CACHE_ROUTING_MAX_COST_FRACTION", defaultCacheRoutingMaxCostFraction),
			MasterKey:       strings.TrimSpace(os.Getenv(env.EnvPrefix + "_CACHE_MASTER_KEY")),
		},
		QualityCap: QualityCapConfig{
			Enabled:    env.EnvBool(env.EnvPrefix+"_QUALITY_CONCURRENCY_CAP", true),
			Overcommit: env.EnvFloat(env.EnvPrefix+"_QUALITY_CONCURRENCY_OVERCOMMIT", 2.0),
		},
	}
}

func envDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return fallback
}

// envStrictFloat preserves a malformed non-empty value as NaN so Check rejects
// startup instead of silently replacing a safety limit with its permissive
// default. Existing best-effort performance tunables continue using EnvFloat.
func envStrictFloat(key string, fallback float64) float64 {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return fallback
	}
	value, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return math.NaN()
	}
	return value
}

// Check validates the configuration.
// An empty MinTrustLevel is valid and means "use the default".
func (c Config) Check() error {
	// An empty MinTrustLevel is valid ("use the default"); a non-empty one must be
	// a recognized level (trustRank returns -1 otherwise). Either way, all
	// sub-configs are validated on every path.
	if c.MinTrustLevel != "" && trustRank(TrustLevel(c.MinTrustLevel)) < 0 {
		return fmt.Errorf("registry: invalid MinTrustLevel %q (valid: %q, %q, %q)",
			c.MinTrustLevel, TrustNone, TrustSelfSigned, TrustHardware)
	}
	if err := c.WarmPool.Check(); err != nil {
		return err
	}
	if err := c.CacheRouting.Check(); err != nil {
		return err
	}
	return c.QualityCap.Check()
}

func (c CacheRoutingConfig) Check() error {
	mode := c.Mode
	if mode == "" {
		mode = CacheRoutingOff
	}
	switch mode {
	case CacheRoutingOff, CacheRoutingOn:
	default:
		return fmt.Errorf("registry: invalid cache routing mode %q", c.Mode)
	}
	if math.IsNaN(c.ActivationPct) || math.IsInf(c.ActivationPct, 0) || c.ActivationPct <= 0 || c.ActivationPct > 100 {
		return fmt.Errorf("registry: cache routing percentage must be greater than 0 and at most 100")
	}
	if math.IsNaN(c.MaxPlanQPS) || math.IsInf(c.MaxPlanQPS, 0) || c.MaxPlanQPS < 0 || c.MaxPlanQPS > maxCacheRoutingPlanQPS {
		return fmt.Errorf("registry: cache routing max plan QPS must be between 0 and %.0f", maxCacheRoutingPlanQPS)
	}
	if c.TTL < 0 {
		return fmt.Errorf("registry: cache routing ttl must be >= 0")
	}
	if c.MaxHolders < 1 || c.MaxHolders > 32 {
		return fmt.Errorf("registry: cache routing max holders must be between 1 and 32")
	}
	if math.IsNaN(c.MaxDiscountMs) || math.IsInf(c.MaxDiscountMs, 0) || c.MaxDiscountMs < 0 || c.MaxDiscountMs > 10_000 {
		return fmt.Errorf("registry: cache routing max discount must be between 0 and 10000ms")
	}
	if math.IsNaN(c.MaxCostFraction) || math.IsInf(c.MaxCostFraction, 0) || c.MaxCostFraction < 0 || c.MaxCostFraction > 1 {
		return fmt.Errorf("registry: cache routing max cost fraction must be between 0 and 1")
	}
	if mode != CacheRoutingOff {
		if _, err := decodeCacheMasterKey(c.MasterKey); err != nil {
			return fmt.Errorf("registry: cache routing requires a valid CACHE_MASTER_KEY: %w", err)
		}
	}
	return nil
}

func (c QualityCapConfig) Check() error {
	if c.Overcommit < 0 {
		return fmt.Errorf("registry: quality concurrency overcommit must be >= 0")
	}
	return nil
}

func envModelIntMap(key string) map[string]int {
	raw := strings.TrimSpace(os.Getenv(key))
	if raw == "" {
		return nil
	}
	out := make(map[string]int)
	for _, entry := range strings.Split(raw, ",") {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		model, value, ok := strings.Cut(entry, "=")
		if !ok {
			continue
		}
		model = strings.TrimSpace(model)
		if model == "" {
			continue
		}
		n, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil || n <= 0 {
			continue
		}
		out[model] = n
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func (c WarmPoolConfig) Check() error {
	if !c.Enabled && c.Interval == 0 {
		return nil
	}
	if c.Interval <= 0 {
		return fmt.Errorf("registry: warm pool interval must be > 0")
	}
	if c.MinDwell < 0 || c.QueueAgeThreshold < 0 || c.LoadDurationThreshold < 0 {
		return fmt.Errorf("registry: warm pool durations must be >= 0")
	}
	if c.WarmSaturationThreshold < 0 || c.WarmSaturationThreshold > 1 {
		return fmt.Errorf("registry: warm pool saturation threshold must be in [0,1]")
	}
	if c.CapacityRejectThreshold < 1 || c.TTFTMissThreshold < 1 || c.SpeculativeStartThreshold < 1 || c.SpeculativeWinThreshold < 1 || c.ColdDispatchThreshold < 1 {
		return fmt.Errorf("registry: warm pool pressure thresholds must be >= 1")
	}
	if c.MaxLoadsPerTick < 0 || c.MaxGlobalPendingLoads < 0 || c.MaxLoadsPerTickCeiling < 0 {
		return fmt.Errorf("registry: warm pool load limits must be >= 0")
	}
	if c.DecodeFloorTPS < 0 || c.BurstBuffer < 0 || c.RampGapFraction < 0 {
		return fmt.Errorf("registry: warm pool target tunables must be >= 0")
	}
	if c.AssumedPromptTokens < 0 || c.AssumedCompletionTokens < 0 {
		return fmt.Errorf("registry: warm pool assumed token counts must be >= 0")
	}
	if c.FallbackQualityConcurrency < 1 {
		return fmt.Errorf("registry: warm pool fallback quality concurrency must be >= 1")
	}
	return nil
}
