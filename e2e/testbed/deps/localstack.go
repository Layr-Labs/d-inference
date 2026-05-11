package deps

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"net"
	"net/http"
	"os/exec"
	"time"
)

type LocalStackLifecycle struct {
	ContainerID string
	Port        int
	EndpointURL string
	Logger      *slog.Logger
}

func NewLocalStackLifecycle(logger *slog.Logger, port int) *LocalStackLifecycle {
	return &LocalStackLifecycle{
		Port:   port,
		Logger: logger,
	}
}

func (ls *LocalStackLifecycle) Start(ctx context.Context) error {
	if _, err := exec.LookPath("docker"); err != nil {
		return fmt.Errorf("testbed/deps: docker not found in PATH (required for LocalStack)")
	}

	if ls.Port == 0 {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return fmt.Errorf("testbed/deps: find free port: %w", err)
		}
		ls.Port = listener.Addr().(*net.TCPAddr).Port
		listener.Close()
	}

	ls.EndpointURL = fmt.Sprintf("http://127.0.0.1:%d", ls.Port)

	containerName := fmt.Sprintf("testbed-ls-%d-%04d", time.Now().UnixMilli(), rand.Intn(10000))

	args := []string{
		"run", "-d",
		"--name", containerName,
		"-p", fmt.Sprintf("127.0.0.1:%d:4566", ls.Port),
		"localstack/localstack:3",
	}

	cmd := exec.CommandContext(ctx, "docker", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("testbed/deps: docker run localstack: %w: %s", err, string(out))
	}

	ls.ContainerID = containerName

	if err := ls.waitForReady(ctx); err != nil {
		ls.Stop()
		return fmt.Errorf("testbed/deps: localstack readiness: %w", err)
	}

	ls.Logger.Info("ephemeral localstack started", "port", ls.Port, "endpoint", ls.EndpointURL, "container", containerName)
	return nil
}

func (ls *LocalStackLifecycle) waitForReady(ctx context.Context) error {
	url := fmt.Sprintf("http://127.0.0.1:%d/_localstack/health", ls.Port)
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
	return fmt.Errorf("testbed/deps: localstack did not become ready within 30s")
}

func (ls *LocalStackLifecycle) Stop() {
	if ls.ContainerID == "" {
		return
	}
	cmd := exec.Command("docker", "rm", "-f", ls.ContainerID)
	if out, err := cmd.CombinedOutput(); err != nil {
		ls.Logger.Error("failed to remove localstack container", "error", err, "output", string(out))
	} else {
		ls.Logger.Info("ephemeral localstack removed", "container", ls.ContainerID)
	}
	ls.ContainerID = ""
}