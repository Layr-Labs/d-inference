package promptcontract

import (
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
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

func TestSupervisorRestartsChildAndBecomesReady(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	temp := realPromptTempDir(t, "prompt-supervisor-")
	script := filepath.Join(temp, "sidecar-helper")
	scriptBody := "#!/bin/sh\nexec \"" + executable + "\" -test.run=TestSupervisorHelperProcess -- \"$@\"\n"
	if err := os.WriteFile(script, []byte(scriptBody), 0o700); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(temp, "sidecar.sock")
	marker := filepath.Join(temp, "first-start")
	t.Setenv("PROMPT_SIDECAR_HELPER", "1")
	t.Setenv("PROMPT_SIDECAR_HELPER_MARKER", marker)

	supervisor := NewSupervisor(SupervisorConfig{
		Enabled:           true,
		BinaryPath:        script,
		SocketPath:        socket,
		ArtifactRoot:      temp,
		RequestTimeout:    50 * time.Millisecond,
		StartupTimeout:    time.Second,
		HealthInterval:    10 * time.Millisecond,
		ShutdownTimeout:   500 * time.Millisecond,
		RestartBackoffMin: 10 * time.Millisecond,
		RestartBackoffMax: 20 * time.Millisecond,
	})
	supervisor.Start(context.Background())
	defer supervisor.Close()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		status := supervisor.Status()
		if status.Ready && status.Restarts >= 1 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("supervisor never became ready after restart: %+v", supervisor.Status())
}

func TestSupervisorRestartsUnhealthyChild(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	temp := realPromptTempDir(t, "prompt-supervisor-health-")
	script := filepath.Join(temp, "sidecar-helper")
	scriptBody := "#!/bin/sh\nexec \"" + executable + "\" -test.run=TestSupervisorHelperProcess -- \"$@\"\n"
	if err := os.WriteFile(script, []byte(scriptBody), 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(temp, "first-start")
	if err := os.WriteFile(marker, []byte("started"), 0o600); err != nil {
		t.Fatal(err)
	}
	unhealthy := filepath.Join(temp, "unhealthy")
	t.Setenv("PROMPT_SIDECAR_HELPER", "1")
	t.Setenv("PROMPT_SIDECAR_HELPER_MARKER", marker)
	t.Setenv("PROMPT_SIDECAR_HELPER_UNHEALTHY", unhealthy)
	supervisor := NewSupervisor(SupervisorConfig{
		Enabled:           true,
		BinaryPath:        script,
		SocketPath:        filepath.Join(temp, "sidecar.sock"),
		ArtifactRoot:      temp,
		RequestTimeout:    30 * time.Millisecond,
		StartupTimeout:    time.Second,
		HealthInterval:    10 * time.Millisecond,
		ShutdownTimeout:   100 * time.Millisecond,
		RestartBackoffMin: 10 * time.Millisecond,
		RestartBackoffMax: 20 * time.Millisecond,
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

func TestSupervisorHelperProcess(t *testing.T) {
	if os.Getenv("PROMPT_SIDECAR_HELPER") != "1" {
		return
	}
	marker := os.Getenv("PROMPT_SIDECAR_HELPER_MARKER")
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
		if r.URL.Path != "/health" {
			http.NotFound(w, r)
			return
		}
		if unhealthy := os.Getenv("PROMPT_SIDECAR_HELPER_UNHEALTHY"); unhealthy != "" {
			if _, err := os.Stat(unhealthy); err == nil {
				<-r.Context().Done()
				return
			}
		}
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})}
	if err := server.Serve(listener); err != nil && err != http.ErrServerClosed {
		os.Exit(28)
	}
	os.Exit(0)
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
