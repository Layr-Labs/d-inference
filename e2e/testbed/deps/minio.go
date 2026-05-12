package deps

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

type MinIOLifecycle struct {
	Port        int
	EndpointURL string
	Logger      *slog.Logger
	binPath     string
	cmd         *exec.Cmd
	tmpDir      string
}

func NewMinIOLifecycle(logger *slog.Logger, port int) *MinIOLifecycle {
	return &MinIOLifecycle{
		Port:   port,
		Logger: logger,
	}
}

func (m *MinIOLifecycle) Start(ctx context.Context) error {
	binPath, err := exec.LookPath("minio")
	if err != nil {
		return fmt.Errorf("testbed/deps: minio not found in PATH (install with: brew install minio/stable/minio)")
	}
	m.binPath = binPath

	if m.Port == 0 {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return fmt.Errorf("testbed/deps: find free port: %w", err)
		}
		m.Port = listener.Addr().(*net.TCPAddr).Port
		listener.Close()
	}

	m.EndpointURL = fmt.Sprintf("http://127.0.0.1:%d", m.Port)

	m.tmpDir = filepath.Join(os.TempDir(), fmt.Sprintf("testbed-minio-%d-%04d", time.Now().UnixMilli(), rand.Intn(10000)))
	if err := os.MkdirAll(m.tmpDir, 0755); err != nil {
		return fmt.Errorf("testbed/deps: create minio data dir: %w", err)
	}

	m.cmd = exec.CommandContext(ctx, m.binPath, "server", m.tmpDir,
		"--address", fmt.Sprintf("127.0.0.1:%d", m.Port),
		"--console-address", ":0",
	)
	m.cmd.Env = append(os.Environ(),
		"MINIO_ROOT_USER=test",
		"MINIO_ROOT_PASSWORD=testtest",
	)

	if err := m.cmd.Start(); err != nil {
		return fmt.Errorf("testbed/deps: start minio: %w", err)
	}

	if err := m.waitForReady(ctx); err != nil {
		m.Stop()
		return fmt.Errorf("testbed/deps: minio readiness: %w", err)
	}

	m.Logger.Info("ephemeral minio started", "port", m.Port, "endpoint", m.EndpointURL, "dataDir", m.tmpDir)
	return nil
}

func (m *MinIOLifecycle) waitForReady(ctx context.Context) error {
	url := fmt.Sprintf("http://127.0.0.1:%d/minio/health/live", m.Port)
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
	return fmt.Errorf("testbed/deps: minio did not become ready within 30s")
}

func (m *MinIOLifecycle) Stop() {
	if m.cmd != nil && m.cmd.Process != nil {
		m.cmd.Process.Signal(os.Interrupt)
		done := make(chan error, 1)
		go func() {
			_, _ = m.cmd.Process.Wait()
			done <- nil
		}()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			m.cmd.Process.Kill()
		}
	}
	if m.tmpDir != "" {
		os.RemoveAll(m.tmpDir)
	}
	m.Logger.Info("ephemeral minio removed", "dataDir", m.tmpDir)
}
