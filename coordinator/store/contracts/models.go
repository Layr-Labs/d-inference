package contracts

import (
	"time"
)

// SupportedModel is the lightweight in-memory shape the model-listing and
// routing code uses to describe a servable model. It is derived from the
// canonical model_registry (see supportedModelFromRegistryRecord); it is no
// longer a standalone persisted catalog. The coordinator remains the single
// source of truth for which models providers can serve.
//
// ModelType determines routing: "text" for chat/completions, "embedding" for
// vector search, etc.
type SupportedModel struct {
	ID                           string   `json:"id"`           // HuggingFace path (e.g. "mlx-community/Qwen3.5-9B-MLX-4bit")
	S3Name                       string   `json:"s3_name"`      // CDN key for download (e.g. "Qwen3.5-9B-MLX-4bit")
	DisplayName                  string   `json:"display_name"` // Human-readable (e.g. "Qwen3.5 9B")
	ModelType                    string   `json:"model_type"`   // "text", "embedding", "tts"
	SizeGB                       float64  `json:"size_gb"`      // Disk/memory size in GB
	Architecture                 string   `json:"architecture"` // e.g. "9B dense", "2B conformer"
	Description                  string   `json:"description"`  // e.g. "Balanced", "Fast reasoning"
	MinRAMGB                     int      `json:"min_ram_gb"`   // Minimum system RAM for auto-selection
	Active                       bool     `json:"active"`       // Whether available for use
	WeightHash                   string   `json:"weight_hash"`  // Expected SHA-256 fingerprint of model weight files
	RequiredProviderCapabilities []string `json:"required_provider_capabilities"`
}

// ModelRegistryEntry is the canonical admin-managed model catalog row.
type ModelRegistryEntry struct {
	ID                           string         `json:"id"`
	DisplayName                  string         `json:"display_name"`
	Family                       string         `json:"family"`
	Architecture                 string         `json:"architecture"`
	Quantization                 string         `json:"quantization"`
	MaxContextLength             int            `json:"max_context_length"`
	MaxOutputLength              int            `json:"max_output_length"`
	MinRAMGB                     int            `json:"min_ram_gb"`
	Capabilities                 []string       `json:"capabilities"`
	RequiredProviderCapabilities []string       `json:"required_provider_capabilities"`
	Status                       string         `json:"status"`
	Description                  string         `json:"description"`
	RuntimeParameters            map[string]any `json:"runtime_parameters"`
	Metadata                     map[string]any `json:"metadata"`
	CreatedAt                    time.Time      `json:"created_at"`
	UpdatedAt                    time.Time      `json:"updated_at"`
}

// ModelVersion is an uploaded manifest version for a registered model.
type ModelVersion struct {
	HuggingFaceArtifact *HuggingFaceArtifact `json:"hugging_face_artifact,omitempty"`
	ID                  int64                `json:"id"`
	ModelID             string               `json:"model_id"`
	Version             string               `json:"version"`
	R2Prefix            string               `json:"r2_prefix"`
	AggregateSHA256     string               `json:"aggregate_sha256"`
	TotalSizeBytes      int64                `json:"total_size_bytes"`
	FileCount           int                  `json:"file_count"`
	Status              string               `json:"status"`
	UploadedBy          string               `json:"uploaded_by,omitempty"`
	UploadedAt          time.Time            `json:"uploaded_at"`
	PromotedAt          *time.Time           `json:"promoted_at,omitempty"`
	Metadata            map[string]any       `json:"metadata"`
}

// ModelVersionFile is one file in a model version manifest.
type ModelVersionFile struct {
	ID             int64  `json:"id"`
	ModelVersionID int64  `json:"model_version_id"`
	Path           string `json:"path"`
	SizeBytes      int64  `json:"size_bytes"`
	SHA256         string `json:"sha256"`
	Role           string `json:"role"`
}

// ModelRegistryRecord combines a model with its active version and files.
type ModelRegistryRecord struct {
	ModelRegistryEntry
	ActiveVersion *ModelVersion      `json:"active_version,omitempty"`
	Files         []ModelVersionFile `json:"files,omitempty"`
}

type ModelAliasSourceKind string

const (
	// ModelAliasSourceAlias follows an active standard alias's rollout pointers.
	// It is also the backward-compatible meaning of an empty source_kind.
	ModelAliasSourceAlias ModelAliasSourceKind = "standard_alias"
	// ModelAliasSourceConcrete pins routing and feed cloning to one concrete model.
	ModelAliasSourceConcrete ModelAliasSourceKind = "concrete_model"
)

// ModelAlias has two forms. A standard alias is a stable consumer-facing name
// resolving to one desired concrete build plus an optional previous build while
// providers converge. An OpenRouter-only alias clones either a standard alias or
// an active concrete catalog model for marketplace identity and request routing.
// It never drives provider convergence, hides its source, or becomes the
// canonical public name for a concrete build.
type ModelAlias struct {
	AliasID        string               `json:"alias_id"`
	DisplayName    string               `json:"display_name"`
	OpenRouterOnly bool                 `json:"openrouter_only,omitempty"` // marketplace clone; excluded from provider convergence and canonical naming
	SourceModel    string               `json:"source_model,omitempty"`    // standard alias or concrete catalog model cloned by an OpenRouter-only entry
	SourceKind     ModelAliasSourceKind `json:"source_kind,omitempty"`     // source identity semantics; empty legacy values mean standard_alias
	OpenRouterSlug string               `json:"openrouter_slug,omitempty"` // marketplace identity for an OpenRouter-only entry
	HuggingFaceID  string               `json:"hugging_face_id,omitempty"` // metadata repository for an OpenRouter-only entry
	DesiredBuild   string               `json:"desired_build"`             // the single build providers should converge to
	PreviousBuild  string               `json:"previous_build,omitempty"`  // still-acceptable during rollout; "" when none

	// RetiredBuilds is the alias's lineage: former desired/previous builds
	// rotated out by later upserts. Kept so a provider that was offline through
	// a retirement (still advertising only a retired build) is recognized as
	// part of this alias's fleet at re-registration and told to converge. A
	// build promoted back to desired/previous leaves this list. Bounded; oldest
	// entries dropped first.
	RetiredBuilds []string  `json:"retired_builds,omitempty"`
	Active        bool      `json:"active"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// ModelManifest mirrors the minimal darkbloom-publish manifest JSON.
type ModelManifest struct {
	SchemaVersion   int            `json:"schema_version"`
	ModelID         string         `json:"model_id"`
	Version         string         `json:"version"`
	R2Prefix        string         `json:"r2_prefix"`
	AggregateSHA256 string         `json:"aggregate_sha256"`
	TotalSizeBytes  int64          `json:"total_size_bytes"`
	FileCount       int            `json:"file_count"`
	Files           []ManifestFile `json:"files"`
	CreatedAt       time.Time      `json:"created_at"`
}

// ManifestFile mirrors a file entry in a model manifest.
type ManifestFile struct {
	Path      string `json:"path"`
	SizeBytes int64  `json:"size_bytes"`
	SHA256    string `json:"sha256"`
	Role      string `json:"role"`
}

// PublishingAPIKey stores a hashed key allowed to publish model manifests.
type PublishingAPIKey struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	KeyHash    string     `json:"key_hash"`
	Active     bool       `json:"active"`
	CreatedAt  time.Time  `json:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty"`
}

// ModelRegistryStore is the manifest-backed model catalog plus the
// public-facing model aliases that resolve to concrete builds.
type ModelRegistryStore interface {
	// --- Model Registry (manifest-backed catalog) ---

	UpsertModelRegistryEntry(entry *ModelRegistryEntry) error
	SetModelVersion(entry *ModelRegistryEntry, version *ModelVersion, files []ModelVersionFile) error
	PromoteModelVersion(modelID, version string) error
	SetModelStatus(modelID, status string) error
	ListActiveModelRegistry() []ModelRegistryRecord
	ListActiveModelRegistryWithError() ([]ModelRegistryRecord, error)
	GetModelRegistryRecord(modelID string) (*ModelRegistryRecord, error)
	GetModelManifest(modelID string) (*ModelManifest, error)
	UpsertPublishingAPIKey(key *PublishingAPIKey) error
	FindPublishingAPIKeys() []PublishingAPIKey
	FindPublishingAPIKeysWithError() ([]PublishingAPIKey, error)
	MarkPublishingAPIKeyUsed(id string) error

	// --- Model Aliases (public-facing names → a desired concrete build) ---

	// UpsertModelAlias creates or replaces an alias definition (idempotent on
	// AliasID). The DesiredBuild/PreviousBuild pointers are stored verbatim;
	// resolution happens in the registry.
	UpsertModelAlias(alias *ModelAlias) error
	// GetModelAlias returns the alias by id; ok is false when not found.
	GetModelAlias(aliasID string) (alias *ModelAlias, ok bool, err error)
	// ListModelAliases returns every alias (active and inactive).
	ListModelAliases() ([]ModelAlias, error)
	// DeleteModelAlias removes an alias definition.
	DeleteModelAlias(aliasID string) error
}
