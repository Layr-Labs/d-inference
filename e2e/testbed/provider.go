package testbed

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func providerBuildConfig() string {
	if cfg := os.Getenv("TESTBED_PROVIDER_CONFIG"); cfg != "" {
		return cfg
	}
	return "release"
}

func BuildProvider(ctx context.Context, logger *slog.Logger) (string, error) {
	if binaryPath := os.Getenv("DARKBLOOM_PROVIDER_BINARY"); binaryPath != "" {
		info, err := os.Stat(binaryPath)
		if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
			return "", fmt.Errorf("configured provider binary is not executable: %s", binaryPath)
		}
		metallibPath := filepath.Join(filepath.Dir(binaryPath), "mlx.metallib")
		if metallib, metallibErr := os.Stat(metallibPath); metallibErr != nil || metallib.IsDir() {
			return "", fmt.Errorf("configured provider metallib not found beside binary: %s", metallibPath)
		}
		logger.Info("using configured provider binary", "path", binaryPath)
		return binaryPath, nil
	}
	repoRoot := os.Getenv("DARKBLOOM_REPO_ROOT")
	if repoRoot == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return "", fmt.Errorf("resolve repository root: %w", err)
		}
		repoRoot, err = findRepositoryRoot(cwd)
		if err != nil {
			return "", err
		}
	}
	providerDir := filepath.Join(repoRoot, "provider-swift")
	cfg := providerBuildConfig()

	showBinPath := exec.CommandContext(ctx, "swift", "build", "-c", cfg, "--show-bin-path")
	showBinPath.Dir = providerDir
	binPathOutput, err := showBinPath.Output()
	if err != nil {
		return "", fmt.Errorf("resolve provider build path: %w", err)
	}
	binPath := strings.TrimSpace(string(binPathOutput))
	if binPath == "" {
		return "", fmt.Errorf("resolve provider build path: swift returned an empty path")
	}
	binaryPath := filepath.Join(binPath, "darkbloom")

	logger.Info("building provider binary", "dir", providerDir, "config", cfg)
	cmd := exec.CommandContext(ctx, "swift", "build", "-c", cfg)
	cmd.Dir = providerDir
	out, buildErr := cmd.CombinedOutput()
	if buildErr != nil {
		return "", fmt.Errorf("swift build provider: %w: %s", buildErr, string(out))
	}
	if info, statErr := os.Stat(binaryPath); statErr != nil || info.IsDir() || info.Mode()&0o111 == 0 {
		return "", fmt.Errorf("provider binary not found after build: %s", binaryPath)
	}

	// Candidate binaries always receive a freshly staged metallib from the
	// exact nested MLX source. An existing colocated file is not evidence that
	// it matches the host code.
	if err := ensureMetallib(ctx, repoRoot, binPath, logger); err != nil {
		return "", fmt.Errorf("metallib setup: %w", err)
	}

	logger.Info("provider binary ready", "path", binaryPath)
	return binaryPath, nil
}

func findRepositoryRoot(start string) (string, error) {
	current, err := filepath.Abs(start)
	if err != nil {
		return "", fmt.Errorf("resolve repository root from %q: %w", start, err)
	}
	for {
		goMod, goModErr := os.Stat(filepath.Join(current, "go.mod"))
		provider, providerErr := os.Stat(filepath.Join(current, "provider-swift"))
		if goModErr == nil && !goMod.IsDir() && providerErr == nil && provider.IsDir() {
			return current, nil
		}
		parent := filepath.Dir(current)
		if parent == current {
			return "", fmt.Errorf("repository root not found above %q", start)
		}
		current = parent
	}
}

func ensureMetallib(
	ctx context.Context,
	repoRoot string,
	binPath string,
	logger *slog.Logger,
) error {
	helper := filepath.Join(repoRoot, "scripts", "fetch-metallib.sh")
	info, err := os.Stat(helper)
	if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
		return fmt.Errorf("source metallib helper is not executable: %s", helper)
	}

	cmd := exec.Command(helper, binPath)
	cmd.Dir = repoRoot
	out, err := runProcessGroup(ctx, cmd)
	if len(out) != 0 {
		(&logWriter{logger: logger, prefix: "metallib helper"}).Write(out)
	}
	if err != nil {
		return fmt.Errorf("build source-matched metallib: %w", err)
	}

	metallibPath := filepath.Join(binPath, "mlx.metallib")
	metallib, err := os.Stat(metallibPath)
	if err != nil || metallib.IsDir() || metallib.Size() == 0 {
		return fmt.Errorf("source metallib helper did not stage %s", metallibPath)
	}
	return nil
}

func runProcessGroup(ctx context.Context, cmd *exec.Cmd) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return output.Bytes(), err
	}

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	select {
	case err := <-done:
		return output.Bytes(), err
	case <-ctx.Done():
		// Let the helper shell handle TERM and run its EXIT cleanup. If CMake
		// or a compiler child does not exit promptly, kill the entire group.
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			<-done
		}
		return output.Bytes(), ctx.Err()
	}
}

func findProviderBinary() string {
	if path := os.Getenv("DARKBLOOM_PROVIDER_BINARY"); path != "" {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	if path, err := exec.LookPath("darkbloom"); err == nil {
		return path
	}
	return ""
}

// BuildProviderTOML renders the minimal provider config the testbed needs in
// order to select a CBv2 KV backend and/or a per-slot concurrency cap.
//
// This file exists ONLY because those two settings have no env-var or CLI
// equivalent. In particular DARKBLOOM_CBV2_PAGED_KV is negative-polarity — it
// can force paged OFF but never ON — so `engine_v2_kv_backend = "paged"` under
// `[backend]` is the sole way an e2e run can exercise paged KV.
//
// A config is always returned, even when both performance knobs are unset.
// `auto_update` / `auto_restart` must remain pinned off: otherwise the default
// testbed launch installs a launchd watchdog that outlives the provider process
// and leaks into later tests (or the operator's real provider session).
func BuildProviderTOML(cfg ProviderConfig, providerIndex int) (string, error) {
	backend := ResolveKVBackend(cfg.KVBackend)
	maxConcurrent, err := ResolveMaxConcurrent(cfg.MaxConcurrent)
	if err != nil {
		return "", err
	}
	switch backend {
	case "", KVBackendAuto, KVBackendPaged, KVBackendContiguous:
	default:
		return "", fmt.Errorf("invalid KV backend %q: want %q, %q or %q",
			backend, KVBackendAuto, KVBackendPaged, KVBackendContiguous)
	}
	if maxConcurrent < 0 {
		return "", fmt.Errorf("invalid max concurrent %d: must be >= 0", maxConcurrent)
	}

	var b strings.Builder
	b.WriteString(testbedConfigMarker + "\n")
	b.WriteString("[provider]\n")
	fmt.Fprintf(&b, "name = \"darkbloom-testbed-%d\"\n", providerIndex)
	b.WriteString("auto_update = false\n")
	b.WriteString("auto_restart = false\n")
	b.WriteString("\n[backend]\n")
	if backend != "" {
		fmt.Fprintf(&b, "engine_v2_kv_backend = %q\n", backend)
	}
	if maxConcurrent > 0 {
		fmt.Fprintf(&b, "engine_v2_max_concurrent = %d\n", maxConcurrent)
	}
	if cfg.MTPDrafterPath != "" {
		fmt.Fprintf(&b, "mtp_drafter_path = %q\n", cfg.MTPDrafterPath)
	}
	if cfg.MTPMode != "" {
		if cfg.MTPMode != "auto" && cfg.MTPMode != "on" && cfg.MTPMode != "off" {
			return "", fmt.Errorf("invalid explicit MTP mode %q", cfg.MTPMode)
		}
		fmt.Fprintf(&b, "mtp_mode = %q\n", cfg.MTPMode)
	}
	return b.String(), nil
}

// testbedConfigMarker heads every TOML BuildProviderTOML generates, so a
// stray copy is recognisable as the testbed's.
const testbedConfigMarker = "# Generated by the d-inference e2e testbed. Do not edit."

type logWriter struct {
	logger *slog.Logger
	prefix string
}

func (w *logWriter) Write(p []byte) (int, error) {
	n := len(p)
	for _, line := range strings.Split(string(p), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			w.logger.Info(w.prefix, "line", line)
		}
	}
	return n, nil
}
