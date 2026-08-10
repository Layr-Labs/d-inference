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
