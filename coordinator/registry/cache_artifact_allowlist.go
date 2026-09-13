package registry

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
)

const (
	cacheArtifactAllowlistEnv = "EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS"
	maxCacheArtifactJSONBytes = 64 << 10
	maxCacheArtifacts         = 128
)

// CacheRoutingArtifact names one verified artifact, not a model family or alias.
// A nil configuration list is unrestricted; an explicitly empty list denies all.
type CacheRoutingArtifact struct {
	ModelID              string `json:"model_id"`
	ModelAggregateSHA256 string `json:"model_aggregate_sha256"`
	PromptContractID     string `json:"prompt_contract_id"`
}

// Reject duplicate and unknown fields rather than accepting JSON's usual
// last-value-wins behavior for an operational allowlist.
func (a *CacheRoutingArtifact) UnmarshalJSON(data []byte) error {
	d := json.NewDecoder(strings.NewReader(string(data)))
	if token, err := d.Token(); err != nil || token != json.Delim('{') {
		return fmt.Errorf("artifact must be an object")
	}
	var decoded CacheRoutingArtifact
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

func readCacheRoutingArtifacts() ([]CacheRoutingArtifact, error) {
	raw, present := os.LookupEnv(cacheArtifactAllowlistEnv)
	if !present {
		return nil, nil
	}
	if len(raw) > maxCacheArtifactJSONBytes {
		return nil, fmt.Errorf("artifact allowlist exceeds %d bytes", maxCacheArtifactJSONBytes)
	}
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(raw, "[") {
		return nil, fmt.Errorf("artifact allowlist must be a JSON array; use [] to deny all")
	}
	var artifacts []CacheRoutingArtifact
	d := json.NewDecoder(strings.NewReader(raw))
	if err := d.Decode(&artifacts); err != nil {
		return nil, fmt.Errorf("invalid artifact allowlist: %w", err)
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return nil, fmt.Errorf("artifact allowlist must contain exactly one JSON array")
	}
	return artifacts, nil
}

// This map is built during configuration and never mutated after publication.
// Readers may keep its snapshot after dropping the registry lock.
type cacheArtifactAllowlist map[CacheRoutingArtifact]struct{}

func newCacheArtifactAllowlist(artifacts []CacheRoutingArtifact) (cacheArtifactAllowlist, error) {
	if artifacts == nil {
		return nil, nil
	}
	if len(artifacts) > maxCacheArtifacts {
		return nil, fmt.Errorf("artifact allowlist exceeds %d entries", maxCacheArtifacts)
	}
	allowed := make(cacheArtifactAllowlist, len(artifacts))
	for i, artifact := range artifacts {
		if artifact.ModelID == "" || len(artifact.ModelID) > 512 ||
			strings.TrimSpace(artifact.ModelID) != artifact.ModelID ||
			strings.ContainsAny(artifact.ModelID, "\x00\r\n\t*") ||
			!validLowerHex256(artifact.ModelAggregateSHA256) ||
			!validLowerHex256(artifact.PromptContractID) {
			return nil, fmt.Errorf("artifact %d requires an exact model ID and lowercase SHA-256 identities", i)
		}
		if _, duplicate := allowed[artifact]; duplicate {
			return nil, fmt.Errorf("artifact %d duplicates an earlier tuple", i)
		}
		allowed[artifact] = struct{}{}
	}
	return allowed, nil
}

func (a cacheArtifactAllowlist) allows(input CachePlanInput) bool {
	if a == nil {
		return true
	}
	_, ok := a[CacheRoutingArtifact{
		ModelID: input.Model, ModelAggregateSHA256: input.ModelAggregateSHA256,
		PromptContractID: input.PromptContractID,
	}]
	return ok
}

func (a cacheArtifactAllowlist) snapshot() []CacheRoutingArtifact {
	if a == nil {
		return nil
	}
	artifacts := make([]CacheRoutingArtifact, 0, len(a))
	for artifact := range a {
		artifacts = append(artifacts, artifact)
	}
	slices.SortFunc(artifacts, func(x, y CacheRoutingArtifact) int {
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
