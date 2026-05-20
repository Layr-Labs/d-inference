// Package types holds shared API response type definitions.
//
// These structs are the canonical JSON shapes for all consumer-facing
// endpoints. They are extracted from the api package so they can be
// used by tests, tooling, and external consumers without importing
// the full handler package.
package types

import (
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
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
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
type ResponsesResponse struct {
	ID               string                     `json:"id"`
	Object           string                     `json:"object"`
	CreatedAt        int64                      `json:"created_at"`
	Model            string                     `json:"model"`
	Output           []any                      `json:"output"`
	Usage            ResponsesUsage             `json:"usage"`
	IncompleteDetail *ResponsesIncompleteDetail `json:"incomplete_details"`
	SESignature      string                     `json:"se_signature,omitempty"`
	ResponseHash     string                     `json:"response_hash,omitempty"`
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

// ModelEntry is a single model entry in the /v1/models response.
type ModelEntry struct {
	ID       string        `json:"id"`
	Object   string        `json:"object"`
	Created  int           `json:"created"`
	OwnedBy  string        `json:"owned_by"`
	Metadata ModelMetadata `json:"metadata"`
}

// ModelListResponse is the top-level /v1/models response.
type ModelListResponse struct {
	Object string       `json:"object"`
	Data   []ModelEntry `json:"data"`
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

// HealthResponse is the GET /health response.
type HealthResponse struct {
	Status    string `json:"status"`
	Providers int    `json:"providers"`
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
