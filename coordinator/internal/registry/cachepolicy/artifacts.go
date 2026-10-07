package cachepolicy

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
)

const (
	ArtifactAllowlistEnv = "EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS"
	MaxArtifactJSONBytes = 64 << 10
	MaxArtifacts         = 128
)

// Artifact names one verified build, not a model family or alias.
type Artifact struct {
	ModelID              string `json:"model_id"`
	ModelAggregateSHA256 string `json:"model_aggregate_sha256"`
	PromptContractID     string `json:"prompt_contract_id"`
}

// Reject duplicate and unknown fields instead of last-value-wins JSON.
func (a *Artifact) UnmarshalJSON(data []byte) error {
	d := json.NewDecoder(strings.NewReader(string(data)))
	if token, err := d.Token(); err != nil || token != json.Delim('{') {
		return fmt.Errorf("artifact must be an object")
	}
	var decoded Artifact
	seen := uint8(0)
	for d.More() {
		field, err := d.Token()
		if err != nil {
			return err
		}
		var target *string
		var bit uint8
		switch field {
		case "model_id":
			target, bit = &decoded.ModelID, 1
		case "model_aggregate_sha256":
			target, bit = &decoded.ModelAggregateSHA256, 2
		case "prompt_contract_id":
			target, bit = &decoded.PromptContractID, 4
		default:
			return fmt.Errorf("artifact contains an unknown field")
		}
		if seen&bit != 0 {
			return fmt.Errorf("artifact contains a duplicate field")
		}
		seen |= bit
		if err := d.Decode(target); err != nil {
			return fmt.Errorf("artifact fields must be strings")
		}
	}
	if _, err := d.Token(); err != nil {
		return err
	}
	if seen != 7 {
		return fmt.Errorf("artifact requires all three identity fields")
	}
	*a = decoded
	return nil
}

func ReadArtifacts() ([]Artifact, error) {
	raw, present := os.LookupEnv(ArtifactAllowlistEnv)
	if !present {
		return nil, nil
	}
	if len(raw) > MaxArtifactJSONBytes {
		return nil, fmt.Errorf("artifact allowlist exceeds %d bytes", MaxArtifactJSONBytes)
	}
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(raw, "[") {
		return nil, fmt.Errorf("artifact allowlist must be a JSON array; use [] to deny all")
	}
	var artifacts []Artifact
	d := json.NewDecoder(strings.NewReader(raw))
	if err := d.Decode(&artifacts); err != nil {
		return nil, fmt.Errorf("invalid artifact allowlist: %w", err)
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return nil, fmt.Errorf("artifact allowlist must contain exactly one JSON array")
	}
	return artifacts, nil
}

// ArtifactAllowlist is immutable after construction. Nil is unrestricted;
// an explicitly empty list constructs a non-nil set that denies everything.
type ArtifactAllowlist struct {
	allowed map[Artifact]struct{}
	models  map[string]struct{}
}

func NewArtifactAllowlist(artifacts []Artifact) (*ArtifactAllowlist, error) {
	if artifacts == nil {
		return nil, nil
	}
	if len(artifacts) > MaxArtifacts {
		return nil, fmt.Errorf("artifact allowlist exceeds %d entries", MaxArtifacts)
	}
	allowed := make(map[Artifact]struct{}, len(artifacts))
	models := make(map[string]struct{}, len(artifacts))
	for i, artifact := range artifacts {
		if artifact.ModelID == "" || len(artifact.ModelID) > 512 ||
			strings.TrimSpace(artifact.ModelID) != artifact.ModelID || strings.ContainsAny(artifact.ModelID, "\x00\r\n\t*") ||
			!LowerHex256(artifact.ModelAggregateSHA256) || !LowerHex256(artifact.PromptContractID) {
			return nil, fmt.Errorf("artifact %d requires an exact model ID and lowercase SHA-256 identities", i)
		}
		if _, duplicate := allowed[artifact]; duplicate {
			return nil, fmt.Errorf("artifact %d duplicates an earlier tuple", i)
		}
		allowed[artifact] = struct{}{}
		models[artifact.ModelID] = struct{}{}
	}
	return &ArtifactAllowlist{allowed: allowed, models: models}, nil
}

func (a *ArtifactAllowlist) Allows(artifact Artifact) bool {
	if a == nil {
		return true
	}
	_, ok := a.allowed[artifact]
	return ok
}

// StaleFor reports that the list names live's model only under other
// identities. A weight or template revision changes the tuple, so the model
// stays out of cache routing until an operator appends the live one. A model
// the list never named is excluded on purpose and is not stale.
func (a *ArtifactAllowlist) StaleFor(live Artifact) bool {
	if a == nil {
		return false
	}
	_, named := a.models[live.ModelID]
	return named && !a.Allows(live)
}

// Snapshot detaches the canonical configuration for public status/configuration.
func (a *ArtifactAllowlist) Snapshot() []Artifact {
	if a == nil {
		return nil
	}
	artifacts := make([]Artifact, 0, len(a.allowed))
	for artifact := range a.allowed {
		artifacts = append(artifacts, artifact)
	}
	slices.SortFunc(artifacts, func(x, y Artifact) int {
		if c := strings.Compare(x.ModelID, y.ModelID); c != 0 {
			return c
		}
		if c := strings.Compare(x.ModelAggregateSHA256, y.ModelAggregateSHA256); c != 0 {
			return c
		}
		return strings.Compare(x.PromptContractID, y.PromptContractID)
	})
	return artifacts
}
