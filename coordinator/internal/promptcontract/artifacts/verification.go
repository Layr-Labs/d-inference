package artifacts

import (
	"crypto/sha256"
	"encoding/json"
	"io"
	"os"
	"path"
	"slices"
	"strings"

	identity "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"
)

func VerifyPublished(root *os.Root, contractID string) (bool, error) {
	info, err := root.Lstat(contractID)
	if err != nil {
		return false, err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return false, ErrArtifactIntegrity
	}
	contractDirectory, err := secureOpenDirectory(root, contractID, false, 0)
	if err != nil {
		return false, ErrArtifactIntegrity
	}
	defer contractDirectory.Close()
	file, err := secureOpenRegular(root, path.Join(contractID, identity.MetadataFile))
	if err != nil {
		return false, ErrArtifactIntegrity
	}
	defer file.Close()
	metadataInfo, err := file.Stat()
	if err != nil || metadataInfo.Size() > maxMetadataBytes {
		return false, ErrArtifactIntegrity
	}
	encoded, err := io.ReadAll(io.LimitReader(file, maxMetadataBytes+1))
	if err != nil || len(encoded) > maxMetadataBytes {
		return false, ErrArtifactIntegrity
	}
	var metadata identity.Metadata
	if json.Unmarshal(encoded, &metadata) != nil ||
		metadata.SchemaVersion != 1 ||
		metadata.PromptContractID != contractID ||
		metadata.Versions != identity.CurrentVersions() {
		return false, ErrArtifactIntegrity
	}
	recomputed, err := identity.ContractID(metadata.Artifacts, metadata.Versions)
	if err != nil || recomputed != contractID {
		return false, ErrArtifactIntegrity
	}
	for _, artifact := range metadata.Artifacts {
		if err := VerifyPublishedArtifact(root, contractID, artifact); err != nil {
			return false, err
		}
	}
	return true, nil
}

func VerifyPublishedArtifact(root *os.Root, contractID string, artifact identity.Artifact) error {
	if !identity.IsPromptRole(artifact.Role) ||
		!identity.ValidRelativePath(artifact.Path) ||
		artifact.SizeBytes < 0 ||
		artifact.SizeBytes > maxArtifactBytes {
		return ErrArtifactIntegrity
	}
	file, err := secureOpenRegular(root, path.Join(contractID, artifact.Path))
	if err != nil {
		return ErrArtifactIntegrity
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() != artifact.SizeBytes {
		return ErrArtifactIntegrity
	}
	hasher := sha256.New()
	written, err := io.Copy(hasher, io.LimitReader(file, artifact.SizeBytes+1))
	if err != nil || written != artifact.SizeBytes {
		return ErrArtifactIntegrity
	}
	expected, err := identity.ParseDigest(artifact.SHA256)
	if err != nil || !equalBytes(hasher.Sum(nil), expected) {
		return ErrArtifactIntegrity
	}
	return nil
}

func verifyManifestAggregate(manifest identity.Manifest) error {
	if manifest.ModelID == "" || !identity.ValidRelativePath(manifest.R2Prefix) {
		return ErrArtifactIntegrity
	}
	files := slices.Clone(manifest.Files)
	slices.SortFunc(files, func(a, b identity.Artifact) int {
		if result := strings.Compare(a.Path, b.Path); result != 0 {
			return result
		}
		return strings.Compare(a.SHA256, b.SHA256)
	})
	hasher := sha256.New()
	for _, file := range files {
		if !identity.ValidRelativePath(file.Path) || file.SizeBytes < 0 {
			return ErrArtifactIntegrity
		}
		digest, err := identity.ParseDigest(file.SHA256)
		if err != nil {
			return ErrArtifactIntegrity
		}
		_, _ = hasher.Write(digest)
	}
	expected, err := identity.ParseDigest(manifest.AggregateSHA256)
	if err != nil || !equalBytes(hasher.Sum(nil), expected) {
		return ErrArtifactIntegrity
	}
	return nil
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var mismatch byte
	for i := range a {
		mismatch |= a[i] ^ b[i]
	}
	return mismatch == 0
}
