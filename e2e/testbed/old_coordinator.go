package testbed

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"time"
)

const OldCoordinatorTag = "v0.4.7"

type OldCoordinatorProcess struct {
	BinPath string
	BaseURL string
	Port    int
	cmd     *exec.Cmd
	cancel  context.CancelFunc
	waitCh  chan error
}

func BuildOldCoordinator(ctx context.Context, logger *slog.Logger) (string, error) {
	repoRoot := FindRepoRoot()

	cacheDir := filepath.Join(repoRoot, ".cache", "e2e-binaries")
	binPath := filepath.Join(cacheDir, "coordinator-"+OldCoordinatorTag)
	if _, err := os.Stat(binPath); err == nil {
		logger.Info("using cached old coordinator binary", "path", binPath)
		return binPath, nil
	}

	sourceDir := filepath.Join(cacheDir, "src-"+OldCoordinatorTag)
	if _, err := os.Stat(filepath.Join(sourceDir, "coordinator")); os.IsNotExist(err) {
		if err := os.MkdirAll(sourceDir, 0755); err != nil {
			return "", fmt.Errorf("create source dir: %w", err)
		}
		archiveCmd := exec.CommandContext(ctx, "git", "archive", OldCoordinatorTag, "--", "coordinator/")
		archiveCmd.Dir = repoRoot
		tarCmd := exec.CommandContext(ctx, "tar", "x", "-C", sourceDir)
		pr, pw, err := os.Pipe()
		if err != nil {
			return "", fmt.Errorf("pipe: %w", err)
		}
		archiveCmd.Stdout = pw
		tarCmd.Stdin = pr
		if err := archiveCmd.Start(); err != nil {
			return "", fmt.Errorf("git archive start: %w", err)
		}
		if err := tarCmd.Start(); err != nil {
			return "", fmt.Errorf("tar start: %w", err)
		}
		if err := archiveCmd.Wait(); err != nil {
			return "", fmt.Errorf("git archive: %w", err)
		}
		pw.Close()
		if err := tarCmd.Wait(); err != nil {
			return "", fmt.Errorf("tar extract: %w", err)
		}
	}

	logger.Info("building old coordinator binary", "tag", OldCoordinatorTag, "dir", sourceDir)
	buildCmd := exec.CommandContext(ctx, "go", "build", "-o", binPath, "./cmd/coordinator")
	buildCmd.Dir = filepath.Join(sourceDir, "coordinator")
	buildCmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	out, err := buildCmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("go build old coordinator: %w: %s", err, string(out))
	}

	logger.Info("old coordinator binary built", "path", binPath)
	return binPath, nil
}

func StartOldCoordinator(ctx context.Context, logger *slog.Logger, binPath string, pgURL string, bucketCDNURL string, port int) (*OldCoordinatorProcess, error) {
	if port <= 0 {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return nil, fmt.Errorf("listen: %w", err)
		}
		port = listener.Addr().(*net.TCPAddr).Port
		listener.Close()
	}

	baseURL := "http://127.0.0.1:" + strconv.Itoa(port)

	ctx, cancel := context.WithCancel(ctx)

	cmd := exec.CommandContext(ctx, binPath)
	cmd.Env = append(os.Environ(),
		"EIGENINFERENCE_PORT="+strconv.Itoa(port),
		"EIGENINFERENCE_DATABASE_URL="+pgURL,
		"EIGENINFERENCE_ADMIN_KEY=testbed-admin-key",
		"EIGENINFERENCE_RELEASE_KEY=testbed-release-key",
		"EIGENINFERENCE_MIN_TRUST=none",
		"EIGENINFERENCE_R2_CDN_URL="+bucketCDNURL,
		"EIGENINFERENCE_R2_SITE_PACKAGES_CDN_URL="+bucketCDNURL,
	)

	cmd.Stdout = &logWriter{logger: logger, prefix: "old-coord:stdout"}
	cmd.Stderr = &logWriter{logger: logger, prefix: "old-coord:stderr"}

	if err := cmd.Start(); err != nil {
		cancel()
		return nil, fmt.Errorf("start old coordinator: %w", err)
	}

	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
	}()

	oc := &OldCoordinatorProcess{
		BinPath: binPath,
		BaseURL: baseURL,
		Port:    port,
		cmd:     cmd,
		cancel:  cancel,
		waitCh:  waitCh,
	}

	if err := oc.waitForReady(ctx); err != nil {
		oc.Stop()
		return nil, fmt.Errorf("old coordinator readiness: %w", err)
	}

	logger.Info("old coordinator started", "port", port, "base_url", baseURL)
	return oc, nil
}

func (oc *OldCoordinatorProcess) waitForReady(ctx context.Context) error {
	url := oc.BaseURL + "/health"
	for i := 0; i < 60; i++ {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
		resp, err := http.DefaultClient.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return nil
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	return fmt.Errorf("old coordinator did not become ready within 30s")
}

func (oc *OldCoordinatorProcess) Stop() {
	if oc.cancel != nil {
		oc.cancel()
	}
	if oc.cmd != nil && oc.cmd.Process != nil {
		oc.cmd.Process.Signal(os.Interrupt)
		select {
		case <-oc.waitCh:
		case <-time.After(5 * time.Second):
			oc.cmd.Process.Kill()
		}
	}
}
