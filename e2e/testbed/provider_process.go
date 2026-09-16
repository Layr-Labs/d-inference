package testbed

import (
	"context"
	"log/slog"
	"os"
)

type Provider struct {
	Target     *ProviderTarget
	AccountID  string
	suiteNonce string
	owned      *ownedProvider

	BinaryPath    string
	Logger        *slog.Logger
	ProviderIndex int
	AuthDir       string
	// StateDir is a per-instance temp dir that holds the provider's
	// persisted state files (daemon-state.json, loaded-models.json).
	// Without it every testbed provider shares the real
	// ~/.darkbloom/loaded-models.json, so provider N+1 startup-preloads
	// (and self-tests) whatever provider N was serving — cross-test
	// state leakage that does not represent a fresh provider boot.
	StateDir string

	cmd    *os.Process
	cancel context.CancelFunc
	done   chan struct{}

	// generatedConfig holds the provider TOML this instance wrote into
	// StateDir. Every provider gets one so auto-update and auto-restart stay off;
	// KV-backend / concurrency keys remain optional within it.
	generatedConfig string
	// canonicalConfigExisted records whether ~/.config/darkbloom/provider.toml
	// was present at launch. The provider copies a --config file there when it
	// is missing; Stop undoes that copy so a testbed TOML never becomes the
	// machine's default config.
	canonicalConfigExisted bool
}
