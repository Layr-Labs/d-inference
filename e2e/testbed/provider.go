package testbed

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func FindRepoRoot() string {
	if root := os.Getenv("DARKBLOOM_REPO_ROOT"); root != "" {
		return root
	}
	if out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output(); err == nil {
		if root := strings.TrimSpace(string(out)); root != "" {
			os.Setenv("DARKBLOOM_REPO_ROOT", root)
			return root
		}
	}
	if cwd, err := os.Getwd(); err == nil {
		dir := cwd
		for {
			if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
				os.Setenv("DARKBLOOM_REPO_ROOT", dir)
				return dir
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	return "."
}

func providerBuildConfig() string {
	if cfg := os.Getenv("TESTBED_PROVIDER_CONFIG"); cfg != "" {
		return cfg
	}
	return "release"
}

func BuildProvider(ctx context.Context, logger *slog.Logger) (string, error) {
	repoRoot := FindRepoRoot()
	providerDir := repoRoot + "/provider-swift"
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

func ModelCacheDir(modelID string) string {
	home, _ := os.UserHomeDir()
	parts := strings.SplitN(modelID, "/", 2)
	if len(parts) == 2 {
		return filepath.Join(home, ".cache", "huggingface", "hub",
			"models--"+parts[0]+"--"+parts[1])
	}
	return filepath.Join(home, ".cache", "huggingface", "hub",
		"models--"+modelID)
}

func EnsureModelCached(ctx context.Context, logger *slog.Logger, modelID string) error {
	cacheDir := ModelCacheDir(modelID)
	snapDir := filepath.Join(cacheDir, "snapshots", "local")
	configPath := filepath.Join(snapDir, "config.json")

	if _, err := os.Stat(configPath); err == nil {
		logger.Info("model already cached", "model", modelID, "path", snapDir)
		return nil
	}

	logger.Info("downloading model from HuggingFace", "model", modelID)

	_ = os.RemoveAll(cacheDir)
	_ = os.MkdirAll(snapDir, 0755)

	slug := strings.ReplaceAll(modelID, "/", "/")
	urlBase := "https://huggingface.co/" + slug + "/resolve/main"
	for _, file := range []string{"config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"} {
		url := urlBase + "/" + file
		dst := filepath.Join(snapDir, file)
		if err := downloadFile(ctx, url, dst); err != nil {
			return fmt.Errorf("download %s: %w", file, err)
		}
	}

	refsDir := filepath.Join(cacheDir, "refs")
	_ = os.MkdirAll(refsDir, 0755)
	if err := os.WriteFile(filepath.Join(refsDir, "main"), []byte("local\n"), 0644); err != nil {
		return fmt.Errorf("write refs/main: %w", err)
	}

	logger.Info("model cached", "model", modelID, "path", snapDir)
	return nil
}

func downloadFile(ctx context.Context, url, dst string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	f, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
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
