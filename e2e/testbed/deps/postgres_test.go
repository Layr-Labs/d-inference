package deps

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// The PATH commands below only re-execute this test binary. No database,
// Docker daemon, network connection or production executable is started.
func TestPostgresHelperProcess(t *testing.T) {
	if os.Getenv("TESTBED_PG_HELPER") != "1" {
		return
	}
	var operation string
	for i, arg := range os.Args {
		if arg == "--" && i+1 < len(os.Args) {
			operation = os.Args[i+1]
			break
		}
	}
	switch operation {
	case "initdb":
		if os.Getenv("TESTBED_PG_INIT_FAIL") == "1" {
			os.Exit(1)
		}
	case "postgres":
		stop := make(chan os.Signal, 1)
		ignoreInterrupt := os.Getenv("TESTBED_PG_IGNORE_INTERRUPT") == "1"
		if ignoreInterrupt {
			signal.Ignore(os.Interrupt)
		} else {
			signal.Notify(stop, os.Interrupt)
		}
		if err := os.WriteFile(os.Getenv("TESTBED_PG_READY"), []byte("ready"), 0o600); err != nil {
			os.Exit(2)
		}
		if ignoreInterrupt {
			for {
				time.Sleep(time.Hour)
			}
		}
		<-stop
	case "pg_isready":
		if os.Getenv("TESTBED_PG_READINESS_FAIL") == "1" {
			os.Exit(1)
		}
		if _, err := os.Stat(os.Getenv("TESTBED_PG_READY")); err != nil {
			os.Exit(1)
		}
	case "createdb":
	default:
		os.Exit(3)
	}
	os.Exit(0)
}

func postgresFixture(t *testing.T) *PostgresLifecycle {
	t.Helper()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	bin := t.TempDir()
	for _, command := range []string{"postgres", "initdb", "pg_isready", "createdb"} {
		body := "#!/bin/sh\nexec \"$TESTBED_PG_BINARY\" -test.run=^TestPostgresHelperProcess$ -- " + command + " \"$@\"\n"
		if err := os.WriteFile(filepath.Join(bin, command), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", bin)
	t.Setenv("TMPDIR", t.TempDir())
	t.Setenv("TESTBED_PG_BINARY", binary)
	t.Setenv("TESTBED_PG_HELPER", "1")
	// Do not let the race runtime's exit delay impersonate a stuck database.
	t.Setenv("GORACE", "atexit_sleep_ms=0")
	t.Setenv("TESTBED_PG_READY", filepath.Join(t.TempDir(), "ready"))
	return NewPostgresLifecycle(slog.New(slog.NewTextHandler(io.Discard, nil)), 55432)
}

func TestNativePostgresRetainsAndReapsOnlyItsChild(t *testing.T) {
	p := postgresFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	defer p.Stop()
	if err := p.Start(ctx); err != nil {
		t.Fatal(err)
	}
	command, done, dataDir := p.command, p.done, p.dataDir
	if command == nil {
		t.Fatal("started database has no owned command")
	}
	// This public display field must not become the source of signal authority.
	p.ContainerID = "invalid-display-only-identity"
	p.Stop()
	select {
	case <-done:
	default:
		t.Fatal("Stop returned without reaping its native child")
	}
	if command.ProcessState == nil || !command.ProcessState.Exited() {
		t.Fatal("native command did not exit gracefully and reap")
	}
	if _, err := os.Stat(dataDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("owned data remained after confirmed exit: %v", err)
	}
	if p.command != nil || p.ContainerID != "" || p.dataDir != "" {
		t.Fatal("stopped lifecycle retained live ownership fields")
	}
	p.Stop() // Idempotent after confirmed cleanup.
}

func TestNativePostgresEscalatesForAnUnresponsiveOwnedChild(t *testing.T) {
	p := postgresFixture(t)
	t.Setenv("TESTBED_PG_IGNORE_INTERRUPT", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	defer p.Stop()
	if err := p.Start(ctx); err != nil {
		t.Fatal(err)
	}
	command := p.command
	p.Stop()
	if command.ProcessState == nil {
		t.Fatal("child was not reaped")
	}
	status := command.ProcessState.Sys().(syscall.WaitStatus)
	if !status.Signaled() || status.Signal() != syscall.SIGKILL {
		t.Fatalf("unresponsive child was not killed: %v", status)
	}
}

func TestNativePostgresReadinessFailureCleansStartedChild(t *testing.T) {
	p := postgresFixture(t)
	t.Setenv("TESTBED_PG_READINESS_FAIL", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	defer p.Stop()
	err := p.Start(ctx)
	if !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "postgres readiness") {
		t.Fatalf("expected post-launch readiness failure, got %v", err)
	}
	if p.command != nil || p.dataDir != "" || p.ContainerID != "" {
		t.Fatal("failed readiness retained owned command or data")
	}
}

func TestNativePostgresInitializationFailureRemovesOwnedDirectory(t *testing.T) {
	p := postgresFixture(t)
	t.Setenv("TESTBED_PG_INIT_FAIL", "1")
	if err := p.Start(context.Background()); err == nil {
		t.Fatal("failed initdb unexpectedly started")
	}
	if p.dataDir != "" || p.command != nil {
		t.Fatal("failed initialization retained owned state")
	}
	entries, err := os.ReadDir(os.TempDir())
	if err != nil || len(entries) != 0 {
		t.Fatalf("failed initialization leaked temporary data: %v %v", entries, err)
	}
}

func TestPostgresReadinessCancellationAndSuccess(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	probes := 0
	if err := waitForPostgres(ctx, func() bool { probes++; return false }); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled readiness returned %v", err)
	}
	if probes != 1 {
		t.Fatalf("canceled readiness probed %d times", probes)
	}
	if err := waitForPostgres(context.Background(), func() bool { return true }); err != nil {
		t.Fatal(err)
	}
}

func TestNativePostgresStopWithoutStartedCommandNeverSignalsPID(t *testing.T) {
	// A malformed/external display identifier is not an owned native child.
	p := NewPostgresLifecycle(slog.New(slog.NewTextHandler(io.Discard, nil)), 0)
	p.native, p.ContainerID = true, "native:invalid"
	p.Stop()
	if p.ContainerID != "" {
		t.Fatal("empty native lifecycle was not reset")
	}
}
