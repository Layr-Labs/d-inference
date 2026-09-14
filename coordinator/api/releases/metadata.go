package releases

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/releasepolicy"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Controller) validateReleaseMetadata(release *store.Release) error {
	release.Version = strings.TrimSpace(release.Version)
	release.Platform = strings.TrimSpace(release.Platform)
	release.Backend = strings.TrimSpace(release.Backend)
	release.BinaryHash = strings.TrimSpace(release.BinaryHash)
	release.BundleHash = strings.TrimSpace(release.BundleHash)
	release.MetallibHash = strings.TrimSpace(release.MetallibHash)
	release.PythonHash = strings.TrimSpace(release.PythonHash)
	release.RuntimeHash = strings.TrimSpace(release.RuntimeHash)
	release.TemplateHashes = strings.TrimSpace(release.TemplateHashes)
	release.URL = strings.TrimSpace(release.URL)

	if release.Version == "" {
		return fmt.Errorf("version is required")
	}
	if !releaseVersionPattern.MatchString(release.Version) {
		return fmt.Errorf("version must be semver, e.g. 1.2.3 or 1.2.3-dev.1")
	}
	if release.Platform == "" {
		return fmt.Errorf("platform is required")
	}
	if !releasePlatformPattern.MatchString(release.Platform) {
		return fmt.Errorf("platform contains invalid characters")
	}

	var err error
	if release.BinaryHash, err = releasepolicy.NormalizeSHA256Hex(release.BinaryHash, "binary_hash"); err != nil {
		return err
	}
	if release.BundleHash, err = releasepolicy.NormalizeSHA256Hex(release.BundleHash, "bundle_hash"); err != nil {
		return err
	}
	if release.MetallibHash != "" {
		if release.MetallibHash, err = releasepolicy.NormalizeSHA256Hex(release.MetallibHash, "metallib_hash"); err != nil {
			return err
		}
	}
	if release.Backend == "mlx-swift" && release.MetallibHash == "" {
		return fmt.Errorf("metallib_hash is required for mlx-swift releases")
	}
	if release.PythonHash != "" {
		if release.PythonHash, err = releasepolicy.NormalizeSHA256Hex(release.PythonHash, "python_hash"); err != nil {
			return err
		}
	}
	if release.RuntimeHash != "" {
		if release.RuntimeHash, err = releasepolicy.NormalizeSHA256Hex(release.RuntimeHash, "runtime_hash"); err != nil {
			return err
		}
	}
	if release.TemplateHashes != "" {
		if release.TemplateHashes, err = normalizeTemplateHashes(release.TemplateHashes); err != nil {
			return err
		}
	}
	if release.URL == "" {
		return fmt.Errorf("url is required")
	}
	if s.cdnURL() != "" {
		if _, err := s.trustedReleaseArtifactURL(release); err != nil {
			return err
		}
	}
	return nil
}

func normalizeTemplateHashes(raw string) (string, error) {
	entries := strings.Split(raw, ",")
	normalized := make([]string, 0, len(entries))
	for _, entry := range entries {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		name, hash, ok := strings.Cut(entry, "=")
		if !ok {
			return "", fmt.Errorf("template_hashes entries must be name=sha256")
		}
		name = strings.TrimSpace(name)
		if name == "" || !releaseTemplateNamePattern.MatchString(name) {
			return "", fmt.Errorf("template_hashes contains an invalid template name")
		}
		hash, err := releasepolicy.NormalizeSHA256Hex(hash, "template_hashes")
		if err != nil {
			return "", err
		}
		normalized = append(normalized, name+"="+hash)
	}
	return strings.Join(normalized, ","), nil
}

var (
	releaseVersionPattern      = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$`)
	releasePlatformPattern     = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)
	releaseTemplateNamePattern = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
)
