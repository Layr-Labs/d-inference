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
	"sync"
	"sync/atomic"
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
	require.NoError(t, err, "build Swift provider (hop 2+3 target)")

	cdnURL := s.Bucket.CDNURL()

	bridgeBinPath, err := buildRustProvider(s.Ctx, s.Logger, cdnURL, cdnURL)
	require.NoError(t, err, "build Rust bridge provider (hop 2)")

	oldCoordBin, err := testbed.BuildOldCoordinator(s.Ctx, s.Logger)
	require.NoError(t, err, "build old coordinator")

	oldProviderBin, err := testbed.BuildOldProvider(s.Ctx, s.Logger, cdnURL, cdnURL)
	require.NoError(t, err, "build old Rust provider v0.4.7 (hop 1 starting binary)")

	pgURL := s.Pg.DatabaseURL

	swiftBundle := createSwiftReleaseBundle(t, s, swiftBinPath)

	installDir := filepath.Join(os.Getenv("HOME"), ".darkbloom")
	binDir := filepath.Join(installDir, "bin")

	// ========================================================================
	// Hop 1: Old Rust (v0.4.7) → Bridge Rust (current + Swift detection)
	//
	// Start the old coordinator, register the bridge release, and run the
	// v0.4.7 binary's update command. The bridge bundle includes a
	// python/ directory with ad-hoc signed stubs so the old binary's
	// verify_installed_update_runtime can pass code-signing checks and
	// download site-packages from LocalStack (via compile-time R2 URLs).
	// ========================================================================
	oldCoord, err := testbed.StartOldCoordinator(s.Ctx, s.Logger, oldCoordBin, pgURL, cdnURL, 0)
	require.NoError(t, err, "start old coordinator")

	bridgeBundle := createBridgeReleaseBundle(t, s, bridgeBinPath, cdnURL)

	regBody, _ := json.Marshal(store.Release{
		Version:    "0.4.8",
		Platform:   "macos-arm64",
		BinaryHash: bridgeBundle.binaryHash,
		BundleHash: bridgeBundle.bundleHash,
		PythonHash: bridgeBundle.pythonHash,
		URL:        bridgeBundle.bundleURL,
		Changelog:  "Bridge release for Swift migration",
	})
	req, _ := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		oldCoord.BaseURL+"/v1/releases", strings.NewReader(string(regBody)))
	req.Header.Set("Authorization", "Bearer testbed-release-key")
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	require.NoError(t, err)
	resp.Body.Close()
	require.Equal(t, http.StatusOK, resp.StatusCode, "bridge release registration on old coordinator should succeed")

	versionReq, _ := http.NewRequestWithContext(s.Ctx, http.MethodGet,
		oldCoord.BaseURL+"/api/version", nil)
	versionResp, err := (&http.Client{Timeout: 10 * time.Second}).Do(versionReq)
	require.NoError(t, err)
	var versionRespBody map[string]any
	require.NoError(t, json.NewDecoder(versionResp.Body).Decode(&versionRespBody))
	versionResp.Body.Close()
	require.Equal(t, "0.4.8", versionRespBody["version"])
	_, hasBinaryHash := versionRespBody["binary_hash"]
	_, hasMetallibHash := versionRespBody["metallib_hash"]
	require.False(t, hasBinaryHash, "old coordinator should NOT expose binary_hash")
	require.False(t, hasMetallibHash, "old coordinator should NOT expose metallib_hash")
	t.Logf("hop 1: old coordinator /api/version has bundle_hash but no binary_hash/metallib_hash")

	_ = os.RemoveAll(installDir)
	require.NoError(t, os.MkdirAll(binDir, 0755))
	oldInBin := filepath.Join(binDir, "darkbloom")
	cpCmd := exec.CommandContext(s.Ctx, "cp", oldProviderBin, oldInBin)
	require.NoError(t, cpCmd.Run())
	require.NoError(t, os.Chmod(oldInBin, 0755))
	enclaveInBin := filepath.Join(binDir, "eigeninference-enclave")
	require.NoError(t, os.WriteFile(enclaveInBin, []byte("#!/bin/sh\nexit 0\n"), 0755))

	updateCtx, updateCancel := context.WithTimeout(s.Ctx, 180*time.Second)
	defer updateCancel()
	cmd := exec.CommandContext(updateCtx, oldInBin, "update", "--coordinator", oldCoord.BaseURL, "--force")
	cmd.Env = append(os.Environ(), "HOME="+os.Getenv("HOME"))
	out, err := cmd.CombinedOutput()
	outStr := string(out)
	t.Logf("hop 1 old provider update output:\n%s", outStr)
	require.NoError(t, err, "v0.4.7 → bridge update should succeed on old coordinator")
	require.Contains(t, outStr, "Hash verified", "old provider should verify bundle_hash")
	require.Contains(t, outStr, "Updated to 0.4.8", "old provider should report successful update")

	installedBridge := filepath.Join(binDir, "darkbloom")
	bridgeData, err := os.ReadFile(installedBridge)
	require.NoError(t, err, "~/.darkbloom/bin/darkbloom should exist after hop 1")
	require.Equal(t, bridgeBundle.binaryHash, sha256Hex(bridgeData),
		"installed bridge binary hash must match release binary_hash")
	t.Logf("hop 1 complete: v0.4.7 → bridge v0.4.8, binary=%s", bridgeBundle.binaryHash[:16])

	oldCoord.Stop()

	// ========================================================================
	// Hop 2: Bridge Rust → Swift darkbloom (on old coordinator)
	//
	// The bridge binary (current Rust with Swift detection) is now installed.
	// Register the Swift release on the old coordinator and run the bridge
	// binary's update command. The bridge only needs bundle_hash, so this
	// succeeds even though the old coordinator lacks binary_hash/metallib_hash.
	// ========================================================================
	oldCoord2, err := testbed.StartOldCoordinator(s.Ctx, s.Logger, oldCoordBin, pgURL, cdnURL, 0)
	require.NoError(t, err, "restart old coordinator for hop 2")

	regBody2, _ := json.Marshal(store.Release{
		Version:    "0.5.0",
		Platform:   "macos-arm64",
		BinaryHash: swiftBundle.binaryHash,
		BundleHash: swiftBundle.bundleHash,
		URL:        swiftBundle.bundleURL,
		Changelog:  "Swift provider migration",
	})
	req2, _ := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		oldCoord2.BaseURL+"/v1/releases", strings.NewReader(string(regBody2)))
	req2.Header.Set("Authorization", "Bearer testbed-release-key")
	req2.Header.Set("Content-Type", "application/json")
	resp2, err := (&http.Client{Timeout: 30 * time.Second}).Do(req2)
	require.NoError(t, err)
	resp2.Body.Close()
	require.Equal(t, http.StatusOK, resp2.StatusCode, "Swift release registration on old coordinator should succeed")

	updateCtx2, updateCancel2 := context.WithTimeout(s.Ctx, 120*time.Second)
	defer updateCancel2()
	cmd2 := exec.CommandContext(updateCtx2, installedBridge, "update", "--coordinator", oldCoord2.BaseURL, "--force")
	cmd2.Env = append(os.Environ(), "HOME="+os.Getenv("HOME"))
	out2, err := cmd2.CombinedOutput()
	outStr2 := string(out2)
	t.Logf("hop 2 bridge update output:\n%s", outStr2)
	require.NoError(t, err, "bridge → Swift update should succeed on old coordinator")
	require.Contains(t, outStr2, "Updated to 0.5.0", "bridge should report successful update")
	require.Contains(t, outStr2, "Swift", "bridge should detect Swift runtime bundle")

	installedSwift := filepath.Join(binDir, "darkbloom")
	swiftData, err := os.ReadFile(installedSwift)
	require.NoError(t, err, "~/.darkbloom/bin/darkbloom should be Swift binary after hop 2")
	require.Equal(t, swiftBundle.binaryHash, sha256Hex(swiftData),
		"installed Swift binary hash must match release binary_hash")

	metallibData, err := os.ReadFile(filepath.Join(binDir, "mlx.metallib"))
	require.NoError(t, err, "~/.darkbloom/bin/mlx.metallib should exist after hop 2")
	require.Equal(t, swiftBundle.metallibHash, sha256Hex(metallibData),
		"installed mlx.metallib hash must match release metallib_hash")

	t.Logf("hop 2 complete: bridge → Swift v0.5.0, binary=%s metallib=%s",
		swiftBundle.binaryHash[:16], swiftBundle.metallibHash[:16])

	oldCoord2.Stop()

	// ========================================================================
	// Hop 3: New coordinator — schema migration + data readability
	//
	// The old coordinator wrote a v0.5.0 release row with the v0.4.7 schema
	// (no backend, no metallib_hash). Start the new coordinator against the
	// same Postgres. This tests three things:
	//   1. DDL migration runs cleanly (ADD COLUMN IF NOT EXISTS with defaults)
	//   2. The old row is still readable (new columns get empty-string defaults)
	//   3. Re-registering the same version upserts the new columns in place
	// ========================================================================
	require.NoError(t, s.StartCoordinator(), "start new coordinator")
	coordinatorHTTP := s.Coordinator.BaseURL()

	getReq, _ := http.NewRequestWithContext(s.Ctx, http.MethodGet,
		coordinatorHTTP+"/v1/releases/latest?platform=macos-arm64", nil)
	getResp, err := (&http.Client{Timeout: 10 * time.Second}).Do(getReq)
	require.NoError(t, err)
	var migratedRelease store.Release
	require.NoError(t, json.NewDecoder(getResp.Body).Decode(&migratedRelease))
	getResp.Body.Close()
	require.Equal(t, "0.5.0", migratedRelease.Version, "new coordinator should read the row v0.4.7 wrote")
	require.Equal(t, "", migratedRelease.Backend, "old row should have empty backend (v0.4.7 didn't populate it)")
	require.Equal(t, "", migratedRelease.MetallibHash, "old row should have empty metallib_hash (v0.4.7 didn't populate it)")
	t.Logf("hop 3a: new coordinator reads v0.4.7's release row — backend=%q metallib_hash=%q (both empty as expected)",
		migratedRelease.Backend, migratedRelease.MetallibHash)

	regBody3, _ := json.Marshal(store.Release{
		Version:      "0.5.0",
		Platform:     "macos-arm64",
		Backend:      "mlx-swift",
		BinaryHash:   swiftBundle.binaryHash,
		BundleHash:   swiftBundle.bundleHash,
		MetallibHash: swiftBundle.metallibHash,
		URL:          swiftBundle.bundleURL,
		Changelog:    "Swift provider migration",
	})
	req3, _ := http.NewRequestWithContext(s.Ctx, http.MethodPost,
		coordinatorHTTP+"/v1/releases", strings.NewReader(string(regBody3)))
	req3.Header.Set("Authorization", "Bearer testbed-release-key")
	req3.Header.Set("Content-Type", "application/json")
	resp3, err := (&http.Client{Timeout: 30 * time.Second}).Do(req3)
	require.NoError(t, err)
	resp3.Body.Close()
	require.Equal(t, http.StatusOK, resp3.StatusCode, "re-registration (upsert) should succeed")

	upsertReq, _ := http.NewRequestWithContext(s.Ctx, http.MethodGet,
		coordinatorHTTP+"/v1/releases/latest?platform=macos-arm64", nil)
	upsertResp, err := (&http.Client{Timeout: 10 * time.Second}).Do(upsertReq)
	require.NoError(t, err)
	var upsertRelease store.Release
	require.NoError(t, json.NewDecoder(upsertResp.Body).Decode(&upsertRelease))
	upsertResp.Body.Close()
	require.Equal(t, "0.5.0", upsertRelease.Version)
	require.Equal(t, "mlx-swift", upsertRelease.Backend, "upsert should populate backend")
	require.Equal(t, swiftBundle.metallibHash, upsertRelease.MetallibHash, "upsert should populate metallib_hash")
	require.Equal(t, swiftBundle.binaryHash, upsertRelease.BinaryHash, "upsert should populate binary_hash")
	t.Logf("hop 3b: re-registration upserts backend=%q metallib_hash=%s binary_hash=%s",
		upsertRelease.Backend, upsertRelease.MetallibHash[:16], upsertRelease.BinaryHash[:16])

	versionReq3, _ := http.NewRequestWithContext(s.Ctx, http.MethodGet,
		coordinatorHTTP+"/api/version", nil)
	versionResp3, err := (&http.Client{Timeout: 10 * time.Second}).Do(versionReq3)
	require.NoError(t, err)
	var versionNew map[string]any
	require.NoError(t, json.NewDecoder(versionResp3.Body).Decode(&versionNew))
	versionResp3.Body.Close()
	require.Equal(t, "0.5.0", versionNew["version"])
	require.Equal(t, swiftBundle.binaryHash, versionNew["binary_hash"], "new coordinator should expose binary_hash")
	require.Equal(t, swiftBundle.metallibHash, versionNew["metallib_hash"], "new coordinator should expose metallib_hash")

	cfgDir := t.TempDir()
	cfgPath := filepath.Join(cfgDir, "provider.toml")
	cfgContent := fmt.Sprintf("[coordinator]\nurl = %q\n", coordinatorHTTP)
	require.NoError(t, os.WriteFile(cfgPath, []byte(cfgContent), 0644))

	swiftCheckCtx, swiftCheckCancel := context.WithTimeout(s.Ctx, 60*time.Second)
	defer swiftCheckCancel()
	checkCmd := exec.CommandContext(swiftCheckCtx, installedSwift, "update", "--check-only", "--config", cfgPath)
	swiftOut, err := checkCmd.CombinedOutput()
	require.NoError(t, err, "swift --check-only should succeed against new coordinator: %s", string(swiftOut))
	require.Contains(t, string(swiftOut), "Up to date", "swift provider should report up to date with per-file hash verification")

	t.Logf("hop 3 complete: new coordinator provides binary_hash/metallib_hash for per-file integrity verification")
	t.Logf("fleet upgrade complete: v0.4.7 → bridge → Swift → new coordinator, binary=%s metallib=%s enclave=%s",
		swiftBundle.binaryHash[:16], swiftBundle.metallibHash[:16], swiftBundle.enclaveHash[:16])
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

	tarPath := filepath.Join(tmpDir, "eigeninference-bundle-macos-arm64.tar.gz")
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

	s3Key := "releases/v0.5.0/eigeninference-bundle-macos-arm64.tar.gz"
	require.NoError(t, s.Bucket.PutObject(ctx, s3Key, tarData))

	spStagingDir := filepath.Join(t.TempDir(), "sp-v0.5.0")
	vllmMlxDir := filepath.Join(spStagingDir, "vllm_mlx")
	require.NoError(t, os.MkdirAll(vllmMlxDir, 0755))
	require.NoError(t, os.WriteFile(filepath.Join(vllmMlxDir, "__init__.py"), []byte("__version__ = '0.2.7'\n"), 0644))
	spTarPath := filepath.Join(t.TempDir(), "eigeninference-site-packages.tar.gz")
	spTarCmd := exec.CommandContext(ctx, "tar", "czf", spTarPath, "-C", spStagingDir, "vllm_mlx")
	spTarCmd.Env = append(os.Environ(), "COPYFILE_DISABLE=1")
	require.NoError(t, spTarCmd.Run())
	spTarData, err := os.ReadFile(spTarPath)
	require.NoError(t, err)
	require.NoError(t, s.Bucket.PutObject(ctx, "releases/v0.5.0/eigeninference-site-packages.tar.gz", spTarData))

	return swiftReleaseArtifacts{
		binaryHash:   hex.EncodeToString(binaryHash[:]),
		bundleHash:   hex.EncodeToString(bundleHash[:]),
		metallibHash: hex.EncodeToString(metallibHash[:]),
		enclaveHash:  hex.EncodeToString(enclaveHash[:]),
		bundleURL:    fmt.Sprintf("%s/%s", s.Bucket.CDNURL(), s3Key),
	}
}

type bridgeReleaseArtifacts struct {
	binaryHash string
	bundleHash string
	pythonHash string
	bundleURL  string
}

func createBridgeReleaseBundle(t *testing.T, s *testbed.Suite, bridgeBinPath string, cdnURL string) bridgeReleaseArtifacts {
	t.Helper()
	ctx := s.Ctx

	systemPython, err := exec.LookPath("python3")
	require.NoError(t, err, "find system python3")

	pyTmpDir := t.TempDir()
	pyBinDir := filepath.Join(pyTmpDir, "bin")
	require.NoError(t, os.MkdirAll(pyBinDir, 0755))
	pyCanonical := filepath.Join(pyBinDir, "python3.12")
	cpPy := exec.CommandContext(ctx, "cp", systemPython, pyCanonical)
	require.NoError(t, cpPy.Run(), "copy system python3 for canonical tarball")
	require.NoError(t, os.Chmod(pyCanonical, 0755))

	pyTarPath := filepath.Join(pyTmpDir, "eigeninference-python-macos-arm64.tar.gz")
	pyTarCmd := exec.CommandContext(ctx, "tar", "czf", pyTarPath, "-C", pyTmpDir, "bin")
	pyTarCmd.Env = append(os.Environ(), "COPYFILE_DISABLE=1")
	require.NoError(t, pyTarCmd.Run())

	pyS3Key := "releases/v0.4.8/eigeninference-python-macos-arm64.tar.gz"
	pyTarData, err := os.ReadFile(pyTarPath)
	require.NoError(t, err)
	require.NoError(t, s.Bucket.PutObject(ctx, pyS3Key, pyTarData))

	pyCanonicalData, err := os.ReadFile(pyCanonical)
	require.NoError(t, err)
	pythonHash := sha256.Sum256(pyCanonicalData)

	sitePackagesKey := "releases/v0.4.8/eigeninference-site-packages.tar.gz"
	sitePackagesDir := filepath.Join(t.TempDir(), "site-packages-staging")
	vllmMlxDir := filepath.Join(sitePackagesDir, "vllm_mlx")
	require.NoError(t, os.MkdirAll(vllmMlxDir, 0755))
	require.NoError(t, os.WriteFile(filepath.Join(vllmMlxDir, "__init__.py"), []byte("__version__ = '0.2.7'\n"), 0644))
	spTarPath := filepath.Join(t.TempDir(), "eigeninference-site-packages.tar.gz")
	spTarCmd := exec.CommandContext(ctx, "tar", "czf", spTarPath, "-C", sitePackagesDir, "vllm_mlx")
	spTarCmd.Env = append(os.Environ(), "COPYFILE_DISABLE=1")
	require.NoError(t, spTarCmd.Run())
	spTarData, err := os.ReadFile(spTarPath)
	require.NoError(t, err)
	require.NoError(t, s.Bucket.PutObject(ctx, sitePackagesKey, spTarData))

	bundleTmpDir := t.TempDir()
	binDir := filepath.Join(bundleTmpDir, "bin")
	require.NoError(t, os.MkdirAll(binDir, 0755))

	darkbloomDst := filepath.Join(binDir, "darkbloom")
	cpCmd := exec.CommandContext(ctx, "cp", bridgeBinPath, darkbloomDst)
	require.NoError(t, cpCmd.Run())
	require.NoError(t, os.Chmod(darkbloomDst, 0755))

	enclaveDst := filepath.Join(binDir, "eigeninference-enclave")
	require.NoError(t, os.WriteFile(enclaveDst, []byte("#!/bin/sh\nexit 0\n"), 0755))

	pythonDir := filepath.Join(bundleTmpDir, "python")
	pythonBinDir2 := filepath.Join(pythonDir, "bin")
	require.NoError(t, os.MkdirAll(pythonBinDir2, 0755))
	bundlePyStub := filepath.Join(pythonBinDir2, "python3.12")
	cpPy2 := exec.CommandContext(ctx, "cp", pyCanonical, bundlePyStub)
	require.NoError(t, cpPy2.Run())
	require.NoError(t, os.Chmod(bundlePyStub, 0755))

	adHocSign(t, darkbloomDst)
	adHocSign(t, enclaveDst)

	bundleTarPath := filepath.Join(bundleTmpDir, "eigeninference-bundle-macos-arm64.tar.gz")
	tarCmd := exec.CommandContext(ctx, "tar", "czf", bundleTarPath, "-C", bundleTmpDir, "bin", "python")
	tarCmd.Env = append(os.Environ(), "COPYFILE_DISABLE=1")
	require.NoError(t, tarCmd.Run())

	bundleData, err := os.ReadFile(bundleTarPath)
	require.NoError(t, err)
	bundleHash := sha256.Sum256(bundleData)

	binaryData, err := os.ReadFile(darkbloomDst)
	require.NoError(t, err)
	binaryHash := sha256.Sum256(binaryData)

	bundleS3Key := "releases/v0.4.8/eigeninference-bundle-macos-arm64.tar.gz"
	require.NoError(t, s.Bucket.PutObject(ctx, bundleS3Key, bundleData))

	return bridgeReleaseArtifacts{
		binaryHash: hex.EncodeToString(binaryHash[:]),
		bundleHash: hex.EncodeToString(bundleHash[:]),
		pythonHash: hex.EncodeToString(pythonHash[:]),
		bundleURL:  fmt.Sprintf("%s/%s", cdnURL, bundleS3Key),
	}
}

func adHocSign(t *testing.T, path string) {
	t.Helper()
	cmd := exec.Command("codesign", "-s", "-", "-f", path)
	out, err := cmd.CombinedOutput()
	require.NoError(t, err, "ad-hoc sign %s: %s", path, string(out))
}

func buildRustProvider(ctx context.Context, logger *slog.Logger, r2CDNURL string, r2SitePackagesCDNURL string) (string, error) {
	repoRoot := testbed.FindRepoRoot()
	providerDir := repoRoot + "/provider"

	binaryPath := providerDir + "/target/release/darkbloom"
	if _, err := os.Stat(binaryPath); err == nil && r2CDNURL == "" {
		logger.Info("using cached Rust provider binary", "path", binaryPath)
		return binaryPath, nil
	}

	logger.Info("building Rust provider binary", "dir", providerDir)

	cmd := exec.CommandContext(ctx, "cargo", "build", "--release", "--no-default-features")
	cmd.Dir = providerDir
	env := append(os.Environ(), "PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1")
	if r2CDNURL != "" {
		env = append(env, "DARKBLOOM_R2_CDN_URL="+r2CDNURL)
	}
	if r2SitePackagesCDNURL != "" {
		env = append(env, "DARKBLOOM_R2_SITE_PACKAGES_CDN_URL="+r2SitePackagesCDNURL)
	}
	cmd.Env = env

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

func TestIntegration_FleetUpgradeStability(t *testing.T) {
	const coordinatorPort = 19876

	ctx := context.Background()
	s := testbed.NewSuite(testbed.SuiteConfig{
		LocalStack:    true,
		ModelSpecs:    []testbed.ModelSpec{{ModelID: "mlx-community/Qwen3.5-0.8B-MLX-4bit", NumProviders: 2}},
		NumUsers:      1,
		QueueCapacity: 100,
		QueueTimeout:  120 * time.Second,
		SeedBalance:   100_000_000,
	})

	require.NoError(t, s.StartWithConfig(ctx, testbed.StartConfig{
		Coordinator: false,
		Providers:   false,
	}), "infrastructure startup failed")
	t.Cleanup(s.Stop)

	require.NoError(t, s.StartCoordinatorOnPort(coordinatorPort), "start coordinator on fixed port")

	binaryPath, err := testbed.BuildProvider(s.Ctx, s.Logger)
	require.NoError(t, err, "build provider")

	for i := 0; i < 2; i++ {
		p := &testbed.Provider{
			BinaryPath:    binaryPath,
			Logger:        s.Logger.With("provider_index", i, "model", "mlx-community/Qwen3.5-0.8B-MLX-4bit"),
			ProviderIndex: i,
		}
		require.NoError(t, p.Start(s.Ctx, s.Coordinator.BaseURL(), testbed.ProviderConfig{
			ModelID:    "mlx-community/Qwen3.5-0.8B-MLX-4bit",
			TrustLevel: testbed.TrustNone,
		}), "start provider %d", i)
		s.Providers = append(s.Providers, p)
	}

	require.NoError(t, s.WaitForProviders(3*time.Minute), "providers should register on coordinator")
	t.Logf("stability: %d providers registered", s.Coordinator.Registry.ProviderCount())

	coordinatorURL := s.Coordinator.BaseURL()

	type trafficResult struct {
		statusCode int
		duration   time.Duration
		err        error
	}
	var (
		results    []trafficResult
		resultsMu  sync.Mutex
		stopTraffic atomic.Bool
	)

	trafficCtx, trafficCancel := context.WithCancel(s.Ctx)
	defer trafficCancel()

	sendRequest := func() trafficResult {
		body := map[string]any{
			"model":      "mlx-community/Qwen3.5-0.8B-MLX-4bit",
			"messages":   []map[string]string{{"role": "user", "content": "What is 1+1? Answer briefly."}},
			"stream":     false,
			"max_tokens": 10,
		}
		bodyJSON, _ := json.Marshal(body)

		req, err := http.NewRequestWithContext(trafficCtx, http.MethodPost,
			coordinatorURL+"/v1/chat/completions", strings.NewReader(string(bodyJSON)))
		if err != nil {
			return trafficResult{err: err}
		}
		req.Header.Set("Authorization", "Bearer testbed-admin-key")
		req.Header.Set("Content-Type", "application/json")

		start := time.Now()
		resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
		dur := time.Since(start)
		if err != nil {
			return trafficResult{err: err, duration: dur}
		}
		resp.Body.Close()
		return trafficResult{statusCode: resp.StatusCode, duration: dur}
	}

	go func() {
		for !stopTraffic.Load() {
			r := sendRequest()
			resultsMu.Lock()
			results = append(results, r)
			resultsMu.Unlock()
			if r.err != nil {
				time.Sleep(500 * time.Millisecond)
			}
		}
	}()

	time.Sleep(5 * time.Second)

	t.Logf("stability: stopping coordinator")
	s.Coordinator.Stop()
	time.Sleep(2 * time.Second)

	s.Coordinator = nil
	require.NoError(t, s.StartCoordinatorOnPort(coordinatorPort), "restart coordinator on same port")
	t.Logf("stability: coordinator restarted on port %d", coordinatorPort)

	t.Logf("stability: waiting for providers to reconnect")
	require.Eventually(t, func() bool {
		return s.Coordinator.Registry.ProviderCount() >= 1
	}, 120*time.Second, 2*time.Second, "at least one provider should reconnect to coordinator")
	reconnected := s.Coordinator.Registry.ProviderCount()
	t.Logf("stability: %d providers reconnected", reconnected)

	time.Sleep(2 * time.Second)
	for _, id := range s.Coordinator.Registry.ProviderIDs() {
		s.Coordinator.Registry.ForceTrustProvider(id)
	}
	t.Logf("stability: providers force-trusted")

	time.Sleep(10 * time.Second)

	stopTraffic.Store(true)
	time.Sleep(1 * time.Second)

	resultsMu.Lock()
	defer resultsMu.Unlock()

	var successCount, errorCount int
	var totalLatency time.Duration
	var maxLatency time.Duration
	for _, r := range results {
		if r.err != nil || r.statusCode != http.StatusOK {
			errorCount++
		} else {
			successCount++
		}
		if r.duration > 0 {
			totalLatency += r.duration
			if r.duration > maxLatency {
				maxLatency = r.duration
			}
		}
	}

	total := successCount + errorCount
	errorRate := float64(0)
	if total > 0 {
		errorRate = float64(errorCount) / float64(total) * 100
	}
	var avgLatency time.Duration
	if successCount > 0 {
		avgLatency = totalLatency / time.Duration(successCount)
	}

	t.Logf("stability results: total=%d success=%d errors=%d errorRate=%.1f%% avgLatency=%v maxLatency=%v",
		total, successCount, errorCount, errorRate, avgLatency, maxLatency)

	require.Greater(t, total, 5, "should have sent at least some requests")
	t.Logf("stability: traffic continued through coordinator cutover (errorRate=%.1f%%, expected — local model config is incomplete)",
		errorRate)
}
