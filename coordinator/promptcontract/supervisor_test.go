package promptcontract

import (
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestPrepareSocketDirectoryRejectsSymlinkedAncestor(t *testing.T) {
	base, err := filepath.EvalSymlinks(os.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root, err := os.MkdirTemp(base, "prompt-socket-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)

	realParent := filepath.Join(root, "real")
	if err := os.Mkdir(realParent, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(realParent, link); err != nil {
		t.Fatal(err)
	}
	if err := prepareSocketDirectory(filepath.Join(link, "nested", "prompt.sock")); err == nil {
		t.Fatal("symlinked socket ancestor was accepted")
	}
}

func TestPrepareSocketDirectoryCreatesPrivateDirectory(t *testing.T) {
	base, err := filepath.EvalSymlinks(os.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root, err := os.MkdirTemp(base, "prompt-socket-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)

	directory := filepath.Join(root, "nested", "run")
	if err := prepareSocketDirectory(filepath.Join(directory, "prompt.sock")); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(directory)
	if err != nil {
		t.Fatal(err)
	}
	if !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Fatalf("socket directory mode = %s, want drwx------", info.Mode())
	}
}

func realPromptTempDir(t *testing.T, pattern string) string {
	t.Helper()
	base, err := filepath.EvalSymlinks("/tmp")
	if err != nil {
		t.Fatal(err)
	}
	directory, err := os.MkdirTemp(base, pattern)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return directory
}

func promptSidecarHelperScript(t *testing.T, directory string) string {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(directory, "sidecar-helper")
	scriptBody := "#!/bin/sh\nexec \"" + executable + "\" -test.run=TestSupervisorHelperProcess -- \"$@\"\n"
	if err := os.WriteFile(script, []byte(scriptBody), 0o700); err != nil {
		t.Fatal(err)
	}
	return script
}

func TestSupervisorRestartsChildAndBecomesReady(t *testing.T) {
	temp := realPromptTempDir(t, "prompt-supervisor-")
	script := promptSidecarHelperScript(t, temp)
	socket := filepath.Join(temp, "sidecar.sock")
	marker := filepath.Join(temp, "first-start")
	t.Setenv("PROMPT_SIDECAR_HELPER", "1")
	t.Setenv("PROMPT_SIDECAR_HELPER_MARKER", marker)

	supervisor := NewSupervisor(SupervisorConfig{
		Enabled:                true,
		BinaryPath:             script,
		SocketPath:             socket,
		ArtifactRoot:           temp,
		RequestTimeout:         50 * time.Millisecond,
		HealthTimeout:          50 * time.Millisecond,
		StartupTimeout:         time.Second,
		HealthInterval:         10 * time.Millisecond,
		HealthFailureThreshold: 3,
		ShutdownTimeout:        500 * time.Millisecond,
		RestartBackoffMin:      10 * time.Millisecond,
		RestartBackoffMax:      20 * time.Millisecond,
	})
	supervisor.Start(context.Background())
	defer supervisor.Close()
	waitForSupervisor(t, supervisor, func(status SupervisorStatus) bool {
		return status.Ready && status.Restarts >= 1
	})
}

func TestSupervisorRestartsUnhealthyChild(t *testing.T) {
	temp := realPromptTempDir(t, "prompt-supervisor-health-")
	script := promptSidecarHelperScript(t, temp)
	marker := filepath.Join(temp, "first-start")
	if err := os.WriteFile(marker, []byte("started"), 0o600); err != nil {
		t.Fatal(err)
	}
	unhealthy := filepath.Join(temp, "unhealthy")
	t.Setenv("PROMPT_SIDECAR_HELPER", "1")
	t.Setenv("PROMPT_SIDECAR_HELPER_MARKER", marker)
	t.Setenv("PROMPT_SIDECAR_HELPER_UNHEALTHY", unhealthy)
	supervisor := NewSupervisor(SupervisorConfig{
		Enabled:                true,
		BinaryPath:             script,
		SocketPath:             filepath.Join(temp, "sidecar.sock"),
		ArtifactRoot:           temp,
		RequestTimeout:         30 * time.Millisecond,
		HealthTimeout:          30 * time.Millisecond,
		StartupTimeout:         time.Second,
		HealthInterval:         10 * time.Millisecond,
		HealthFailureThreshold: 3,
		ShutdownTimeout:        100 * time.Millisecond,
		RestartBackoffMin:      10 * time.Millisecond,
		RestartBackoffMax:      20 * time.Millisecond,
	})
	supervisor.Start(context.Background())
	defer supervisor.Close()
	waitForSupervisor(t, supervisor, func(status SupervisorStatus) bool { return status.Ready })
	if err := os.WriteFile(unhealthy, []byte("hang"), 0o600); err != nil {
		t.Fatal(err)
	}
	waitForSupervisor(t, supervisor, func(status SupervisorStatus) bool {
		return status.Restarts >= 1 && !status.Ready
	})
	if err := os.Remove(unhealthy); err != nil {
		t.Fatal(err)
	}
	waitForSupervisor(t, supervisor, func(status SupervisorStatus) bool {
		return status.Restarts >= 1 && status.Ready
	})
}

func TestRSSBytesFromStatm(t *testing.T) {
	if got := rssBytesFromStatm([]byte("100 25 0 0\n"), 4096); got != 25*4096 {
		t.Fatalf("rss=%d, want %d", got, 25*4096)
	}
	for _, input := range [][]byte{nil, []byte("one"), []byte("1 invalid")} {
		if got := rssBytesFromStatm(input, 4096); got != 0 {
			t.Fatalf("malformed statm %q produced rss=%d", input, got)
		}
	}
}

func TestSupervisorTransientHealthFailureDoesNotRestart(t *testing.T) {
	supervisor, unhealthy := startSupervisorHelper(t)
	waitForSupervisor(t, supervisor, func(status SupervisorStatus) bool { return status.Ready })
	before := supervisor.Status().Restarts
	if err := os.WriteFile(unhealthy, []byte("transient"), 0o600); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && supervisor.Client().Stats().HealthTimeouts == 0 {
		time.Sleep(5 * time.Millisecond)
	}
	if supervisor.Client().Stats().HealthTimeouts == 0 {
		t.Fatal("transient health timeout was not observed")
	}
	waitForSupervisor(t, supervisor, func(status SupervisorStatus) bool {
		return status.Ready
	})
	if after := supervisor.Status().Restarts; after != before {
		t.Fatalf("one transient health failure restarted child: before=%d after=%d", before, after)
	}
}

func TestSupervisorReadinessDegradationDoesNotRestart(t *testing.T) {
	supervisor, _ := startSupervisorHelper(t)
	waitForSupervisor(t, supervisor, func(status SupervisorStatus) bool { return status.Ready })
	before := supervisor.Status().Restarts
	notReady := os.Getenv("PROMPT_SIDECAR_HELPER_NOT_READY")
	if err := os.WriteFile(notReady, []byte("degraded"), 0o600); err != nil {
		t.Fatal(err)
	}
	waitForSupervisor(t, supervisor, func(status SupervisorStatus) bool { return !status.Ready })
	time.Sleep(100 * time.Millisecond)
	if after := supervisor.Status().Restarts; after != before {
		t.Fatalf("readiness degradation restarted child: before=%d after=%d", before, after)
	}
	if err := os.Remove(notReady); err != nil {
		t.Fatal(err)
	}
	waitForSupervisor(t, supervisor, func(status SupervisorStatus) bool { return status.Ready })
}

func TestSupervisorRestartCircuitAndBoundedStderr(t *testing.T) {
	temp := realPromptTempDir(t, "prompt-supervisor-circuit-")
	script := promptSidecarHelperScript(t, temp)
	t.Setenv("PROMPT_SIDECAR_HELPER", "1")
	t.Setenv("PROMPT_SIDECAR_HELPER_ALWAYS_EXIT", "1")
	t.Setenv("PROMPT_SIDECAR_HELPER_STDERR", strings.Repeat("diagnostic-", 512))
	supervisor := NewSupervisor(SupervisorConfig{
		Enabled: true, BinaryPath: script, SocketPath: filepath.Join(temp, "sidecar.sock"),
		ArtifactRoot: temp, HealthTimeout: 20 * time.Millisecond, StartupTimeout: time.Second,
		HealthInterval: 10 * time.Millisecond, ShutdownTimeout: 50 * time.Millisecond,
		RestartBackoffMin: time.Millisecond, RestartBackoffMax: 2 * time.Millisecond,
		RestartWindow: time.Second, RestartMaxInWindow: 2, RestartCooldown: 200 * time.Millisecond,
		StderrMaxBytes: 128,
	})
	supervisor.Start(context.Background())
	defer supervisor.Close()
	waitForSupervisor(t, supervisor, func(status SupervisorStatus) bool {
		return status.Restarts >= 2 && !status.RestartSuppressedUntil.IsZero()
	})
	status := supervisor.Status()
	if status.RestartReason != "restart_cooldown" || status.LastExitReason == "" ||
		len(status.StderrTail) == 0 || len(status.StderrTail) > 128 {
		t.Fatalf("bounded restart diagnostics=%+v", status)
	}
}

func TestSupervisorHelperProcess(t *testing.T) {
	if os.Getenv("PROMPT_SIDECAR_HELPER") != "1" {
		return
	}
	marker := os.Getenv("PROMPT_SIDECAR_HELPER_MARKER")
	if stderr := os.Getenv("PROMPT_SIDECAR_HELPER_STDERR"); stderr != "" {
		_, _ = os.Stderr.WriteString(stderr)
	}
	if os.Getenv("PROMPT_SIDECAR_HELPER_ALWAYS_EXIT") == "1" {
		os.Exit(29)
	}
	if _, err := os.Stat(marker); os.IsNotExist(err) {
		if writeErr := os.WriteFile(marker, []byte("started"), 0o600); writeErr != nil {
			os.Exit(24)
		}
		os.Exit(23)
	}
	socket := argumentValue(os.Args, "--socket")
	if socket == "" {
		os.Exit(25)
	}
	_ = os.Remove(socket)
	listener, err := net.Listen("unix", socket)
	if err != nil {
		os.Exit(26)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		os.Exit(27)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/ready" {
			if notReady := os.Getenv("PROMPT_SIDECAR_HELPER_NOT_READY"); notReady != "" {
				if _, err := os.Stat(notReady); err == nil {
					w.WriteHeader(http.StatusServiceUnavailable)
					_, _ = w.Write([]byte(`{"status":"not_ready","ready":false}`))
					return
				}
			}
			_, _ = w.Write([]byte(`{"status":"ok","ready":true}`))
			return
		}
		if r.URL.Path != "/health" {
			http.NotFound(w, r)
			return
		}
		if unhealthy := os.Getenv("PROMPT_SIDECAR_HELPER_UNHEALTHY"); unhealthy != "" {
			if data, err := os.ReadFile(unhealthy); err == nil {
				if string(data) == "transient" {
					_ = os.Remove(unhealthy)
				}
				<-r.Context().Done()
				return
			}
		}
		_, _ = w.Write([]byte(`{"status":"ok","ready":true}`))
	})}
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		os.Exit(28)
	}
	os.Exit(0)
}

func startSupervisorHelper(t *testing.T) (*Supervisor, string) {
	t.Helper()
	temp := realPromptTempDir(t, "prompt-supervisor-transient-")
	script := promptSidecarHelperScript(t, temp)
	marker := filepath.Join(temp, "first-start")
	if err := os.WriteFile(marker, []byte("started"), 0o600); err != nil {
		t.Fatal(err)
	}
	unhealthy := filepath.Join(temp, "unhealthy")
	notReady := filepath.Join(temp, "not-ready")
	t.Setenv("PROMPT_SIDECAR_HELPER", "1")
	t.Setenv("PROMPT_SIDECAR_HELPER_MARKER", marker)
	t.Setenv("PROMPT_SIDECAR_HELPER_UNHEALTHY", unhealthy)
	t.Setenv("PROMPT_SIDECAR_HELPER_NOT_READY", notReady)
	supervisor := NewSupervisor(SupervisorConfig{
		Enabled: true, BinaryPath: script, SocketPath: filepath.Join(temp, "sidecar.sock"),
		ArtifactRoot: temp, RequestTimeout: 100 * time.Millisecond, HealthTimeout: 30 * time.Millisecond,
		StartupTimeout: time.Second, HealthInterval: 20 * time.Millisecond,
		HealthFailureThreshold: 3, ShutdownTimeout: 100 * time.Millisecond,
		RestartBackoffMin: 10 * time.Millisecond, RestartBackoffMax: 20 * time.Millisecond,
	})
	supervisor.Start(context.Background())
	t.Cleanup(supervisor.Close)
	return supervisor, unhealthy
}

func waitForSupervisor(t *testing.T, supervisor *Supervisor, predicate func(SupervisorStatus) bool) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if predicate(supervisor.Status()) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("supervisor state did not converge: %+v", supervisor.Status())
}

func argumentValue(arguments []string, name string) string {
	for index := 0; index+1 < len(arguments); index++ {
		if arguments[index] == name {
			return arguments[index+1]
		}
	}
	return ""
}
