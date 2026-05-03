package deps

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

type PostgresLifecycle struct {
	ContainerID string
	Port        int
	DatabaseURL string
	Logger      *slog.Logger

	dataDir string
	native  bool
}

func NewPostgresLifecycle(logger *slog.Logger, port int) *PostgresLifecycle {
	return &PostgresLifecycle{
		Port:   port,
		Logger: logger,
	}
}

func (p *PostgresLifecycle) Start(ctx context.Context) error {
	if _, err := exec.LookPath("docker"); err == nil {
		return p.startDocker(ctx)
	}
	return p.startNative(ctx)
}

func (p *PostgresLifecycle) startDocker(ctx context.Context) error {
	if p.Port == 0 {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return fmt.Errorf("testbed/deps: find free port: %w", err)
		}
		p.Port = listener.Addr().(*net.TCPAddr).Port
		listener.Close()
	}

	p.DatabaseURL = fmt.Sprintf("postgres://testbed:testbed@127.0.0.1:%d/testbed?sslmode=disable", p.Port)

	containerName := fmt.Sprintf("testbed-pg-%d-%04d", time.Now().UnixMilli(), rand.Intn(10000))

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

	if err := p.waitForReadyDocker(ctx); err != nil {
		p.Stop()
		return fmt.Errorf("testbed/deps: postgres readiness: %w", err)
	}

	p.Logger.Info("ephemeral postgres started (docker)", "port", p.Port, "container", containerName)
	return nil
}

func (p *PostgresLifecycle) startNative(ctx context.Context) error {
	pgBin, err := exec.LookPath("postgres")
	if err != nil {
		return fmt.Errorf("testbed/deps: neither docker nor postgres found in PATH (need one for ephemeral Postgres)")
	}

	if p.Port == 0 {
		listener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			return fmt.Errorf("testbed/deps: find free port: %w", err)
		}
		p.Port = listener.Addr().(*net.TCPAddr).Port
		listener.Close()
	}

	p.dataDir = filepath.Join(os.TempDir(), fmt.Sprintf("testbed-pg-%d-%04d", time.Now().UnixMilli(), rand.Intn(10000)))
	if err := os.MkdirAll(p.dataDir, 0755); err != nil {
		return fmt.Errorf("testbed/deps: create data dir: %w", err)
	}

	initdb, _ := exec.LookPath("initdb")
	if initdb == "" {
		initdb = filepath.Join(filepath.Dir(pgBin), "initdb")
	}
	cmd := exec.CommandContext(ctx, initdb, "-D", p.dataDir, "-U", "testbed", "-A", "trust")
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("testbed/deps: initdb: %w: %s", err, string(out))
	}

	p.DatabaseURL = fmt.Sprintf("postgres://testbed@127.0.0.1:%d/testbed?sslmode=disable", p.Port)

	cmd = exec.CommandContext(ctx, pgBin,
		"-D", p.dataDir,
		"-p", fmt.Sprintf("%d", p.Port),
		"-c", "listen_addresses=127.0.0.1",
		"-c", "unix_socket_directories=",
		"-c", "logging_collector=off",
	)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("testbed/deps: start postgres: %w", err)
	}

	p.ContainerID = fmt.Sprintf("native:%d", cmd.Process.Pid)
	p.native = true

	if err := p.waitForReadyNative(ctx); err != nil {
		p.Stop()
		return fmt.Errorf("testbed/deps: postgres readiness: %w", err)
	}

	createdb, _ := exec.LookPath("createdb")
	if createdb == "" {
		createdb = filepath.Join(filepath.Dir(pgBin), "createdb")
	}
	cmd = exec.CommandContext(ctx, createdb,
		"-h", "127.0.0.1",
		"-p", fmt.Sprintf("%d", p.Port),
		"-U", "testbed",
		"testbed",
	)
	if out, err := cmd.CombinedOutput(); err != nil {
		p.Logger.Warn("createdb failed (may already exist)", "error", string(out))
	}

	p.Logger.Info("ephemeral postgres started (native)", "port", p.Port, "dataDir", p.dataDir)
	return nil
}

func (p *PostgresLifecycle) waitForReadyDocker(ctx context.Context) error {
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

func (p *PostgresLifecycle) waitForReadyNative(ctx context.Context) error {
	for i := 0; i < 30; i++ {
		cmd := exec.CommandContext(ctx, "pg_isready",
			"-h", "127.0.0.1",
			"-p", fmt.Sprintf("%d", p.Port),
			"-U", "testbed",
		)
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
	if p.native {
		p.stopNative()
		return
	}
	p.stopDocker()
}

func (p *PostgresLifecycle) stopDocker() {
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

func (p *PostgresLifecycle) stopNative() {
	if p.ContainerID == "" {
		return
	}
	var pid int
	fmt.Sscanf(p.ContainerID, "native:%d", &pid)
	if pid > 0 {
		proc, err := os.FindProcess(pid)
		if err == nil {
			proc.Signal(os.Interrupt)
			time.Sleep(500 * time.Millisecond)
			proc.Kill()
		}
	}
	if p.dataDir != "" {
		os.RemoveAll(p.dataDir)
	}
	p.Logger.Info("ephemeral postgres removed (native)", "dataDir", p.dataDir)
	p.ContainerID = ""
	p.dataDir = ""
}

func (p *PostgresLifecycle) SetEnv() {
	os.Setenv("EIGENINFERENCE_DATABASE_URL", p.DatabaseURL)
}
