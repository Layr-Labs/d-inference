package api

import (
	"io"
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// quietLogger returns a logger that discards everything — for tests that
// exercise noisy failure paths.
func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func testServer(t *testing.T) (*Server, *memory.MemoryStore) {
	return testServerWithConfig(t, ServerConfig{})
}

func testServerWithConfig(t *testing.T, cfg ServerConfig) (*Server, *memory.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, cfg, logger)
	t.Cleanup(srv.Close)
	return srv, st
}
