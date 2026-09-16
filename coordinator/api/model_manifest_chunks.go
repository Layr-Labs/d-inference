package api

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Requirements follow the active transport as well as operator metadata.
// Registering another (unchunked) version must not remove the protection from
// an active chunked version before that replacement is promoted.
func modelTransportCapabilities(rec *store.ModelRegistryRecord) []string {
	capabilities := append([]string{}, rec.RequiredProviderCapabilities...)
	for _, capability := range capabilities {
		if capability == registry.ProviderCapabilityR2Chunks {
			return capabilities
		}
	}
	for _, file := range rec.Files {
		if len(file.R2Chunks) > 0 {
			return append(capabilities, registry.ProviderCapabilityR2Chunks)
		}
	}
	return capabilities
}

func validateChunkCapability(manifest *store.ModelManifest, capabilities []string) error {
	for _, file := range manifest.Files {
		if len(file.R2Chunks) == 0 {
			continue
		}
		for _, capability := range capabilities {
			if capability == registry.ProviderCapabilityR2Chunks {
				return nil
			}
		}
		return fmt.Errorf("chunked manifests require provider capability %q", registry.ProviderCapabilityR2Chunks)
	}
	return nil
}

func validateManifestChunks(manifest *store.ModelManifest) error {
	count := 0
	for _, file := range manifest.Files {
		if file.R2Chunks == nil {
			continue
		}
		if len(file.R2Chunks) == 0 {
			return fmt.Errorf("empty r2_chunks for %q", file.Path)
		}
		count += len(file.R2Chunks)
		if count > 4096 {
			return fmt.Errorf("manifest exceeds 4096 R2 chunks")
		}
		var total int64
		for _, chunk := range file.R2Chunks {
			if chunk.SizeBytes <= 0 || chunk.SizeBytes >= 500_000_000 || !isLowerSHA256Hex(chunk.SHA256) {
				return fmt.Errorf("invalid R2 chunk for %q: expected 1..499999999 bytes and SHA-256", file.Path)
			}
			if chunk.SizeBytes > file.SizeBytes-total {
				return fmt.Errorf("R2 chunk sizes exceed %q", file.Path)
			}
			total += chunk.SizeBytes
		}
		if total != file.SizeBytes {
			return fmt.Errorf("R2 chunk sizes do not sum to %q", file.Path)
		}
		// Transport objects and local reconstruction directories cannot overlap
		// logical model files (including on case-insensitive provider volumes).
		for _, other := range manifest.Files {
			for _, suffix := range []string{".chunks", ".r2-transfer"} {
				reserved := strings.ToLower(file.Path + suffix)
				path := strings.ToLower(other.Path)
				if path == reserved || strings.HasPrefix(path, reserved+"/") {
					return fmt.Errorf("file %q overlaps chunk storage", other.Path)
				}
			}
		}
	}
	return nil
}

func verifyManifestTransportHEAD(ctx context.Context, client *http.Client, baseURL, prefix string, file store.ManifestFile, logger interface{ Warn(string, ...any) }) error {
	if len(file.R2Chunks) == 0 {
		return verifyManifestFileHEAD(ctx, client, baseURL, prefix, file, logger)
	}
	for index, chunk := range file.R2Chunks {
		object := store.ManifestFile{
			Path:      fmt.Sprintf("%s.chunks/%06d.bin", file.Path, index),
			SizeBytes: chunk.SizeBytes, SHA256: chunk.SHA256,
		}
		if err := verifyManifestFileHEAD(ctx, client, baseURL, prefix, object, logger); err != nil {
			return err
		}
	}
	return nil
}
