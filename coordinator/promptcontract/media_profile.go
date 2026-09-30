package promptcontract

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"path"

	"github.com/eigeninference/d-inference/coordinator/mediawork"
)

// mediaProfile runs only in the bounded background provisioner. Read the same
// verified config bytes as the provider, with no inference-path file or URL IO.
// Unsupported/missing configuration leaves optional accounting unavailable.
func (c *ArtifactCache) mediaProfile(manifest Manifest) *mediawork.Profile {
	artifacts, err := PromptArtifacts(manifest.Files)
	if err != nil {
		return nil
	}
	id, err := ContractID(artifacts, CurrentVersions())
	if err != nil {
		return nil
	}
	var config *Artifact
	for i := range artifacts {
		if artifacts[i].Path == "config.json" && artifacts[i].Role == "config" {
			if config != nil {
				return nil
			}
			config = &artifacts[i]
		}
	}
	if config == nil || config.SizeBytes <= 0 || config.SizeBytes > 1<<20 {
		return nil
	}
	root, err := openVerifiedRoot(c.root, 0o700)
	if err != nil {
		return nil
	}
	defer root.Close()
	f, err := secureOpenRegular(root, path.Join(id, config.Path))
	if err != nil {
		return nil
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, config.SizeBytes+1))
	if err != nil || int64(len(data)) != config.SizeBytes {
		return nil
	}
	digest := sha256.Sum256(data)
	if hex.EncodeToString(digest[:]) != config.SHA256 {
		return nil
	}
	return mediawork.FromConfig(data)
}
