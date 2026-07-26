package testbed

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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

	binaryPath := providerDir + "/.build/" + cfg + "/darkbloom"
	if _, err := os.Stat(binaryPath); err == nil {
		metallibPath := providerDir + "/.build/" + cfg + "/mlx.metallib"
		if _, err2 := os.Stat(metallibPath); err2 == nil {
			logger.Info("using cached provider binary", "path", binaryPath)
			return binaryPath, nil
		}
	}

	logger.Info("building provider binary", "dir", providerDir, "config", cfg)

	cmd := exec.CommandContext(ctx, "swift", "build", "-c", cfg)
	cmd.Dir = providerDir

	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("swift build provider: %w: %s", err, string(out))
	}

	if _, err := os.Stat(binaryPath); err != nil {
		return "", fmt.Errorf("provider binary not found after build: %s", binaryPath)
	}

	if err := ensureMetallib(providerDir, logger); err != nil {
		return "", fmt.Errorf("metallib setup: %w", err)
	}

	logger.Info("provider binary built", "path", binaryPath)
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

func ensureMetallib(providerDir string, logger *slog.Logger) error {
	cfg := providerBuildConfig()
	metallibPath := providerDir + "/.build/" + cfg + "/mlx.metallib"
	if _, err := os.Stat(metallibPath); err == nil {
		return nil
	}

	if envPath := os.Getenv("MLX_METALLIB_PATH"); envPath != "" {
		if _, err := os.Stat(envPath); err == nil {
			return copyFile(envPath, metallibPath)
		}
	}

	siteDirs, _ := filepath.Glob("/tmp/mlxvenv/lib/python*/site-packages/mlx/lib")
	for _, dir := range siteDirs {
		src := filepath.Join(dir, "mlx.metallib")
		if _, err := os.Stat(src); err == nil {
			logger.Info("copying mlx.metallib from Python wheel", "src", src)
			return copyFile(src, metallibPath)
		}
	}

	return fmt.Errorf("mlx.metallib not found; install mlx==0.31.2 Python wheel and copy to %s or set MLX_METALLIB_PATH", metallibPath)
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0644)
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
// Returns ("", nil) when neither knob is set, so the default path never
// materialises a file and never grows a `--config` argument.
//
// `auto_update` / `auto_restart` are pinned off: a testbed provider must not
// self-update mid-suite, and must not install the launchd crash-recovery
// watchdog, which would outlive the test process.
func BuildProviderTOML(cfg ProviderConfig, providerIndex int) (string, error) {
	backend := ResolveKVBackend(cfg.KVBackend)
	maxConcurrent, err := ResolveMaxConcurrent(cfg.MaxConcurrent)
	if err != nil {
		return "", err
	}
	if backend == "" && maxConcurrent == 0 {
		return "", nil
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
	b.WriteString("# Generated by the d-inference e2e testbed. Do not edit.\n")
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
	return b.String(), nil
}

// canonicalProviderConfigPath is the path the provider copies a
// `--config`-supplied file to when nothing lives there yet (migrateConfigIfNeeded
// in the Swift CLI). The testbed tracks it so it can undo that copy on Stop: a
// testbed-generated TOML left behind there would silently become the machine's
// default config for every later provider run, including ones that pass no
// --config at all.
func canonicalProviderConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "darkbloom", "provider.toml")
}

// removeMigratedTestbedConfig deletes the canonical provider.toml only when it
// did not exist before this provider started AND its bytes are exactly the TOML
// the testbed generated. Both guards must hold, so a real operator config is
// never touched.
func removeMigratedTestbedConfig(generated string, existedBefore bool) {
	if generated == "" || existedBefore {
		return
	}
	path := canonicalProviderConfigPath()
	if path == "" {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != generated {
		return
	}
	_ = os.Remove(path)
}

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
