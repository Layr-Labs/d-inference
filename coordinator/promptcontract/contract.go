package promptcontract

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"slices"
	"strings"
)

const (
	NormalizationVersion = "darkbloom-request-normalization-v2"
	RendererVersion      = "swift-jinja-compatible-v1"
	TokenizerVersion     = "huggingface-tokenizer-json-v1"
	BlockHashVersion     = "darkbloom-block-chain-v1"
	BlockSize            = uint32(256)
	MetadataFile         = "prompt-contract.json"
)

var contractDomain = []byte("darkbloom.prompt-contract.v1")

type Artifact struct {
	Path      string `json:"path"`
	Role      string `json:"role"`
	SizeBytes int64  `json:"size_bytes"`
	SHA256    string `json:"sha256"`
}

type Manifest struct {
	ModelID         string
	ModelType       string
	R2Prefix        string
	AggregateSHA256 string
	Files           []Artifact
}

type Versions struct {
	Normalization string `json:"normalization"`
	Renderer      string `json:"renderer"`
	Tokenizer     string `json:"tokenizer"`
	BlockHash     string `json:"block_hash"`
	BlockSize     uint32 `json:"block_size"`
}

type Metadata struct {
	SchemaVersion        int        `json:"schema_version"`
	PromptContractID     string     `json:"prompt_contract_id"`
	ModelID              string     `json:"model_id"`
	ModelType            string     `json:"model_type,omitempty"`
	ModelAggregateSHA256 string     `json:"model_aggregate_sha256"`
	Artifacts            []Artifact `json:"artifacts"`
	Versions             Versions   `json:"versions"`
}

var (
	ErrInvalidArtifact = errors.New("invalid prompt-contract artifact")
	ErrInvalidVersions = errors.New("unsupported prompt-contract versions")
)

func CurrentVersions() Versions {
	return Versions{
		Normalization: NormalizationVersion,
		Renderer:      RendererVersion,
		Tokenizer:     TokenizerVersion,
		BlockHash:     BlockHashVersion,
		BlockSize:     BlockSize,
	}
}

func IsPromptRole(role string) bool {
	return role == "tokenizer" || role == "template" || role == "config"
}

func PromptArtifacts(files []Artifact) ([]Artifact, error) {
	artifacts := make([]Artifact, 0, len(files))
	for _, file := range files {
		if !IsPromptRole(file.Role) {
			continue
		}
		if !validRelativePath(file.Path) || file.SizeBytes < 0 {
			return nil, ErrInvalidArtifact
		}
		if _, err := parseDigest(file.SHA256); err != nil {
			return nil, err
		}
		artifacts = append(artifacts, file)
	}
	if len(artifacts) == 0 {
		return nil, ErrInvalidArtifact
	}
	return artifacts, nil
}

func ContractID(artifacts []Artifact, versions Versions) (string, error) {
	if versions != CurrentVersions() {
		return "", ErrInvalidVersions
	}
	if len(artifacts) == 0 {
		return "", ErrInvalidArtifact
	}
	sorted := slices.Clone(artifacts)
	slices.SortFunc(sorted, func(a, b Artifact) int {
		if result := strings.Compare(a.Role, b.Role); result != 0 {
			return result
		}
		if result := strings.Compare(a.Path, b.Path); result != 0 {
			return result
		}
		return strings.Compare(a.SHA256, b.SHA256)
	})
	if uint64(len(sorted)) > uint64(^uint32(0)) {
		return "", ErrInvalidArtifact
	}

	encoded := make([]byte, 0, 1024)
	var err error
	encoded, err = appendField(encoded, contractDomain)
	if err != nil {
		return "", err
	}
	encoded = binary.BigEndian.AppendUint32(encoded, uint32(len(sorted)))
	for _, artifact := range sorted {
		if !IsPromptRole(artifact.Role) || !validRelativePath(artifact.Path) {
			return "", ErrInvalidArtifact
		}
		digest, err := parseDigest(artifact.SHA256)
		if err != nil {
			return "", err
		}
		if encoded, err = appendField(encoded, []byte(artifact.Role)); err != nil {
			return "", err
		}
		if encoded, err = appendField(encoded, []byte(artifact.Path)); err != nil {
			return "", err
		}
		if encoded, err = appendField(encoded, digest); err != nil {
			return "", err
		}
	}
	for _, field := range [][2]string{
		{"normalization", versions.Normalization},
		{"renderer", versions.Renderer},
		{"tokenizer", versions.Tokenizer},
		{"block_hash", versions.BlockHash},
	} {
		if encoded, err = appendField(encoded, []byte(field[0])); err != nil {
			return "", err
		}
		if encoded, err = appendField(encoded, []byte(field[1])); err != nil {
			return "", err
		}
	}
	if encoded, err = appendField(encoded, []byte("block_size")); err != nil {
		return "", err
	}
	encoded = binary.BigEndian.AppendUint32(encoded, versions.BlockSize)
	digest := sha256.Sum256(encoded)
	return hex.EncodeToString(digest[:]), nil
}

func appendField(output, value []byte) ([]byte, error) {
	if uint64(len(value)) > uint64(^uint32(0)) {
		return nil, ErrInvalidArtifact
	}
	output = binary.BigEndian.AppendUint32(output, uint32(len(value)))
	return append(output, value...), nil
}

func parseDigest(value string) ([]byte, error) {
	if len(value) != sha256.Size*2 || value != strings.ToLower(value) {
		return nil, ErrInvalidArtifact
	}
	decoded, err := hex.DecodeString(value)
	if err != nil || len(decoded) != sha256.Size {
		return nil, ErrInvalidArtifact
	}
	return decoded, nil
}

func validRelativePath(value string) bool {
	if value == "" || strings.HasPrefix(value, "/") || strings.Contains(value, "\\") {
		return false
	}
	for part := range strings.SplitSeq(value, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}
