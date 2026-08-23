package testbed

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

// DefaultTestModelID is the checkpoint the testbed serves by default.
//
// v0.7.5 ONE-ENGINE: the provider serves exclusively through
// ContinuousBatchingV2 and never advertises models without a CBv2 adapter,
// so the old tiny-Qwen fixture (no adapter) became unservable BY DESIGN.
// gpt-oss-20b is the smallest CBv2-supported production checkpoint
// (~12 GB weights — the runner needs it in the HF cache). Override with
// DARKBLOOM_TESTBED_MODEL for machines that cache a different supported
// checkpoint.
func DefaultTestModelID() string {
	if m := os.Getenv("DARKBLOOM_TESTBED_MODEL"); m != "" {
		return m
	}
	return "mlx-community/gpt-oss-20b-MXFP4-Q8"
}

// SecondaryTestModelID is the second checkpoint multi-model suites serve.
// It must also be CBv2-servable (gpt_oss / gemma4 model families only —
// the provider filters advertised models through EngineV2SupportedModels,
// so a non-CBv2 checkpoint here would never register and its requests
// would only measure routing failures). Override with
// DARKBLOOM_TESTBED_MODEL_B.
func SecondaryTestModelID() string {
	if m := os.Getenv("DARKBLOOM_TESTBED_MODEL_B"); m != "" {
		return m
	}
	return "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
}

type ModelSpec struct {
	// ModelID is the single-model shorthand. ModelIDs takes precedence when set.
	ModelID string
	// ModelIDs lets one provider process advertise multiple models.
	ModelIDs     []string
	NumProviders int
}

func (ms ModelSpec) IDs() []string {
	if len(ms.ModelIDs) > 0 {
		return ms.ModelIDs
	}
	if ms.ModelID != "" {
		return []string{ms.ModelID}
	}
	return nil
}

var KnownModelSizes = map[string]string{
	"mlx-community/gpt-oss-20b-MXFP4-Q8":        "12.1 GB",
	"mlx-community/gemma-4-26B-A4B-it-qat-4bit": "14.5 GB",
	"mlx-community/Qwen3.5-0.8B-MLX-4bit":       "0.5 GB",
	"mlx-community/gemma-3-270m-4bit":           "0.2 GB",
}

type TrustLevel string

const (
	TrustNone       TrustLevel = "none"
	TrustSelfSigned TrustLevel = "self_signed"
	TrustHardware   TrustLevel = "hardware"
)

// KVBackendAuto / KVBackendPaged / KVBackendContiguous are the values the
// provider accepts for `engine_v2_kv_backend` under `[backend]`.
const (
	KVBackendAuto       = "auto"
	KVBackendPaged      = "paged"
	KVBackendContiguous = "contiguous"
)

// ResolveKVBackend returns the KV backend the testbed should ask the provider
// for: the explicit value when set, else DARKBLOOM_TESTBED_KV_BACKEND, else ""
// (leave the provider at its own default). The env fallback lets CI re-run the
// existing suites against a different backend without editing a single test.
func ResolveKVBackend(explicit string) string {
	if explicit != "" {
		return explicit
	}
	return os.Getenv("DARKBLOOM_TESTBED_KV_BACKEND")
}

// ResolveMaxConcurrent returns the per-slot concurrency cap: the explicit
// value when non-zero, else DARKBLOOM_TESTBED_MAX_CONCURRENT, else 0 (leave
// the provider to pick).
//
// 0 IS NOT "8". It is the provider's default, which is 4 as of v0.8.1 — the
// release that reverted v0.8.0's raise to 8 along with the paged KV default
// that justified it. Both the memberwise init and the config-decoder fallback
// read one constant (`BackendSettings.defaultEngineV2MaxConcurrent`, pinned
// together by maxConcurrentMemberwiseAndDecodeDefaultsCannotDrift), so unlike
// the pre-v0.8.0 split it no longer matters whether a TOML was written.
//
// Paged at B=4 measures 0.98x of contiguous against 1.17x at B=8, so selecting
// a KV backend and leaving this at 0 is the one configuration with all of
// paged's cost and none of its benefit. A lane that wants paged MUST name the
// cap too.
//
// A malformed env value is a hard error rather than a silent fall-through. It
// used to be ignored "over a typo in an optional knob", and the knob stopped
// being optional when it became the difference between measuring paged and
// measuring nothing: a typo would quietly seat the suite at the default and
// still pass.
func ResolveMaxConcurrent(explicit int) (int, error) {
	if explicit != 0 {
		return explicit, nil
	}
	raw := os.Getenv("DARKBLOOM_TESTBED_MAX_CONCURRENT")
	if raw == "" {
		return 0, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf(
			"DARKBLOOM_TESTBED_MAX_CONCURRENT=%q is not an integer: %w", raw, err)
	}
	return n, nil
}

// DescribeKVPosture renders the KV posture this config resolves to, naming the
// PROVENANCE of each value and not just the value. A run that reads back
// "provider default" in its log is a run nobody chose the backend for.
//
// This describes what the testbed ASKS the provider for. It equals what the
// provider BUILDS only because an explicit "paged" refuses rather than degrades
// (EngineV2KVBackendPolicy.degradesPagedFailure is false for .paged), so a
// paged request that could not be honoured fails the run instead of reaching
// this log with a lie in it. Under "auto" — or under the negative-polarity kill
// switch DARKBLOOM_CBV2_PAGED_KV=0, which always degrades — the two can differ,
// and only the provider's own slot log says which one served.
func DescribeKVPosture(cfg ProviderConfig) string {
	backend := "provider default"
	switch {
	case cfg.KVBackend != "":
		backend = cfg.KVBackend + " (suite)"
	case os.Getenv("DARKBLOOM_TESTBED_KV_BACKEND") != "":
		backend = os.Getenv("DARKBLOOM_TESTBED_KV_BACKEND") +
			" (env DARKBLOOM_TESTBED_KV_BACKEND)"
	}

	concurrent := "provider default"
	switch {
	case cfg.MaxConcurrent != 0:
		concurrent = fmt.Sprintf("%d (suite)", cfg.MaxConcurrent)
	case os.Getenv("DARKBLOOM_TESTBED_MAX_CONCURRENT") != "":
		concurrent = os.Getenv("DARKBLOOM_TESTBED_MAX_CONCURRENT") +
			" (env DARKBLOOM_TESTBED_MAX_CONCURRENT)"
	}

	kill := "unset"
	if raw := os.Getenv("DARKBLOOM_CBV2_PAGED_KV"); raw != "" {
		kill = raw
	}

	return fmt.Sprintf(
		"kv_backend=%s max_concurrent=%s DARKBLOOM_CBV2_PAGED_KV=%s",
		backend, concurrent, kill)
}

type ProviderConfig struct {
	TrustLevel                 TrustLevel
	ModelID                    string
	ModelIDs                   []string
	AttestationInterval        time.Duration
	AuthTokenPath              string
	EnableEphemeralPrefixCache bool
	// KVBackend selects the CBv2 KV-cache backend for every engine slot the
	// provider builds: "" (leave the provider at its own default), "auto",
	// "paged", or "contiguous". Non-empty makes the testbed write a provider
	// TOML into StateDir and launch with `--config`; empty changes nothing
	// about the launch.
	//
	// GOTCHA — do NOT reach for DARKBLOOM_CBV2_PAGED_KV to turn paged on.
	// That env var is negative-polarity ONLY: it is the fleet kill switch and
	// can force paged OFF, never ON. `engine_v2_kv_backend` under `[backend]`
	// is the only way to select paged, which is the entire reason the testbed
	// writes a config file at all.
	//
	// SETTING THIS ALONE IS A TRAP. Leaving MaxConcurrent at 0 seats the
	// provider on its own default, which is 4 as of v0.8.1. So "paged" on its
	// own is paged@4: 0.98x of contiguous, against 1.17x at B=8. Name
	// MaxConcurrent whenever you name KVBackend.
	KVBackend string
	// MaxConcurrent is the box-wide concurrent-request cap per engine slot
	// (`engine_v2_max_concurrent` under `[backend]`). The provider clamps the
	// value to [1, 8]. Travels through the same generated TOML as KVBackend.
	//
	// 0 leaves the provider to pick, which is 4 as of v0.8.1 — see
	// ResolveMaxConcurrent for why 0 is not a way to ask for 8.
	MaxConcurrent int
}

func DefaultProviderConfig() ProviderConfig {
	return ProviderConfig{
		TrustLevel:          TrustNone,
		AttestationInterval: 5 * time.Minute,
	}
}

type RequestConfig struct {
	MaxTokens         int
	Streaming         bool
	Temperature       float64
	Concurrency       int
	TotalRequests     int
	// ExpectedSuccesses is the target used for reporting. MinimumSuccesses is
	// the hard floor: Run returns an error below it. Both must be configured.
	ExpectedSuccesses int
	MinimumSuccesses  int
	ModelID           string
	PromptBytes       int
}

func DefaultRequestConfig() RequestConfig {
	return RequestConfig{
		MaxTokens:         128,
		Streaming:         true,
		Temperature:       0.0,
		Concurrency:       1,
		TotalRequests:     10,
		ExpectedSuccesses: 10,
		MinimumSuccesses:  10,
	}
}

type TestConfig struct {
	Model    ModelConfig
	Provider ProviderConfig
	Request  RequestConfig
}

func DefaultTestConfig() TestConfig {
	return TestConfig{
		Model:    DefaultModelConfig(),
		Provider: DefaultProviderConfig(),
		Request:  DefaultRequestConfig(),
	}
}

type ModelConfig struct {
	ModelID            string
	Quantization       string
	BackendPort        int
	ContinuousBatching bool
}

func DefaultModelConfig() ModelConfig {
	return ModelConfig{
		ModelID:     DefaultTestModelID(),
		BackendPort: 8000,
	}
}

type UserAccount struct {
	AccountID string
	APIKey    string
}

type SuiteConfig struct {
	ModelSpecs                 []ModelSpec
	NumUsers                   int
	QueueCapacity              int
	QueueTimeout               time.Duration
	SeedBalance                int64
	UseMemoryStore             bool
	EnableEphemeralPrefixCache bool
	// KVBackend / MaxConcurrent are forwarded verbatim to every provider this
	// suite launches. See ProviderConfig for the zero-value semantics and the
	// DARKBLOOM_CBV2_PAGED_KV gotcha.
	KVBackend     string
	MaxConcurrent int
	// ExpectKVBackend asserts the KV backend every engine slot was actually
	// BUILT with ("paged" or "contiguous"); the suite pre-warms each slot and
	// fails Start when the heartbeat-reported kv_backend differs or never
	// arrives. "" falls back to DARKBLOOM_TESTBED_EXPECT_KV_BACKEND, and an
	// unset env leaves the assertion off. Orthogonal to KVBackend: that knob
	// REQUESTS a backend, this one asserts the CONSTRUCTED one — a lane
	// exercising the `.auto` default sets only the expectation.
	ExpectKVBackend string
}

func DefaultSuiteConfig() SuiteConfig {
	return SuiteConfig{
		ModelSpecs:    []ModelSpec{{ModelID: DefaultTestModelID(), NumProviders: 1}},
		NumUsers:      1,
		QueueCapacity: 100,
		QueueTimeout:  120 * time.Second,
		SeedBalance:   100_000_000,
	}
}

func (sc SuiteConfig) AllModelIDs() []string {
	seen := make(map[string]bool)
	var ids []string
	for _, spec := range sc.ModelSpecs {
		for _, id := range spec.IDs() {
			if !seen[id] {
				seen[id] = true
				ids = append(ids, id)
			}
		}
	}
	return ids
}

func (sc SuiteConfig) TotalProviders() int {
	total := 0
	for _, spec := range sc.ModelSpecs {
		total += spec.NumProviders
	}
	return total
}

func (sc SuiteConfig) PrimaryModelID() string {
	if len(sc.ModelSpecs) > 0 {
		ids := sc.ModelSpecs[0].IDs()
		if len(ids) > 0 {
			return ids[0]
		}
	}
	return DefaultTestModelID()
}
