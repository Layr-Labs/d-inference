package testbed

import (
	"os"
	"time"
)

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

// builtinDefaultModelID is the model exercised when no env override is set.
// gpt-oss-20b is the smallest production model in the registry.
const builtinDefaultModelID = "gpt-oss-20b"

// DefaultModelID resolves the primary model under test. Priority:
//  1. TESTBED_MODEL (model registry ID, e.g. "gemma-4-26b-qat-4bit")
//  2. TESTBED_MODEL_ID (legacy alias, kept for backwards compatibility)
//  3. builtinDefaultModelID
//
// Every default model reference in the e2e suites routes through this
// function so a single env knob switches the model for a whole run.
func DefaultModelID() string {
	if env := os.Getenv("TESTBED_MODEL"); env != "" {
		return env
	}
	if env := os.Getenv("TESTBED_MODEL_ID"); env != "" {
		return env
	}
	return builtinDefaultModelID
}

// KnownModelSizes maps model IDs to the human-readable weight size that is
// advertised in reports (e.g. the benchmark RAM column). TESTBED_MODEL_GB
// (a human string like "15.6 GB") inserts or overrides the entry for the
// active model — see init below — so arbitrary models work without code
// changes.
var KnownModelSizes = map[string]string{
	"mlx-community/Qwen3.5-0.8B-MLX-4bit": "0.5 GB",
	"mlx-community/gemma-3-270m-4bit":     "0.2 GB",
	"gemma-4-26b-qat-4bit":                "15.6 GB",
	"gpt-oss-20b":                         "12.1 GB",
}

func init() {
	// Applied once at package init: TESTBED_MODEL_GB describes the model
	// selected via TESTBED_MODEL (or the built-in default).
	if gb := os.Getenv("TESTBED_MODEL_GB"); gb != "" {
		KnownModelSizes[DefaultModelID()] = gb
	}
}

type TrustLevel string

const (
	TrustNone       TrustLevel = "none"
	TrustSelfSigned TrustLevel = "self_signed"
	TrustHardware   TrustLevel = "hardware"
)

type ProviderConfig struct {
	TrustLevel          TrustLevel
	ModelID             string
	ModelIDs            []string
	AttestationInterval time.Duration
	AuthTokenPath       string
}

func DefaultProviderConfig() ProviderConfig {
	return ProviderConfig{
		TrustLevel:          TrustNone,
		AttestationInterval: 5 * time.Minute,
	}
}

type RequestConfig struct {
	PromptTokens  int
	MaxTokens     int
	Streaming     bool
	Temperature   float64
	Concurrency   int
	TotalRequests int
	ModelID       string
	PromptBytes   int
}

func DefaultRequestConfig() RequestConfig {
	return RequestConfig{
		PromptTokens:  64,
		MaxTokens:     128,
		Streaming:     true,
		Temperature:   0.0,
		Concurrency:   1,
		TotalRequests: 10,
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
		ModelID:     "mlx-community/gemma-3-270m",
		BackendPort: 8000,
	}
}

type UserAccount struct {
	AccountID string
	APIKey    string
}

type SuiteConfig struct {
	ModelSpecs     []ModelSpec
	NumUsers       int
	QueueCapacity  int
	QueueTimeout   time.Duration
	SeedBalance    int64
	UseMemoryStore bool
}

func DefaultSuiteConfig() SuiteConfig {
	return SuiteConfig{
		ModelSpecs:    []ModelSpec{{ModelID: DefaultModelID(), NumProviders: 1}},
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
	return DefaultModelID()
}
