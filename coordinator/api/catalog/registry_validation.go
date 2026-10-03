package catalog

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/url"
	"sort"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func parseModelCatalogPath(p string) (string, bool) {
	rest := strings.TrimPrefix(p, "/v1/models/catalog/")
	if rest == p || rest == "" {
		return "", false
	}
	modelID, err := url.PathUnescape(rest)
	if err != nil {
		return "", false
	}
	return modelID, true
}

func parseModelCatalogManifestPath(p string) (string, bool) {
	rest := strings.TrimPrefix(p, "/v1/models/catalog/manifest/")
	if rest == p || rest == "" {
		return "", false
	}
	modelID, err := url.PathUnescape(rest)
	if err != nil {
		return "", false
	}
	return modelID, true
}

func parseAdminModelActionPath(p string) (string, string, bool) {
	rest := strings.TrimPrefix(p, "/v1/admin/models/")
	if rest == p || rest == "" {
		return "", "", false
	}
	for _, action := range []string{"/publish-revision", "/retire-revision", "/promote", "/status", "/runtime-parameters", "/capabilities", "/deprecation", "/openrouter-slug", "/hugging-face-id"} {
		if strings.HasSuffix(rest, action) {
			modelID, err := url.PathUnescape(strings.TrimSuffix(rest, action))
			if err != nil {
				return "", "", false
			}
			return modelID, strings.TrimPrefix(action, "/"), true
		}
	}
	return "", "", false
}

func validateRegisterModelRequest(req registerModelRequest) error {
	if err := req.HuggingFaceArtifact.Validate(); err != nil {
		return err
	}
	if strings.TrimSpace(req.ModelID) == "" {
		return fmt.Errorf("model_id is required")
	}
	if strings.TrimSpace(req.Version) == "" {
		return fmt.Errorf("version is required")
	}
	if !validRegistryIdentifier(req.ModelID, true) {
		return fmt.Errorf("model_id contains invalid characters or path components")
	}
	if !validRegistryIdentifier(req.Version, false) {
		return fmt.Errorf("version contains invalid characters or path components")
	}
	if strings.TrimSpace(req.Quantization) == "" {
		return fmt.Errorf("quantization is required")
	}
	if req.MaxContextLength <= 0 {
		return fmt.Errorf("max_context_length must be greater than zero")
	}
	if req.MaxOutputLength <= 0 {
		return fmt.Errorf("max_output_length must be greater than zero")
	}
	if req.MinRAMGB <= 0 {
		return fmt.Errorf("min_ram_gb must be greater than zero")
	}
	if err := req.Input.Validate(); err != nil {
		return err
	}
	if err := validateRequiredProviderCapabilities(
		req.ModelID, req.RequiredProviderCapabilities); err != nil {
		return err
	}
	return nil
}
func validateRequiredProviderCapabilities(modelID string, capabilities []string) error {
	seen := make(map[string]struct{}, len(capabilities))
	for _, capability := range capabilities {
		if capability == "" || capability != strings.TrimSpace(capability) {
			return fmt.Errorf("required_provider_capabilities contains a malformed capability name")
		}
		switch capability {
		case registry.ProviderCapabilityAppleM5, registry.ProviderCapabilityMLXNAX:
		default:
			return fmt.Errorf("required_provider_capabilities contains unknown capability %q", capability)
		}
		if _, duplicate := seen[capability]; duplicate {
			return fmt.Errorf("required_provider_capabilities contains duplicate capability %q", capability)
		}
		seen[capability] = struct{}{}
	}
	if modelID == registry.Qwen38NAXModelID {
		for _, required := range []string{
			registry.ProviderCapabilityAppleM5,
			registry.ProviderCapabilityMLXNAX,
		} {
			if _, ok := seen[required]; !ok {
				return fmt.Errorf(
					"model %q requires provider capability %q", modelID, required)
			}
		}
	}
	return nil
}

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
	if manifest.FileCount != len(manifest.Files) {
		return fmt.Errorf("manifest file_count does not match files length")
	}
	if len(manifest.Files) == 0 {
		return fmt.Errorf("manifest must contain at least one file")
	}
	var totalSize int64
	seenPaths := make(map[string]bool, len(manifest.Files))
	for _, file := range manifest.Files {
		if err := validateManifestFile(file); err != nil {
			return err
		}
		pathKey := strings.ToLower(file.Path)
		if seenPaths[pathKey] {
			return fmt.Errorf("manifest file path %q is duplicated", file.Path)
		}
		seenPaths[pathKey] = true
		totalSize += file.SizeBytes
	}
	if totalSize != manifest.TotalSizeBytes {
		return fmt.Errorf("manifest total_size_bytes does not match files sum")
	}
	if aggregate := aggregateManifestFileHashes(manifest.Files); aggregate != manifest.AggregateSHA256 {
		return fmt.Errorf("manifest aggregate_sha256 does not match file hashes")
	}
	return nil
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
		h.Write(digest)
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

func containsTraversal(value string) bool {
	return strings.Contains(value, "..")
}

func validRegistryIdentifier(value string, allowSlash bool) bool {
	if value == "" || strings.HasPrefix(value, "/") || containsTraversal(value) {
		return false
	}
	for _, r := range value {
		if r >= '0' && r <= '9' || r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r == '.' || r == '_' || r == '-' {
			continue
		}
		if allowSlash && r == '/' {
			continue
		}
		return false
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
