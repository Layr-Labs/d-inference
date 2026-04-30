package deps

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"time"
)

type PostgresLifecycle struct {
	ContainerID string
	Port        int
	DatabaseURL string
	Logger      *slog.Logger
}

func NewPostgresLifecycle(logger *slog.Logger, port int) *PostgresLifecycle {
	if port == 0 {
		port = 5433
	}
	return &PostgresLifecycle{
		Port:   port,
		Logger: logger,
	}
}

func (p *PostgresLifecycle) Start(ctx context.Context) error {
	if _, err := exec.LookPath("docker"); err != nil {
		return fmt.Errorf("testbed/deps: docker not found in PATH (required for ephemeral Postgres)")
	}

	p.DatabaseURL = fmt.Sprintf("postgres://testbed:testbed@127.0.0.1:%d/testbed?sslmode=disable", p.Port)

	containerName := fmt.Sprintf("testbed-postgres-%d", time.Now().UnixMilli())

	args := []string{
		"run", "-d",
		"--name", containerName,
		"-e", "POSTGRES_USER=testbed",
		"-e", "POSTGRES_PASSWORD=testbed",
		"-e", "POSTGRES_DB=testbed",
		"-p", fmt.Sprintf("127.0.0.1:%d:5432", p.Port),
		"postgres:16",
	}

	cmd := exec.CommandContext(ctx, "docker", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("testbed/deps: docker run postgres: %w: %s", err, string(out))
	}

	p.ContainerID = containerName

	if err := p.waitForReady(ctx); err != nil {
		p.Stop()
		return fmt.Errorf("testbed/deps: postgres readiness: %w", err)
	}

	p.Logger.Info("ephemeral postgres started", "port", p.Port, "container", containerName)
	return nil
}

func (p *PostgresLifecycle) waitForReady(ctx context.Context) error {
	for i := 0; i < 30; i++ {
		cmd := exec.CommandContext(ctx, "docker", "exec", p.ContainerID,
			"pg_isready", "-U", "testbed", "-d", "testbed")
		if err := cmd.Run(); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	return fmt.Errorf("testbed/deps: postgres did not become ready within 15s")
}

func (p *PostgresLifecycle) Stop() {
	if p.ContainerID == "" {
		return
	}
	cmd := exec.Command("docker", "rm", "-f", p.ContainerID)
	if out, err := cmd.CombinedOutput(); err != nil {
		p.Logger.Error("failed to remove postgres container", "error", err, "output", string(out))
	} else {
		p.Logger.Info("ephemeral postgres removed", "container", p.ContainerID)
	}
	p.ContainerID = ""
}

func (p *PostgresLifecycle) SetEnv() {
	os.Setenv("EIGENINFERENCE_DATABASE_URL", p.DatabaseURL)
}
