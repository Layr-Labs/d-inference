package testbed

import (
	"context"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// Block only the child's output, so a completed provider must also finish the
// exec.Cmd copy goroutine before Running reports false or cleanup can proceed.
type blockedProviderOutput struct {
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (h *blockedProviderOutput) Enabled(context.Context, slog.Level) bool { return true }
func (h *blockedProviderOutput) WithAttrs([]slog.Attr) slog.Handler       { return h }
func (h *blockedProviderOutput) WithGroup(string) slog.Handler            { return h }
func (h *blockedProviderOutput) Handle(_ context.Context, record slog.Record) error {
	if record.Message == "provider:stdout" {
		h.once.Do(func() { close(h.entered) })
		<-h.release
	}
	return nil
}

func TestLocalProviderWaitIncludesOutputDrain(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	binary := filepath.Join(t.TempDir(), "fixture-provider")
	if err := os.WriteFile(binary, []byte("#!/bin/sh\nprintf 'fixture output\\n'\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	handler := &blockedProviderOutput{entered: make(chan struct{}), release: make(chan struct{})}
	provider := &Provider{BinaryPath: binary, Logger: slog.New(handler), StateDir: t.TempDir()}
	var release sync.Once
	defer func() {
		release.Do(func() { close(handler.release) })
		provider.Stop()
	}()
	if err := provider.Start(context.Background(), "http://127.0.0.1:1", ProviderConfig{}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-handler.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("fixture output never reached the logger")
	}
	select {
	case <-provider.done:
		t.Fatal("provider completion skipped command output drain")
	case <-time.After(100 * time.Millisecond):
	}
	release.Do(func() { close(handler.release) })
	select {
	case <-provider.done:
	case <-time.After(5 * time.Second):
		t.Fatal("provider did not finish after output drained")
	}
	if provider.Running() {
		t.Fatal("completed provider still reported running")
	}
}
