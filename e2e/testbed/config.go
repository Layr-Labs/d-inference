package testbed

import "time"

type ModelSpec struct {
	ModelID      string
	NumProviders int
}

var KnownModelSizes = map[string]string{
	"mlx-community/Qwen3.5-0.8B-MLX-4bit": "0.5 GB",
	"mlx-community/gemma-3-270m-4bit":     "0.2 GB",
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
	AttestationInterval time.Duration
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
	ModelSpecs    []ModelSpec
	NumUsers      int
	QueueCapacity int
	QueueTimeout  time.Duration
	SeedBalance   int64
}

func DefaultSuiteConfig() SuiteConfig {
	return SuiteConfig{
		ModelSpecs:    []ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 1}},
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
		if !seen[spec.ModelID] {
			seen[spec.ModelID] = true
			ids = append(ids, spec.ModelID)
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
		return sc.ModelSpecs[0].ModelID
	}
	return "mlx-community/Qwen3.5-0.8B-MLX-4bit"
}
