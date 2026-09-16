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

	"github.com/jackc/pgx/v5"
)

type PostgresLifecycle struct {
	ContainerID string
	Port        int
	DatabaseURL string
	Logger      *slog.Logger

	dataDir string
	native  bool
	command *exec.Cmd
	done    chan struct{}
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

func (p *PostgresLifecycle) resolvePort() error {
	if p.Port != 0 {
		return nil
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("testbed/deps: find free port: %w", err)
	}
	defer listener.Close()
	p.Port = listener.Addr().(*net.TCPAddr).Port
	return nil
}

func (p *PostgresLifecycle) startDocker(ctx context.Context) error {
	if err := p.resolvePort(); err != nil {
		return err
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

	if err := p.resolvePort(); err != nil {
		return err
	}

	p.dataDir, err = os.MkdirTemp("", "testbed-pg-")
	if err != nil {
		return fmt.Errorf("testbed/deps: create data dir: %w", err)
	}
	p.native = true
	started := false
	defer func() {
		if !started {
			p.stopNative()
		}
	}()

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
	p.command = cmd
	p.done = make(chan struct{})
	go func(command *exec.Cmd, done chan struct{}) {
		defer close(done)
		_ = command.Wait()
	}(cmd, p.done)

	if err := p.waitForReadyNative(ctx); err != nil {
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

	started = true
	p.Logger.Info("ephemeral postgres started (native)", "port", p.Port, "dataDir", p.dataDir)
	return nil
}

func (p *PostgresLifecycle) waitForReadyDocker(ctx context.Context) error {
	return waitForPostgres(ctx, func() bool {
		cmd := exec.CommandContext(ctx, "docker", "exec", p.ContainerID,
			"pg_isready", "-U", "testbed", "-d", "testbed")
		return cmd.Run() == nil && p.hostDatabaseReady(ctx)
	})
}

func (p *PostgresLifecycle) hostDatabaseReady(ctx context.Context) bool {
	probeCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	connection, err := pgx.Connect(probeCtx, p.DatabaseURL)
	if err != nil {
		return false
	}
	defer connection.Close(probeCtx)
	return connection.Ping(probeCtx) == nil
}

func (p *PostgresLifecycle) waitForReadyNative(ctx context.Context) error {
	return waitForPostgres(ctx, func() bool {
		cmd := exec.CommandContext(ctx, "pg_isready",
			"-h", "127.0.0.1", "-p", fmt.Sprintf("%d", p.Port), "-U", "testbed")
		return cmd.Run() == nil
	})
}

func waitForPostgres(ctx context.Context, ready func() bool) error {
	for i := 0; i < 30; i++ {
		if ready() {
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
	if p.command != nil {
		// Retain the actual child handle: a display PID must never authorize a kill.
		_ = p.command.Process.Signal(os.Interrupt)
		select {
		case <-p.done:
		case <-time.After(500 * time.Millisecond):
			_ = p.command.Process.Kill()
			select {
			case <-p.done:
			case <-time.After(5 * time.Second):
				p.Logger.Error("postgres termination unconfirmed; retaining owned data", "dataDir", p.dataDir)
				return
			}
		}
		p.command, p.done = nil, nil
	}
	if p.dataDir != "" {
		if err := os.RemoveAll(p.dataDir); err != nil {
			p.Logger.Error("failed to remove postgres data", "dataDir", p.dataDir, "error", err)
			return
		}
		p.Logger.Info("ephemeral postgres removed (native)", "dataDir", p.dataDir)
	}
	p.ContainerID, p.dataDir = "", ""
}

func (p *PostgresLifecycle) SetEnv() {
	os.Setenv("EIGENINFERENCE_DATABASE_URL", p.DatabaseURL)
}
