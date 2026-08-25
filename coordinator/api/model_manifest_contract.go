package api

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"math"
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// These limits are the schema-v1 transport/structure contract shared with the
// Swift provider. Keep the values aligned with ModelManifestContract.
const (
	maxModelManifestBytes     int64 = 1 << 20
	maxModelManifestFileCount       = 16_384
)

func validateModelManifest(manifest *store.ModelManifest, modelID, version, r2Prefix string) error {
	if manifest == nil {
		return fmt.Errorf("manifest is empty")
	}
	if manifest.SchemaVersion != 1 {
		return fmt.Errorf("unsupported manifest schema_version %d", manifest.SchemaVersion)
	}
	if manifest.ModelID != modelID || manifest.Version != version || manifest.R2Prefix != r2Prefix {
		return fmt.Errorf("manifest fields do not match registration request")
	}
	if !isLowerSHA256Hex(manifest.AggregateSHA256) {
		return fmt.Errorf("manifest aggregate_sha256 must be 64 lowercase hex characters")
	}
	if manifest.TotalSizeBytes < 0 {
		return fmt.Errorf("manifest total_size_bytes must be nonnegative")
	}
	if manifest.FileCount < 1 {
		return fmt.Errorf("manifest must contain at least one file")
	}
	if manifest.FileCount > maxModelManifestFileCount {
		return fmt.Errorf("manifest file_count exceeds limit of %d", maxModelManifestFileCount)
	}
	if len(manifest.Files) > maxModelManifestFileCount {
		return fmt.Errorf("manifest files length exceeds limit of %d", maxModelManifestFileCount)
	}
	if manifest.FileCount != len(manifest.Files) {
		return fmt.Errorf("manifest file_count does not match files length")
	}

	totalSize, err := checkedManifestTotalSize(manifest.Files)
	if err != nil {
		return err
	}
	if totalSize != manifest.TotalSizeBytes {
		return fmt.Errorf("manifest total_size_bytes does not match files sum")
	}
	if aggregate := aggregateManifestFileHashes(manifest.Files); aggregate != manifest.AggregateSHA256 {
		return fmt.Errorf("manifest aggregate_sha256 does not match file hashes")
	}
	return nil
}

func checkedManifestTotalSize(files []store.ManifestFile) (int64, error) {
	var totalSize int64
	seenPaths := make(map[string]bool, len(files))
	for _, file := range files {
		if err := validateManifestFile(file); err != nil {
			return 0, err
		}
		pathKey := strings.ToLower(file.Path)
		if seenPaths[pathKey] {
			return 0, fmt.Errorf("manifest file path %q is duplicated", file.Path)
		}
		seenPaths[pathKey] = true
		if file.SizeBytes > math.MaxInt64-totalSize {
			return 0, fmt.Errorf("manifest file sizes overflow int64")
		}
		totalSize += file.SizeBytes
	}
	return totalSize, nil
}

func aggregateManifestFileHashes(files []store.ManifestFile) string {
	sorted := append([]store.ManifestFile(nil), files...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Path < sorted[j].Path })
	h := sha256.New()
	for _, file := range sorted {
		digest, err := hex.DecodeString(file.SHA256)
		if err != nil || len(digest) != sha256.Size {
			return ""
		}
		_, _ = h.Write(digest)
	}
	return hex.EncodeToString(h.Sum(nil))
}

func validateManifestFile(file store.ManifestFile) error {
	if !validManifestRelativePath(file.Path) {
		return fmt.Errorf("manifest file path %q is invalid", file.Path)
	}
	if file.SizeBytes < 0 {
		return fmt.Errorf("manifest file %q size_bytes must be nonnegative", file.Path)
	}
	if !isLowerSHA256Hex(file.SHA256) {
		return fmt.Errorf("manifest file %q sha256 must be 64 lowercase hex characters", file.Path)
	}
	return nil
}

func validManifestRelativePath(path string) bool {
	if path == "" || strings.HasPrefix(path, "/") || strings.Contains(path, "\\") {
		return false
	}
	for _, part := range strings.Split(path, "/") {
		if part == "" || part == "." || part == ".." {
			return false
		}
	}
	return true
}

func isLowerSHA256Hex(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, r := range value {
		if !(r >= '0' && r <= '9') && !(r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}
