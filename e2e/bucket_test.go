package e2e

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func startSuiteWithBucket(t *testing.T) *testbed.Suite {
	t.Helper()
	ctx := context.Background()
	s := testbed.NewSuite(testbed.SuiteConfig{
		LocalStack:    true,
		ModelSpecs:    []testbed.ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 0}},
		NumUsers:      1,
		QueueCapacity: 100,
		QueueTimeout:  120 * time.Second,
		SeedBalance:   100_000_000,
	})
	require.NoError(t, s.Start(ctx), "suite startup failed")
	t.Cleanup(s.Stop)
	return s
}

func startInfrastructure(t *testing.T) *testbed.Suite {
	t.Helper()
	ctx := context.Background()
	s := testbed.NewSuite(testbed.SuiteConfig{
		LocalStack:    true,
		ModelSpecs:    []testbed.ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 0}},
		NumUsers:      1,
		QueueCapacity: 100,
		QueueTimeout:  120 * time.Second,
		SeedBalance:   100_000_000,
	})
	require.NoError(t, s.StartWithConfig(ctx, testbed.StartConfig{}), "infrastructure startup failed")
	t.Cleanup(s.Stop)
	return s
}

func TestIntegration_ReleaseRegistration(t *testing.T) {
	s := startSuiteWithBucket(t)

	bundle := createReleaseBundle(t, s)

	body, _ := json.Marshal(store.Release{
		Version:      "0.99.0",
		Platform:     "macos-arm64",
		Backend:      "mlx-swift",
		BinaryHash:   bundle.binaryHash,
		BundleHash:   bundle.bundleHash,
		MetallibHash: bundle.metallibHash,
		URL:          bundle.bundleURL,
		Changelog:    "test release",
	})

	req, err := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		s.Coordinator.BaseURL()+"/v1/releases", strings.NewReader(string(body)))
	require.NoError(t, err)
	req.Header.Set("Authorization", "Bearer testbed-release-key")
	req.Header.Set("Content-Type", "application/json")

	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode, "release registration should succeed")

	var regResp struct {
		Release store.Release `json:"release"`
	}
	require.NoError(t, json.NewDecoder(resp.Body).Decode(&regResp))
	require.Equal(t, "0.99.0", regResp.Release.Version)
	require.Equal(t, bundle.bundleHash, regResp.Release.BundleHash)
	require.Equal(t, bundle.binaryHash, regResp.Release.BinaryHash)
	require.Equal(t, bundle.metallibHash, regResp.Release.MetallibHash)

	lreq, _ := http.NewRequestWithContext(s.Ctx, http.MethodGet,
		s.Coordinator.BaseURL()+"/v1/releases/latest?platform=macos-arm64", nil)
	lresp, err := (&http.Client{Timeout: 30 * time.Second}).Do(lreq)
	require.NoError(t, err)
	defer lresp.Body.Close()
	require.Equal(t, http.StatusOK, lresp.StatusCode)

	var latest store.Release
	require.NoError(t, json.NewDecoder(lresp.Body).Decode(&latest))
	require.Equal(t, "0.99.0", latest.Version)
	require.Equal(t, bundle.bundleURL, latest.URL)

	dlResp, err := http.Get(bundle.bundleURL)
	require.NoError(t, err)
	defer dlResp.Body.Close()
	require.Equal(t, http.StatusOK, dlResp.StatusCode, "bundle should be downloadable from LocalStack")

	dlData, err := io.ReadAll(dlResp.Body)
	require.NoError(t, err)
	gotHash := sha256.Sum256(dlData)
	require.Equal(t, bundle.bundleHash, hex.EncodeToString(gotHash[:]),
		"downloaded bundle hash must match registered bundle_hash")

	gf, err := gzip.NewReader(strings.NewReader(string(dlData)))
	require.NoError(t, err)
	defer gf.Close()
	tr := tar.NewReader(gf)
	foundFiles := map[string]bool{}
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		require.NoError(t, err)
		foundFiles[hdr.Name] = true
	}
	require.True(t, foundFiles["bin/darkbloom"], "tarball must contain bin/darkbloom")
	require.True(t, foundFiles["bin/darkbloom-enclave"], "tarball must contain bin/darkbloom-enclave")
	require.True(t, foundFiles["bin/mlx.metallib"], "tarball must contain bin/mlx.metallib")
	t.Logf("release v0.99.0: bundle=%s binary=%s metallib=%s files=%v",
		bundle.bundleHash[:16], bundle.binaryHash[:16], bundle.metallibHash[:16], foundFiles)
}

func TestIntegration_SelfUpdateCheck(t *testing.T) {
	s := startSuiteWithBucket(t)

	bundle := createReleaseBundle(t, s)

	regBody, _ := json.Marshal(store.Release{
		Version:      "99.0.0",
		Platform:     "macos-arm64",
		Backend:      "mlx-swift",
		BinaryHash:   bundle.binaryHash,
		BundleHash:   bundle.bundleHash,
		MetallibHash: bundle.metallibHash,
		URL:          bundle.bundleURL,
		Changelog:    "e2e self-update test",
	})
	req, _ := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		s.Coordinator.BaseURL()+"/v1/releases", strings.NewReader(string(regBody)))
	req.Header.Set("Authorization", "Bearer testbed-release-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	require.NoError(t, err)
	resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode)

	binPath, err := testbed.BuildProvider(s.Ctx, s.Logger)
	require.NoError(t, err, "build provider for self-update check")

	cfgDir := t.TempDir()
	cfgPath := filepath.Join(cfgDir, "provider.toml")
	cfgContent := fmt.Sprintf("[coordinator]\nurl = %q\n", s.Coordinator.BaseURL())
	require.NoError(t, os.WriteFile(cfgPath, []byte(cfgContent), 0644))

	ctx, cancel := context.WithTimeout(s.Ctx, 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, binPath, "update", "--check-only",
		"--config", cfgPath)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "darkbloom update --check-only should succeed: %s", string(out))

	outStr := string(out)
	require.Contains(t, outStr, "Update available", "should detect v99.0.0 as newer")
	require.Contains(t, outStr, "99.0.0", "output should mention new version")
	t.Logf("self-update check output:\n%s", outStr)
}

func TestIntegration_ModelWeightDownload(t *testing.T) {
	s := startSuiteWithBucket(t)

	s3Name := "Qwen3.5-0.8B-MLX-4bit"
	modelID := "mlx-community/Qwen3.5-0.8B-MLX-4bit"

	configJSON := []byte(`{"model_type":"qwen3","hidden_size":1024,"num_hidden_layers":24,"vocab_size":151936}`)
	tokenizerJSON := []byte(`{"version":1,"truncation":null}`)
	tokenizerCfgJSON := []byte(`{"tokenizer_class":"PreTrainedTokenizerFast","model_max_length":32768}`)

	ctx := s.Ctx
	require.NoError(t, s.Bucket.PutObject(ctx, s3Name+"/config.json", configJSON))
	require.NoError(t, s.Bucket.PutObject(ctx, s3Name+"/tokenizer.json", tokenizerJSON))
	require.NoError(t, s.Bucket.PutObject(ctx, s3Name+"/tokenizer_config.json", tokenizerCfgJSON))

	modelContent := []byte("fake-safetensors-payload-for-testing")
	require.NoError(t, s.Bucket.PutObject(ctx, s3Name+"/model.safetensors", modelContent))

	require.NoError(t, s.PgStore.SetSupportedModel(&store.SupportedModel{
		ID:          modelID,
		S3Name:      s3Name,
		DisplayName: "Qwen3.5 0.8B (test)",
		ModelType:   "text",
		SizeGB:      0.5,
		Active:      true,
	}))

	cdnURL := s.Bucket.CDNURL()
	for _, file := range []string{"config.json", "tokenizer.json", "model.safetensors"} {
		url := fmt.Sprintf("%s/%s/%s", cdnURL, s3Name, file)
		vreq, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		vresp, err := (&http.Client{Timeout: 30 * time.Second}).Do(vreq)
		require.NoError(t, err)
		data, _ := io.ReadAll(vresp.Body)
		vresp.Body.Close()
		require.Equal(t, http.StatusOK, vresp.StatusCode, "%s should be servable from LocalStack", file)
		if file == "config.json" {
			require.Equal(t, configJSON, data, "config.json content must match")
		}
		if file == "model.safetensors" {
			require.Equal(t, modelContent, data, "model.safetensors content must match")
		}
	}

	binPath, err := testbed.BuildProvider(s.Ctx, s.Logger)
	require.NoError(t, err, "build provider for model download")

	cacheDir := filepath.Join(os.Getenv("HOME"), ".cache", "huggingface", "hub",
		"models--mlx-community--Qwen3.5-0.8B-MLX-4bit")
	_ = os.RemoveAll(cacheDir)

	cmdCtx, cmdCancel := context.WithTimeout(ctx, 120*time.Second)
	defer cmdCancel()

	cmd := exec.CommandContext(cmdCtx, binPath, "models", "download", modelID,
		"--coordinator", s.Coordinator.BaseURL(),
		"--r2-cdn", cdnURL)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "darkbloom models download should succeed: %s", string(out))

	snapDir := filepath.Join(cacheDir, "snapshots", "local")
	for _, file := range []string{"config.json", "tokenizer.json", "model.safetensors"} {
		p := filepath.Join(snapDir, file)
		data, err := os.ReadFile(p)
		require.NoError(t, err, "%s should exist in cache after download", file)
		if file == "config.json" {
			require.Equal(t, configJSON, data, "cached config.json must match")
		}
		if file == "model.safetensors" {
			require.Equal(t, modelContent, data, "cached model.safetensors must match")
		}
	}

	mainRef := filepath.Join(cacheDir, "refs", "main")
	refData, err := os.ReadFile(mainRef)
	require.NoError(t, err, "refs/main pointer must exist")
	require.Equal(t, "local", strings.TrimSpace(string(refData)), "refs/main must point to 'local'")

	t.Logf("model download: %d files cached in %s", 3, snapDir)
}

func TestIntegration_FleetUpgradeToSwift(t *testing.T) {
	s := startInfrastructure(t)

	swiftBinPath, err := testbed.BuildProvider(s.Ctx, s.Logger)
	require.NoError(t, err, "build Swift provider")

	rustBinPath, err := buildRustProvider(s.Ctx, s.Logger)
	require.NoError(t, err, "build Rust provider (bridge)")

	oldCoordBin, err := testbed.BuildOldCoordinator(s.Ctx, s.Logger)
	require.NoError(t, err, "build old coordinator")

	pgURL := s.Pg.DatabaseURL
	cdnURL := s.Bucket.CDNURL()

	bundle := createSwiftReleaseBundle(t, s, swiftBinPath)

	installDir := filepath.Join(os.Getenv("HOME"), ".darkbloom")
	binDir := filepath.Join(installDir, "bin")

	// ========================================================================
	// Phase 0: Old coordinator + bridge update to Swift
	//
	// Simulates the state after v0.4.7→bridge auto-update. The bridge binary
	// (current Rust with Swift detection) is already installed. The old
	// coordinator (v0.4.7) is running — its /api/version lacks
	// binary_hash/metallib_hash, but the bridge only checks bundle_hash, so
	// it can successfully install the Swift bundle.
	// ========================================================================
	oldCoord, err := testbed.StartOldCoordinator(s.Ctx, s.Logger, oldCoordBin, pgURL, cdnURL)
	require.NoError(t, err, "start old coordinator")

	regBody, _ := json.Marshal(store.Release{
		Version:    "0.5.0",
		Platform:   "macos-arm64",
		BinaryHash: bundle.binaryHash,
		BundleHash: bundle.bundleHash,
		URL:        bundle.bundleURL,
		Changelog:  "Swift provider migration",
	})
	req, _ := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		oldCoord.BaseURL+"/v1/releases", strings.NewReader(string(regBody)))
	req.Header.Set("Authorization", "Bearer testbed-release-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	require.NoError(t, err)
	resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode, "release registration on old coordinator should succeed")

	versionReq, _ := http.NewRequestWithContext(s.Ctx, http.MethodGet,
		oldCoord.BaseURL+"/api/version", nil)
	versionResp, err := (&http.Client{Timeout: 10 * time.Second}).Do(versionReq)
	require.NoError(t, err)
	var versionOld map[string]any
	require.NoError(t, json.NewDecoder(versionResp.Body).Decode(&versionOld))
	versionResp.Body.Close()
	require.Equal(t, "0.5.0", versionOld["version"])
	_, hasBinaryHash := versionOld["binary_hash"]
	_, hasMetallibHash := versionOld["metallib_hash"]
	require.False(t, hasBinaryHash, "old coordinator should NOT expose binary_hash")
	require.False(t, hasMetallibHash, "old coordinator should NOT expose metallib_hash")
	t.Logf("phase 0 (old coordinator v0.4.7): /api/version has version+download_url+bundle_hash but no binary_hash/metallib_hash")

	_ = os.RemoveAll(installDir)
	require.NoError(t, os.MkdirAll(binDir, 0755))
	rustInBin := filepath.Join(binDir, "darkbloom")
	cpCmd := exec.CommandContext(s.Ctx, "cp", rustBinPath, rustInBin)
	require.NoError(t, cpCmd.Run())
	require.NoError(t, os.Chmod(rustInBin, 0755))
	enclaveInBin := filepath.Join(binDir, "eigeninference-enclave")
	require.NoError(t, os.WriteFile(enclaveInBin, []byte("#!/bin/sh\nexit 0\n"), 0755))

	updateCtx, updateCancel := context.WithTimeout(s.Ctx, 120*time.Second)
	defer updateCancel()
	cmd := exec.CommandContext(updateCtx, rustBinPath, "update", "--coordinator", oldCoord.BaseURL, "--force")
	cmd.Env = append(os.Environ(), "HOME="+os.Getenv("HOME"))
	out, err := cmd.CombinedOutput()
	outStr := string(out)
	t.Logf("phase 0 bridge update output:\n%s", outStr)
	require.NoError(t, err, "bridge should successfully update to Swift on old coordinator (only needs bundle_hash)")
	require.Contains(t, outStr, "Updated to 0.5.0", "bridge update should report success")
	require.Contains(t, outStr, "Swift", "bridge should detect Swift runtime bundle")

	installedDarkbloom := filepath.Join(binDir, "darkbloom")
	data, err := os.ReadFile(installedDarkbloom)
	require.NoError(t, err, "~/.darkbloom/bin/darkbloom should exist after update")
	require.Equal(t, bundle.binaryHash, sha256Hex(data), "installed darkbloom hash must match release binary_hash")

	metallibData, err := os.ReadFile(filepath.Join(binDir, "mlx.metallib"))
	require.NoError(t, err, "~/.darkbloom/bin/mlx.metallib should exist after update")
	require.Equal(t, bundle.metallibHash, sha256Hex(metallibData), "installed mlx.metallib hash must match release metallib_hash")

	// Verify the Swift binary's --check-only against old coordinator reports "Up to date"
	// but without per-file hash verification (no binary_hash/metallib_hash available).
	swiftCheckCtx, swiftCheckCancel := context.WithTimeout(s.Ctx, 60*time.Second)
	defer swiftCheckCancel()
	cfgDir := t.TempDir()
	cfgPath := filepath.Join(cfgDir, "provider.toml")
	cfgContent := fmt.Sprintf("[coordinator]\nurl = %q\n", oldCoord.BaseURL)
	require.NoError(t, os.WriteFile(cfgPath, []byte(cfgContent), 0644))
	checkCmd := exec.CommandContext(swiftCheckCtx, installedDarkbloom, "update", "--check-only", "--config", cfgPath)
	swiftOut, err := checkCmd.CombinedOutput()
	require.NoError(t, err, "swift --check-only should succeed against old coordinator: %s", string(swiftOut))
	require.Contains(t, string(swiftOut), "Up to date", "swift provider should report up to date")
	t.Logf("phase 0: Swift provider reports 'Up to date' on old coordinator (but without per-file hash verification)")

	oldCoord.Stop()

	// ========================================================================
	// Phase 1: Deploy NEW coordinator (in-process — /api/version includes binary_hash/metallib_hash)
	//
	// The Swift provider now gets per-file hash verification when checking
	// for updates. This is the security upgrade that justifies the migration
	// order: deploy new coordinator first, then Swift providers can verify
	// individual binary/metallib hashes on every update check.
	// ========================================================================
	require.NoError(t, s.StartCoordinator(), "start new coordinator")
	t.Logf("phase 1: new coordinator started — /api/version includes binary_hash/metallib_hash")

	coordinatorHTTP := s.Coordinator.BaseURL()

	regBody2, _ := json.Marshal(store.Release{
		Version:      "0.5.0",
		Platform:     "macos-arm64",
		Backend:      "mlx-swift",
		BinaryHash:   bundle.binaryHash,
		BundleHash:   bundle.bundleHash,
		MetallibHash: bundle.metallibHash,
		URL:          bundle.bundleURL,
		Changelog:    "Swift provider migration",
	})
	req2, _ := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		coordinatorHTTP+"/v1/releases", strings.NewReader(string(regBody2)))
	req2.Header.Set("Authorization", "Bearer testbed-release-key")
	req2.Header.Set("Content-Type", "application/json")
	resp2, err := (&http.Client{Timeout: 30 * time.Second}).Do(req2)
	require.NoError(t, err)
	resp2.Body.Close()
	require.Equal(t, http.StatusOK, resp2.StatusCode, "release registration on new coordinator should succeed")

	versionReq2, _ := http.NewRequestWithContext(s.Ctx, http.MethodGet,
		coordinatorHTTP+"/api/version", nil)
	versionResp2, err := (&http.Client{Timeout: 10 * time.Second}).Do(versionReq2)
	require.NoError(t, err)
	var versionNew map[string]any
	require.NoError(t, json.NewDecoder(versionResp2.Body).Decode(&versionNew))
	versionResp2.Body.Close()
	require.Equal(t, "0.5.0", versionNew["version"])
	require.Equal(t, bundle.binaryHash, versionNew["binary_hash"], "new coordinator should expose binary_hash")
	require.Equal(t, bundle.metallibHash, versionNew["metallib_hash"], "new coordinator should expose metallib_hash")
	t.Logf("phase 1: /api/version returns binary_hash=%s metallib_hash=%s",
		bundle.binaryHash[:16], bundle.metallibHash[:16])

	cfgContent2 := fmt.Sprintf("[coordinator]\nurl = %q\n", coordinatorHTTP)
	cfgPath2 := filepath.Join(t.TempDir(), "provider.toml")
	require.NoError(t, os.WriteFile(cfgPath2, []byte(cfgContent2), 0644))

	swiftCheckCtx2, swiftCheckCancel2 := context.WithTimeout(s.Ctx, 60*time.Second)
	defer swiftCheckCancel2()
	checkCmd2 := exec.CommandContext(swiftCheckCtx2, installedDarkbloom, "update", "--check-only", "--config", cfgPath2)
	swiftOut2, err := checkCmd2.CombinedOutput()
	require.NoError(t, err, "swift --check-only should succeed against new coordinator: %s", string(swiftOut2))
	require.Contains(t, string(swiftOut2), "Up to date", "swift provider should report up to date on new coordinator")
	t.Logf("phase 1: Swift provider reports 'Up to date' on new coordinator (with per-file hash verification via binary_hash/metallib_hash)")

	t.Logf("fleet upgrade complete: old coordinator v0.4.7 → bridge → Swift → new coordinator, binary=%s metallib=%s enclave=%s",
		bundle.binaryHash[:16], bundle.metallibHash[:16], bundle.enclaveHash[:16])
}

type releaseBundleArtifacts struct {
	binaryHash   string
	bundleHash   string
	metallibHash string
	bundleURL    string
}

func createReleaseBundle(t *testing.T, s *testbed.Suite) releaseBundleArtifacts {
	t.Helper()
	ctx := s.Ctx

	tmpDir := t.TempDir()
	binDir := filepath.Join(tmpDir, "bin")
	require.NoError(t, os.MkdirAll(binDir, 0755))

	darkbloomSrc, err := os.Executable()
	require.NoError(t, err)
	darkbloomDst := filepath.Join(binDir, "darkbloom")
	cpCmd := exec.CommandContext(ctx, "cp", darkbloomSrc, darkbloomDst)
	require.NoError(t, cpCmd.Run())

	metallibContent := []byte("// fake mlx.metallib for testing")
	metallibDst := filepath.Join(binDir, "mlx.metallib")
	require.NoError(t, os.WriteFile(metallibDst, metallibContent, 0644))

	enclaveDst := filepath.Join(binDir, "darkbloom-enclave")
	require.NoError(t, os.WriteFile(enclaveDst, []byte("#!/bin/sh\nexit 0\n"), 0755))

	tarPath := filepath.Join(tmpDir, "darkbloom-0.99.0-macos-arm64.tar.gz")
	tarCmd := exec.CommandContext(ctx, "tar", "czf", tarPath, "-C", tmpDir, "bin")
	tarCmd.Env = append(os.Environ(), "COPYFILE_DISABLE=1")
	require.NoError(t, tarCmd.Run())

	tarData, err := os.ReadFile(tarPath)
	require.NoError(t, err)
	bundleHash := sha256.Sum256(tarData)

	binaryData, err := os.ReadFile(darkbloomDst)
	require.NoError(t, err)
	binaryHash := sha256.Sum256(binaryData)

	metallibHash := sha256.Sum256(metallibContent)

	s3Key := "releases/darkbloom-0.99.0-macos-arm64.tar.gz"
	require.NoError(t, s.Bucket.PutObject(ctx, s3Key, tarData))

	return releaseBundleArtifacts{
		binaryHash:   hex.EncodeToString(binaryHash[:]),
		bundleHash:   hex.EncodeToString(bundleHash[:]),
		metallibHash: hex.EncodeToString(metallibHash[:]),
		bundleURL:    fmt.Sprintf("%s/%s", s.Bucket.CDNURL(), s3Key),
	}
}

type swiftReleaseArtifacts struct {
	binaryHash   string
	bundleHash   string
	metallibHash string
	enclaveHash  string
	bundleURL    string
}

func createSwiftReleaseBundle(t *testing.T, s *testbed.Suite, swiftBinPath string) swiftReleaseArtifacts {
	t.Helper()
	ctx := s.Ctx

	tmpDir := t.TempDir()
	binDir := filepath.Join(tmpDir, "bin")
	require.NoError(t, os.MkdirAll(binDir, 0755))

	darkbloomDst := filepath.Join(binDir, "darkbloom")
	cpCmd := exec.CommandContext(ctx, "cp", swiftBinPath, darkbloomDst)
	require.NoError(t, cpCmd.Run())

	enclaveContent := []byte("#!/bin/sh\nexit 0\n")
	enclaveDst := filepath.Join(binDir, "darkbloom-enclave")
	require.NoError(t, os.WriteFile(enclaveDst, enclaveContent, 0755))

	metallibSrc := filepath.Join(filepath.Dir(swiftBinPath), "mlx.metallib")
	metallibDst := filepath.Join(binDir, "mlx.metallib")
	cpMeta := exec.CommandContext(ctx, "cp", metallibSrc, metallibDst)
	require.NoError(t, cpMeta.Run(), "copy mlx.metallib from %s", metallibSrc)

	tarPath := filepath.Join(tmpDir, "darkbloom-0.5.0-macos-arm64.tar.gz")
	tarCmd := exec.CommandContext(ctx, "tar", "czf", tarPath, "-C", tmpDir, "bin")
	tarCmd.Env = append(os.Environ(), "COPYFILE_DISABLE=1")
	require.NoError(t, tarCmd.Run())

	tarData, err := os.ReadFile(tarPath)
	require.NoError(t, err)
	bundleHash := sha256.Sum256(tarData)

	binaryData, err := os.ReadFile(darkbloomDst)
	require.NoError(t, err)
	binaryHash := sha256.Sum256(binaryData)

	metallibData, err := os.ReadFile(metallibDst)
	require.NoError(t, err)
	metallibHash := sha256.Sum256(metallibData)

	enclaveHash := sha256.Sum256(enclaveContent)

	s3Key := "releases/darkbloom-0.5.0-macos-arm64.tar.gz"
	require.NoError(t, s.Bucket.PutObject(ctx, s3Key, tarData))

	return swiftReleaseArtifacts{
		binaryHash:   hex.EncodeToString(binaryHash[:]),
		bundleHash:   hex.EncodeToString(bundleHash[:]),
		metallibHash: hex.EncodeToString(metallibHash[:]),
		enclaveHash:  hex.EncodeToString(enclaveHash[:]),
		bundleURL:    fmt.Sprintf("%s/%s", s.Bucket.CDNURL(), s3Key),
	}
}

func buildRustProvider(ctx context.Context, logger *slog.Logger) (string, error) {
	repoRoot := os.Getenv("DARKBLOOM_REPO_ROOT")
	if repoRoot == "" {
		repoRoot = "."
	}
	providerDir := repoRoot + "/provider"

	binaryPath := providerDir + "/target/release/darkbloom"
	if _, err := os.Stat(binaryPath); err == nil {
		logger.Info("using cached Rust provider binary", "path", binaryPath)
		return binaryPath, nil
	}

	logger.Info("building Rust provider binary", "dir", providerDir)

	cmd := exec.CommandContext(ctx, "cargo", "build", "--release")
	cmd.Dir = providerDir
	cmd.Env = append(os.Environ(), "PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1")

	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("cargo build provider: %w: %s", err, string(out))
	}

	if _, err := os.Stat(binaryPath); err != nil {
		return "", fmt.Errorf("Rust provider binary not found after build: %s", binaryPath)
	}

	logger.Info("Rust provider binary built", "path", binaryPath)
	return binaryPath, nil
}

func sha256Hex(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}
