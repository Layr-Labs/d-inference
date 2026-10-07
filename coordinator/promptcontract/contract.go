package promptcontract

import "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"

const (
	NormalizationVersion = identity.NormalizationVersion
	RendererVersion      = identity.RendererVersion
	TokenizerVersion     = identity.TokenizerVersion
	BlockHashVersion     = identity.BlockHashVersion
	BlockSize            = identity.BlockSize
	MetadataFile         = identity.MetadataFile
)

type Artifact = identity.Artifact
type Manifest = identity.Manifest
type Versions = identity.Versions
type Metadata = identity.Metadata

var (
	ErrInvalidArtifact  = identity.ErrInvalidArtifact
	ErrInvalidVersions  = identity.ErrInvalidVersions
	ErrIdentityTooLarge = identity.ErrIdentityTooLarge
)

func CurrentVersions() Versions                            { return identity.CurrentVersions() }
func IsPromptRole(role string) bool                        { return identity.IsPromptRole(role) }
func PromptArtifacts(files []Artifact) ([]Artifact, error) { return identity.PromptArtifacts(files) }
func ContractID(artifacts []Artifact, versions Versions) (string, error) {
	return identity.ContractID(artifacts, versions)
}
func BlockHash(contractID, scopeID []byte, parent [32]byte, blockIndex uint32, tokens []uint32) ([32]byte, error) {
	return identity.BlockHash(contractID, scopeID, parent, blockIndex, tokens)
}
func LastCompleteBoundary(tokenCount, blockSize int) (int, bool) {
	return identity.LastCompleteBoundary(tokenCount, blockSize)
}
