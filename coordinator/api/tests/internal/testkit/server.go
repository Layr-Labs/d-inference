// Package testkit owns composed API fixtures used by external contract tests.
package testkit

import (
	"log/slog"
	"os"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type Fixture struct {
	Server   *api.Server
	Registry *registry.Registry
	Store    *memory.MemoryStore
}

func New(t testing.TB, cfg api.ServerConfig) *Fixture {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := api.NewServer(reg, st, cfg, logger)
	t.Cleanup(srv.Close)
	return &Fixture{Server: srv, Registry: reg, Store: st}
}
