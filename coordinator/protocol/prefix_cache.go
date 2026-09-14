package protocol

const PrefixCacheReadyBoundaryCheckpoint = "checkpoint"

// PrefixCacheV2Capability binds one live model slot to the exact artifacts and
// cache generation for which protocol-v2 evidence is valid. The containing
// snapshot names the tier: prefix_cache_v2_models is durable SSD, while the
// additive prefix_cache_memory_models snapshot describes ephemeral resident KV.
type PrefixCacheV2Capability struct {
	ModelID            string `json:"model_id"`
	ModelAggregateHash string `json:"model_aggregate_hash"`
	PromptContractID   string `json:"prompt_contract_id"`
	BlockHashVersion   string `json:"block_hash_version"`
	BlockSize          uint32 `json:"block_size"`
	CacheEpoch         string `json:"cache_epoch"`
	Enabled            bool   `json:"enabled"`
	Ready              bool   `json:"ready"`
	// Empty retains legacy durable coverage through the prompt floor.
	// Checkpoint mode advertises only explicitly committed input endpoints.
	ReadyBoundaryMode string `json:"ready_boundary_mode,omitempty"`
}

// PrefixCacheModelStatus is a content-free status for one concrete loaded
// model slot. Every dimension is a fixed enum validated at the coordinator
// boundary; no cache identity, provider identity, path, hash, or request data
// is carried.
type PrefixCacheModelStatus struct {
	ModelID        string `json:"model_id"`
	Backend        string `json:"backend"`
	ReplayStrategy string `json:"replay_strategy"`
	State          string `json:"state"`
	Reason         string `json:"reason"`
}

// PrefixCacheDonationOutcomeCount is one cumulative, process-local counter
// from the provider's SSD donation path. Outcome is a fixed enum; Count is
// monotonic for the lifetime of the provider process.
type PrefixCacheDonationOutcomeCount struct {
	Outcome string `json:"outcome"`
	Count   uint64 `json:"count"`
}

// PrefixCacheLookupMessage is a nonce-bound provider receipt describing the
// lookup performed for one inference attempt.
type PrefixCacheLookupMessage struct {
	Type               string  `json:"type"`
	RequestID          string  `json:"request_id"`
	CacheReceiptNonce  string  `json:"cache_receipt_nonce"`
	Outcome            string  `json:"outcome"`
	Tier               string  `json:"tier,omitempty"`
	CachedTokens       int     `json:"cached_tokens,omitempty"`
	PrefillTokensSaved int     `json:"prefill_tokens_saved,omitempty"`
	StageMs            float64 `json:"stage_ms,omitempty"`
}

// PrefixCacheReadyMessage confirms that reusable prefix state is ready after
// an inference attempt. Ready receipts may arrive after inference_complete.
type PrefixCacheReadyMessage struct {
	Type                       string  `json:"type"`
	RequestID                  string  `json:"request_id"`
	CacheReceiptNonce          string  `json:"cache_receipt_nonce"`
	ReadyTokens                int     `json:"ready_tokens"`
	RequiredRecomputeTokens    int     `json:"required_recompute_tokens,omitempty"`
	ExpectedPrefillTokensSaved int     `json:"expected_prefill_tokens_saved,omitempty"`
	Tier                       string  `json:"tier,omitempty"`
	StageMs                    float64 `json:"stage_ms,omitempty"`
}

// PrefixCacheAnchor is a bounded, provider-computed DBK3 block-chain
// boundary. ChainHash is lowercase SHA-256 hex and TokenCount is block-aligned.
type PrefixCacheAnchor struct {
	ChainHash  string `json:"chain_hash"`
	TokenCount int    `json:"token_count"`
}

// PrefixCacheLookupV2Message proves the exact prompt boundary and actual
// provider lookup result for one nonce-bound attempt.
type PrefixCacheLookupV2Message struct {
	Type                       string             `json:"type"`
	RequestID                  string             `json:"request_id"`
	CacheReceiptNonce          string             `json:"cache_receipt_nonce"`
	ModelID                    string             `json:"model_id"`
	ModelAggregateHash         string             `json:"model_aggregate_hash"`
	PromptContractID           string             `json:"prompt_contract_id"`
	CacheEpoch                 string             `json:"cache_epoch"`
	CacheSeq                   uint64             `json:"cache_seq"`
	PromptAnchor               PrefixCacheAnchor  `json:"prompt_anchor"`
	MatchedAnchor              *PrefixCacheAnchor `json:"matched_anchor,omitempty"`
	Outcome                    string             `json:"outcome"`
	Tier                       string             `json:"tier,omitempty"`
	RequiredRecomputeTokens    int                `json:"required_recompute_tokens,omitempty"`
	ExpectedPrefillTokensSaved int                `json:"expected_prefill_tokens_saved,omitempty"`
	StageMs                    float64            `json:"stage_ms,omitempty"`
}

// PrefixCacheReadyV2Message reports a published reusable boundary. SSD evidence
// requires durable settlement and is bounded to the prompt and continuation.
// Memory evidence requires a separately advertised resident capability and may
// name up to 16 actually reusable, coordinator-verified input prompt boundaries.
type PrefixCacheReadyV2Message struct {
	Type                       string              `json:"type"`
	RequestID                  string              `json:"request_id"`
	CacheReceiptNonce          string              `json:"cache_receipt_nonce"`
	ModelID                    string              `json:"model_id"`
	ModelAggregateHash         string              `json:"model_aggregate_hash"`
	PromptContractID           string              `json:"prompt_contract_id"`
	CacheEpoch                 string              `json:"cache_epoch"`
	CacheSeq                   uint64              `json:"cache_seq"`
	Outcome                    string              `json:"outcome"`
	Tier                       string              `json:"tier"`
	ReadyAnchors               []PrefixCacheAnchor `json:"ready_anchors"`
	RequiredRecomputeTokens    int                 `json:"required_recompute_tokens,omitempty"`
	ExpectedPrefillTokensSaved int                 `json:"expected_prefill_tokens_saved,omitempty"`
	StageMs                    float64             `json:"stage_ms,omitempty"`
}
