// Package types holds shared API response type definitions.
//
// These structs are the canonical JSON shapes for all consumer-facing
// endpoints. They are extracted from the api package so they can be
// used by tests, tooling, and external consumers without importing
// the full handler package.
package types

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ── Chat completions ────────────────────────────────────────────────

// ChatCompletionMessage is the assistant message in a chat completion choice.
type ChatCompletionMessage struct {
	Role      string           `json:"role"`
	Content   string           `json:"content"`
	Reasoning string           `json:"reasoning,omitempty"`
	ToolCalls []map[string]any `json:"tool_calls,omitempty"`
}

// ChatCompletionChoice is a single choice in a chat completion response.
type ChatCompletionChoice struct {
	Index        int                   `json:"index"`
	Message      ChatCompletionMessage `json:"message"`
	FinishReason string                `json:"finish_reason"`
}

// ChatCompletionUsage is token usage in a chat completion response.
type ChatCompletionUsage struct {
	PromptTokens            int                      `json:"prompt_tokens"`
	CompletionTokens        int                      `json:"completion_tokens"`
	TotalTokens             int                      `json:"total_tokens"`
	CompletionTokensDetails *CompletionTokensDetails `json:"completion_tokens_details,omitempty"`
}

// CompletionTokensDetails is the OpenAI-compatible breakdown of
// completion tokens. Only emitted when there is something to report
// (e.g. a non-zero reasoning-token count).
type CompletionTokensDetails struct {
	ReasoningTokens int `json:"reasoning_tokens"`
}

// ChatCompletionResponse is an OpenAI-compatible chat completion response.
type ChatCompletionResponse struct {
	ID           string                 `json:"id"`
	Object       string                 `json:"object"`
	Created      int64                  `json:"created"`
	Model        string                 `json:"model"`
	Choices      []ChatCompletionChoice `json:"choices"`
	Usage        ChatCompletionUsage    `json:"usage"`
	SESignature  string                 `json:"se_signature,omitempty"`
	ResponseHash string                 `json:"response_hash,omitempty"`
}

// ── Responses API ────────────────────────────────────────────────────

// ResponsesUsageDetail holds token breakdown details.
type ResponsesUsageDetail struct {
	CachedTokens    int `json:"cached_tokens"`
	ReasoningTokens int `json:"reasoning_tokens"`
}

// ResponsesUsage is the usage object in a Responses API response.
type ResponsesUsage struct {
	InputTokens        int                  `json:"input_tokens"`
	InputTokensDetail  ResponsesUsageDetail `json:"input_tokens_details"`
	OutputTokens       int                  `json:"output_tokens"`
	OutputTokensDetail ResponsesUsageDetail `json:"output_tokens_details"`
}

// ResponsesIncompleteDetail is the incomplete_details block.
type ResponsesIncompleteDetail struct {
	Reason string `json:"reason"`
}

// ResponsesResponse is an OpenAI-compatible Responses API response.
// Nullable spec fields (error, instructions, temperature, top_p, …) are
// emitted explicitly as null — official SDKs require the keys to exist.
type ResponsesResponse struct {
	ID                string                     `json:"id"`
	Object            string                     `json:"object"`
	CreatedAt         int64                      `json:"created_at"`
	Status            string                     `json:"status"`
	Error             any                        `json:"error"`
	IncompleteDetail  *ResponsesIncompleteDetail `json:"incomplete_details"`
	Instructions      any                        `json:"instructions"`
	MaxOutputTokens   any                        `json:"max_output_tokens"`
	Model             string                     `json:"model"`
	Output            []any                      `json:"output"`
	ParallelToolCalls bool                       `json:"parallel_tool_calls"`
	Temperature       *float64                   `json:"temperature"`
	ToolChoice        any                        `json:"tool_choice"`
	Tools             []any                      `json:"tools"`
	TopP              *float64                   `json:"top_p"`
	Metadata          map[string]any             `json:"metadata"`
	Usage             ResponsesUsage             `json:"usage"`
	SESignature       string                     `json:"se_signature,omitempty"`
	ResponseHash      string                     `json:"response_hash,omitempty"`
}

// ── GET /v1/models ───────────────────────────────────────────────────

// ModelAttestation is the attestation metadata for a model in /v1/models.
type ModelAttestation struct {
	SecureEnclave bool `json:"secure_enclave"`
	SIPEnabled    bool `json:"sip_enabled"`
	SecureBoot    bool `json:"secure_boot"`
}

// ModelMetadata is the metadata block for a model in /v1/models.
type ModelMetadata struct {
	ModelType         string            `json:"model_type"`
	Quantization      string            `json:"quantization"`
	ProviderCount     int               `json:"provider_count"`
	AttestedProviders int               `json:"attested_providers"`
	TrustLevel        string            `json:"trust_level"`
	Attestation       *ModelAttestation `json:"attestation,omitempty"`
	DisplayName       string            `json:"display_name,omitempty"`
	RoutableProviders int               `json:"routable_providers"`
	WarmProviders     int               `json:"warm_providers"`
	CanAccept         bool              `json:"can_accept"`
}

// ModelPricing is the per-token pricing block in the /v1/models response.
// All values are USD strings (per the OpenRouter provider schema) to avoid
// floating-point precision issues. prompt/completion are per-token;
// image/request are per-image / per-request; input_cache_read is per-token.
type ModelPricing struct {
	Prompt         string `json:"prompt"`
	Completion     string `json:"completion"`
	Image          string `json:"image"`
	Request        string `json:"request"`
	InputCacheRead string `json:"input_cache_read"`
}

// ModelEntry is a single model entry in the /v1/models response. The top-level
// fields follow the OpenRouter provider schema; the nested `metadata` block is
// retained for Darkbloom-native consumers (trust level, provider counts, etc.).
type ModelEntry struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Created int64  `json:"created"`
	OwnedBy string `json:"owned_by"`

	// OpenRouter provider fields.
	Name                        string        `json:"name,omitempty"`
	HuggingFaceID               string        `json:"hugging_face_id,omitempty"`
	Description                 string        `json:"description,omitempty"`
	InputModalities             []string      `json:"input_modalities,omitempty"`
	OutputModalities            []string      `json:"output_modalities,omitempty"`
	Quantization                string        `json:"quantization,omitempty"`
	ContextLength               int           `json:"context_length,omitempty"`
	MaxOutputLength             int           `json:"max_output_length,omitempty"`
	Pricing                     *ModelPricing `json:"pricing,omitempty"`
	SupportedSamplingParameters []string      `json:"supported_sampling_parameters,omitempty"`
	SupportedFeatures           []string      `json:"supported_features,omitempty"`
	DeprecationDate             string        `json:"deprecation_date,omitempty"`

	Metadata ModelMetadata `json:"metadata"`
}

// ModelListResponse is the top-level /v1/models response.
type ModelListResponse struct {
	Object string       `json:"object"`
	Data   []ModelEntry `json:"data"`
}

// ── OpenRouter provider feed (GET /v1/models/openrouter) ─────────────
//
// These types implement OpenRouter's provider "List Models" schema exactly,
// with no Darkbloom-internal fields. Required fields are emitted without
// omitempty so the contract is stable for OpenRouter's validator.

// OpenRouterSlug carries the marketplace slug suggestion.
type OpenRouterSlug struct {
	Slug string `json:"slug"`
}

// OpenRouterDatacenter is one serving location (ISO 3166-1 alpha-2 country).
type OpenRouterDatacenter struct {
	CountryCode string `json:"country_code"`
}

// OpenRouterModel is a single entry in the OpenRouter provider feed.
type OpenRouterModel struct {
	ID                          string                 `json:"id"`
	HuggingFaceID               string                 `json:"hugging_face_id,omitempty"`
	Name                        string                 `json:"name"`
	Created                     int64                  `json:"created"`
	InputModalities             []string               `json:"input_modalities"`
	OutputModalities            []string               `json:"output_modalities"`
	Quantization                string                 `json:"quantization,omitempty"`
	ContextLength               int                    `json:"context_length"`
	MaxOutputLength             int                    `json:"max_output_length"`
	Pricing                     ModelPricing           `json:"pricing"`
	SupportedSamplingParameters []string               `json:"supported_sampling_parameters"`
	SupportedFeatures           []string               `json:"supported_features"`
	Description                 string                 `json:"description,omitempty"`
	DeprecationDate             string                 `json:"deprecation_date,omitempty"`
	IsReady                     bool                   `json:"is_ready"`
	OpenRouter                  *OpenRouterSlug        `json:"openrouter,omitempty"`
	Datacenters                 []OpenRouterDatacenter `json:"datacenters,omitempty"`
}

// OpenRouterModelsResponse is the top-level /v1/models/openrouter response.
type OpenRouterModelsResponse struct {
	Data []OpenRouterModel `json:"data"`
}

// ── Small handler responses ─────────────────────────────────────────

// CreateKeyResponse is the POST /v1/auth/keys response.
type CreateKeyResponse struct {
	APIKey    string `json:"api_key"`
	AccountID string `json:"account_id"`
}

// RevokeKeyResponse is the DELETE /v1/auth/keys response.
type RevokeKeyResponse struct {
	Status string `json:"status"`
}

// ── Multi-key management (GET/POST/PATCH/DELETE /v1/keys) ────────────
//
// APIKeyResponse is the masked, non-secret representation of a single key,
// returned by the list/get/update endpoints. Money is expressed in USD floats
// for ergonomics; the wire never carries the secret after creation.
type APIKeyResponse struct {
	ID            string     `json:"id"`
	Name          string     `json:"name"`
	Label         string     `json:"label"`
	Disabled      bool       `json:"disabled"`
	LimitUSD      *float64   `json:"limit_usd,omitempty"`
	LimitReset    string     `json:"limit_reset"`
	UsageUSD      float64    `json:"usage_usd"`
	RemainingUSD  *float64   `json:"remaining_usd,omitempty"`
	RPMLimit      *int64     `json:"rpm_limit,omitempty"`
	ITPMLimit     *int64     `json:"itpm_limit,omitempty"`
	OTPMLimit     *int64     `json:"otpm_limit,omitempty"`
	AllowedModels []string   `json:"allowed_models,omitempty"`
	SelfRouteOnly bool       `json:"self_route_only"`
	ExpiresAt     *time.Time `json:"expires_at,omitempty"`
	CreatedAt     time.Time  `json:"created_at"`
	LastUsedAt    *time.Time `json:"last_used_at,omitempty"`
}

// APIKeyListResponse is the GET /v1/keys response.
type APIKeyListResponse struct {
	Object string           `json:"object"`
	Data   []APIKeyResponse `json:"data"`
}

// CreateAPIKeyResponse is the POST /v1/keys (and rotate) response. The raw
// secret is included exactly once, alongside the masked metadata.
type CreateAPIKeyResponse struct {
	Key  string         `json:"key"`
	Data APIKeyResponse `json:"data"`
}

// HealthResponse is the GET /health response.
type HealthResponse struct {
	Status      string `json:"status"`
	Providers   int    `json:"providers"`
	Version     string `json:"version"`
	BuildCommit string `json:"build_commit"`
	BuildDate   string `json:"build_date"`
}

// VersionResponse is the GET /api/version response.
type VersionResponse struct {
	Version      string `json:"version"`
	Platform     string `json:"platform,omitempty"`
	Backend      string `json:"backend,omitempty"`
	DownloadURL  string `json:"download_url"`
	BinaryHash   string `json:"binary_hash,omitempty"`
	BundleHash   string `json:"bundle_hash,omitempty"`
	MetallibHash string `json:"metallib_hash,omitempty"`
	Changelog    string `json:"changelog,omitempty"`
}

// BalanceResponse is the GET /v1/payments/balance response.
type BalanceResponse struct {
	BalanceMicroUSD      int64  `json:"balance_micro_usd"`
	BalanceUSD           string `json:"balance_usd"`
	WithdrawableMicroUSD int64  `json:"withdrawable_micro_usd"`
	WithdrawableUSD      string `json:"withdrawable_usd"`
}

// UsageResponse is the GET /v1/payments/usage response.
type UsageResponse struct {
	Usage []payments.UsageEntry `json:"usage"`
}

// ProviderEarningsResponse is the GET /v1/provider/earnings response.
type ProviderEarningsResponse struct {
	BalanceMicroUSD     int64               `json:"balance_micro_usd"`
	BalanceUSD          string              `json:"balance_usd"`
	TotalEarnedMicroUSD int64               `json:"total_earned_micro_usd"`
	TotalEarnedUSD      string              `json:"total_earned_usd"`
	TotalJobs           int                 `json:"total_jobs"`
	Payouts             []payments.Payout   `json:"payouts"`
	Ledger              []store.LedgerEntry `json:"ledger"`
}
