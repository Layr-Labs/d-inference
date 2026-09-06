package e2e

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
)

// Explicit input, never a latest-snapshot lookup or model-family substitution.
// Catalog includes the exact target and any externally configured assistant.
type connectedCacheInput struct {
	Providers       []testbed.ProviderTarget `json:"providers,omitempty"`
	CorrectnessOnly bool                     `json:"correctness_only,omitempty"`

	Catalog           []testbed.CatalogModel        `json:"catalog"`
	Artifact          registry.CacheRoutingArtifact `json:"artifact"`
	PromptArtifactDir string                        `json:"prompt_artifact_dir"`
	ProviderBinary    string                        `json:"provider_binary"`
	ProviderSHA256    string                        `json:"provider_sha256"`
	MetallibSHA256    string                        `json:"metallib_sha256"`
	SidecarBinary     string                        `json:"sidecar_binary"`
	SidecarSHA256     string                        `json:"sidecar_sha256"`
	Backend           string                        `json:"backend"`
	CacheMode         string                        `json:"cache_mode"`
	MTPMode           string                        `json:"mtp_mode"`
	AssistantPath     string                        `json:"assistant_path,omitempty"`
	VisionPNG         string                        `json:"vision_png,omitempty"`
	VisionSHA256      string                        `json:"vision_sha256,omitempty"`
	ToolsRequest      json.RawMessage               `json:"tools_request"`
	Prompt            string                        `json:"prompt"`
	MaxConcurrent     int                           `json:"max_concurrent"`
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func (in connectedCacheInput) validate() (exactCacheArtifactFixture, error) {
	fixture := exactCacheArtifactFixture{files: map[string][]byte{}}
	if err := validateConnectedTargetBindings(in); err != nil {
		return fixture, err
	}
	if in.Backend != "paged" && in.Backend != "contiguous" {
		return fixture, fmt.Errorf("backend must be explicit")
	}
	if in.CacheMode != "ssd" && in.CacheMode != "off" {
		return fixture, fmt.Errorf("cache_mode must be ssd or off")
	}
	if in.MaxConcurrent != 1 && in.MaxConcurrent != 2 && in.MaxConcurrent != 4 {
		return fixture, fmt.Errorf("max_concurrent must be 1, 2 or 4")
	}
	expectedMTP := map[string]string{"gpt-oss-20b": "off", "gemma-4-26b": "on", "qwen3.5-35b-a3b": "on", "qwen3.6-35b-a3b-vl-mtp-mxfp8": "on", "EigenLabs/Qwen3.8-27B-4bit-mtp": "on"}
	if expectedMTP[in.Artifact.ModelID] == "" || expectedMTP[in.Artifact.ModelID] != in.MTPMode {
		return fixture, fmt.Errorf("exact release model and normal MTP mode required")
	}
	if in.Artifact.ModelID == "gemma-4-26b" && in.AssistantPath == "" {
		return fixture, fmt.Errorf("normal Gemma requires explicit verified assistant input")
	}
	if len(in.Prompt) == 0 || len(in.ToolsRequest) == 0 {
		return fixture, fmt.Errorf("explicit text and tools fixtures required")
	}
	var target *testbed.CatalogModel
	for i := range in.Catalog {
		if in.Catalog[i].Entry.ID == in.Artifact.ModelID {
			if target != nil {
				return fixture, fmt.Errorf("duplicate target")
			}
			target = &in.Catalog[i]
		}
	}
	if target == nil || target.Manifest.ModelID != in.Artifact.ModelID || target.Manifest.AggregateSHA256 != in.Artifact.ModelAggregateSHA256 {
		return fixture, fmt.Errorf("exact target catalog/aggregate mismatch")
	}
	manifest := target.Manifest
	if manifest.FileCount != len(manifest.Files) || manifest.Version == "" {
		return fixture, fmt.Errorf("incomplete immutable manifest")
	}
	for _, f := range manifest.Files {
		if !filepath.IsLocal(f.Path) {
			return fixture, fmt.Errorf("nonlocal manifest path")
		}
		fixture.manifest.Files = append(fixture.manifest.Files, promptcontract.Artifact{Path: f.Path, Role: f.Role, SHA256: f.SHA256, SizeBytes: f.SizeBytes})
		if !promptcontract.IsPromptRole(f.Role) {
			continue
		}
		body, err := os.ReadFile(filepath.Join(in.PromptArtifactDir, f.Path))
		if err != nil {
			return fixture, err
		}
		hash := sha256.Sum256(body)
		if int64(len(body)) != f.SizeBytes || hex.EncodeToString(hash[:]) != f.SHA256 {
			return fixture, fmt.Errorf("prompt artifact mismatch: %s", f.Path)
		}
		fixture.files[f.Path] = body
	}
	var config struct {
		ModelType    string          `json:"model_type"`
		VisionConfig json.RawMessage `json:"vision_config"`
	}
	if err := json.Unmarshal(fixture.files["config.json"], &config); err != nil {
		return fixture, err
	}
	hasVision := len(config.VisionConfig) > 0 && string(config.VisionConfig) != "null"
	if hasVision && (in.VisionPNG == "" || in.VisionSHA256 != "f9f9fbf8c0a05fbac1081db94dff3688cdcb3ee3425e2c18e51cbe90f3c5cb33") {
		return fixture, fmt.Errorf("vision config requires the exact existing cube-hero PNG fixture")
	}
	if !hasVision && in.VisionPNG != "" {
		return fixture, fmt.Errorf("vision input supplied for a target without vision config")
	}
	fixture.manifest.ModelID, fixture.manifest.ModelType, fixture.manifest.AggregateSHA256 = manifest.ModelID, config.ModelType, manifest.AggregateSHA256
	artifacts, err := promptcontract.PromptArtifacts(fixture.manifest.Files)
	if err != nil {
		return fixture, err
	}
	contract, err := promptcontract.ContractID(artifacts, promptcontract.CurrentVersions())
	if err != nil {
		return fixture, err
	}
	if contract != in.Artifact.PromptContractID {
		return fixture, fmt.Errorf("supplied prompt contract differs from current exact artifacts")
	}
	if in.AssistantPath != "" {
		// The serving loader still verifies compatibility/manifest binding. This
		// preflight additionally pins every supplied assistant file, not just config.
		var assistant *testbed.CatalogModel
		for i := range in.Catalog {
			if in.Catalog[i].Entry.ID != in.Artifact.ModelID {
				if assistant != nil {
					return fixture, fmt.Errorf("ambiguous assistant catalog")
				}
				assistant = &in.Catalog[i]
			}
		}
		if assistant == nil {
			return fixture, fmt.Errorf("assistant manifest required")
		}
		for _, f := range assistant.Manifest.Files {
			if !filepath.IsLocal(f.Path) {
				return fixture, fmt.Errorf("nonlocal assistant path")
			}
			actual, err := fileSHA256(filepath.Join(in.AssistantPath, f.Path))
			if err != nil || actual != f.SHA256 {
				return fixture, fmt.Errorf("assistant file hash mismatch: %s", f.Path)
			}
		}
	}
	return fixture, nil
}

// Refuse before provider launch. The serving CLI would copy a custom config
// into the canonical path only if absent; we never create, repair or delete it.
func connectedHostPreflight(in connectedCacheInput) (string, string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", "", err
	}
	canonical := filepath.Join(home, ".config", "darkbloom", "provider.toml")
	original, err := fileSHA256(canonical)
	if err != nil {
		return "", "", fmt.Errorf("existing canonical config required to prevent CLI migration: %w", err)
	}
	for _, rel := range []string{".darkbloom/telemetry-queue.jsonl", ".darkbloom/telemetry-queue.jsonl.tmp"} {
		if _, err := os.Lstat(filepath.Join(home, rel)); !os.IsNotExist(err) {
			return "", "", fmt.Errorf("retired startup artifact exists; fixture will not purge %s", rel)
		}
	}
	for path, expected := range map[string]string{in.ProviderBinary: in.ProviderSHA256, filepath.Join(filepath.Dir(in.ProviderBinary), "mlx.metallib"): in.MetallibSHA256, in.SidecarBinary: in.SidecarSHA256} {
		actual, err := fileSHA256(path)
		if err != nil || len(expected) != 64 || actual != expected {
			return "", "", fmt.Errorf("binary/metallib identity mismatch: %s", path)
		}
	}
	// The data-protection keychain enforces explicit access-group membership.
	// Reject entitled binaries rather than exercising persistent signer repair.
	output, err := exec.Command("/usr/bin/codesign", "-d", "--entitlements", ":-", in.ProviderBinary).CombinedOutput()
	if err != nil || strings.Contains(string(output), "keychain-access-groups") {
		return "", "", fmt.Errorf("fixture requires verifiably unentitled ad-hoc provider")
	}
	if err := exec.Command("/usr/bin/pgrep", "-x", "darkbloom").Run(); err == nil {
		return "", "", fmt.Errorf("provider host already busy")
	}
	return canonical, original, nil
}

// SelfUpdater confirmation creates lock/state beside its executable even with
// auto-update disabled. Copy only the selected runtime and colocated Swift
// resources into this new fixture's root before launching the provider.
func stageConnectedRuntime(root, sourceBinary string) (string, error) {
	destination := filepath.Join(root, "runtime", "bin")
	if err := os.MkdirAll(destination, 0700); err != nil {
		return "", err
	}
	copyFile := func(source, target string) error {
		info, err := os.Stat(source)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return fmt.Errorf("runtime source is not a regular file")
		}
		from, err := os.Open(source)
		if err != nil {
			return err
		}
		defer from.Close()
		to, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, info.Mode().Perm())
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(to, from)
		closeErr := to.Close()
		if copyErr != nil {
			return copyErr
		}
		return closeErr
	}
	sourceDir := filepath.Dir(sourceBinary)
	for _, pair := range [][2]string{{sourceBinary, filepath.Join(destination, "darkbloom")}, {filepath.Join(sourceDir, "mlx.metallib"), filepath.Join(destination, "mlx.metallib")}} {
		if err := copyFile(pair[0], pair[1]); err != nil {
			return "", err
		}
	}
	entries, err := os.ReadDir(sourceDir)
	if err != nil {
		return "", err
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".bundle") && !strings.HasSuffix(name, ".dylib") {
			continue
		}
		err = filepath.WalkDir(filepath.Join(sourceDir, name), func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			relative, err := filepath.Rel(sourceDir, path)
			if err != nil {
				return err
			}
			target := filepath.Join(destination, relative)
			if d.IsDir() {
				return os.MkdirAll(target, 0700)
			}
			if d.Type()&os.ModeSymlink != 0 {
				return fmt.Errorf("runtime resource symlink must be materialized in final package")
			}
			return copyFile(path, target)
		})
		if err != nil {
			return "", err
		}
	}
	return filepath.Join(destination, "darkbloom"), nil
}
