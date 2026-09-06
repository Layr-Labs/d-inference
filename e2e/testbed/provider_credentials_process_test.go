package testbed

import (
	"context"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

// This stub exercises the real Provider.Start command/env path without running
// Swift, loading a model, or contacting any coordinator. It records only the
// selected fixture credentials and mimics the credential store's lock sidecar.
func credentialProbe(t *testing.T) (binary, output string) {
	t.Helper()
	dir := t.TempDir()
	binary = filepath.Join(dir, "credential-probe")
	output = filepath.Join(dir, "observed-credentials")
	require.NoError(t, os.WriteFile(binary, []byte(`#!/bin/sh
set -eu
{
  printf '%s\n' "$DARKBLOOM_AUTH_TOKEN_PATH" "$DARKBLOOM_PROVIDER_ACCOUNT_PATH" "$DARKBLOOM_PROVIDER_ISSUER_PATH"
  for credential_path in "$DARKBLOOM_AUTH_TOKEN_PATH" "$DARKBLOOM_PROVIDER_ACCOUNT_PATH" "$DARKBLOOM_PROVIDER_ISSUER_PATH"; do
    if [ -f "$credential_path" ]; then cat "$credential_path"; else printf '<missing>\n'; fi
  done
  printf '%s\n' "$4"
} > "$DARKBLOOM_TESTBED_CREDENTIAL_PROBE"
: > "${DARKBLOOM_AUTH_TOKEN_PATH%/*}/.provider-credential.lock"
`), 0700))
	// BuildProvider's prebuilt-binary branch checks for this file; the probe
	// never opens it. This pins suite launch to the no-Swift-build path.
	require.NoError(t, os.WriteFile(filepath.Join(dir, "mlx.metallib"), nil, 0600))
	t.Setenv("DARKBLOOM_PROVIDER_BINARY", binary)
	t.Setenv("DARKBLOOM_TESTBED_CREDENTIAL_PROBE", output)
	t.Setenv("DARKBLOOM_TESTBED_KV_BACKEND", "")
	t.Setenv("DARKBLOOM_TESTBED_MAX_CONCURRENT", "")
	return binary, output
}

func waitCredentialProbe(t *testing.T, p *Provider, output string) []string {
	t.Helper()
	select {
	case <-p.done:
	case <-time.After(5 * time.Second):
		t.Fatal("credential probe did not exit")
	}
	data, err := os.ReadFile(output)
	require.NoError(t, err)
	lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
	require.Len(t, lines, 7)
	require.FileExists(t, filepath.Join(filepath.Dir(lines[0]), ".provider-credential.lock"))
	return lines
}

func credentialTreeSnapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	files := make(map[string]string)
	require.NoError(t, filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return err
		}
		data, err := os.ReadFile(path)
		files[path] = string(data)
		return err
	}))
	return files
}

// Poison both override paths and simulated canonical/legacy login locations.
// All sentinels live under TempDir, so a regression cannot expose real secrets.
func protectOperatorCredentialFixtures(t *testing.T) {
	t.Helper()
	root := t.TempDir()
	home := filepath.Join(root, "home")
	t.Setenv("HOME", home)
	for _, dir := range []string{filepath.Join(home, ".darkbloom"), filepath.Join(root, "overrides")} {
		paths := providerCredentialPathsIn(dir)
		require.NoError(t, os.MkdirAll(dir, 0700))
		for path, value := range map[string]string{
			paths.token: "operator-token\n", paths.account: "operator-account\n", paths.issuer: "https://operator.example\n",
		} {
			require.NoError(t, os.WriteFile(path, []byte(value), 0600))
		}
	}
	for _, path := range []string{
		filepath.Join(home, ".config", "eigeninference", "auth_token"),
		filepath.Join(home, "Library", "Application Support", "eigeninference", "auth_token"),
	} {
		require.NoError(t, os.MkdirAll(filepath.Dir(path), 0700))
		require.NoError(t, os.WriteFile(path, []byte("legacy-operator-token\n"), 0600))
	}
	paths := providerCredentialPathsIn(filepath.Join(root, "overrides"))
	t.Setenv("DARKBLOOM_AUTH_TOKEN_PATH", paths.token)
	t.Setenv("DARKBLOOM_PROVIDER_ACCOUNT_PATH", paths.account)
	t.Setenv("DARKBLOOM_PROVIDER_ISSUER_PATH", paths.issuer)
	before := credentialTreeSnapshot(t, root)
	t.Cleanup(func() {
		require.Equal(t, before, credentialTreeSnapshot(t, root), "operator login files must remain untouched")
	})
}

func TestSuiteProviderLaunchPassesCompleteCredentialAndCleansUp(t *testing.T) {
	protectOperatorCredentialFixtures(t)
	_, output := credentialProbe(t)
	s := credentialTestSuite(t)
	s.Config.ModelSpecs = []ModelSpec{{ModelID: "fixture-model", NumProviders: 1}}
	require.NoError(t, s.startProviders())
	require.Len(t, s.Providers, 1)
	p := s.Providers[0]
	t.Cleanup(p.Stop)
	observed := waitCredentialProbe(t, p, output)
	for _, path := range observed[:3] {
		require.Equal(t, p.AuthDir, filepath.Dir(path))
		requireCredentialPermissions(t, path, 0600)
	}
	record, err := s.PgStore.GetProviderToken(observed[3])
	require.NoError(t, err)
	require.Equal(t, "testbed-provider-0", record.AccountID)
	require.Equal(t, record.AccountID, observed[4])
	require.Equal(t, s.Coordinator.BaseURL(), observed[5])
	require.Equal(t, strings.Replace(s.Coordinator.BaseURL(), "http://", "ws://", 1)+"/ws/provider", observed[6])
	issuer, err := canonicalProviderIssuer(observed[6])
	require.NoError(t, err)
	require.Equal(t, observed[5], issuer, "launched endpoint must match credential issuer")

	p.Stop()
	require.NoDirExists(t, p.AuthDir)
	require.NoDirExists(t, p.StateDir)
	for _, path := range observed[:3] {
		require.NoFileExists(t, path)
	}
}

func TestProviderLaunchKeepsMissingCredentialsIsolated(t *testing.T) {
	for _, tokenOnly := range []bool{false, true} {
		name := "default_empty_auth_token"
		if tokenOnly {
			name = "explicit_token_without_metadata"
		}
		t.Run(name, func(t *testing.T) {
			protectOperatorCredentialFixtures(t)
			binary, output := credentialProbe(t)
			cfg := DefaultProviderConfig()
			if tokenOnly {
				cfg.AuthTokenPath = filepath.Join(t.TempDir(), "partial-token")
				require.NoError(t, os.WriteFile(cfg.AuthTokenPath, []byte("incomplete-fixture-token\n"), 0600))
			}
			p := &Provider{BinaryPath: binary, Logger: slog.New(slog.NewTextHandler(io.Discard, nil))}
			t.Cleanup(p.Stop)
			require.NoError(t, p.Start(context.Background(), "http://127.0.0.1:54321", cfg))
			observed := waitCredentialProbe(t, p, output)
			firstMissing := 0
			if tokenOnly {
				require.Equal(t, cfg.AuthTokenPath, observed[0])
				require.Equal(t, "incomplete-fixture-token", observed[3])
				firstMissing = 1
			}
			for i := firstMissing; i < 3; i++ {
				path := observed[i]
				require.True(t, strings.HasPrefix(path, p.StateDir+string(os.PathSeparator)), path)
				requireCredentialPermissions(t, filepath.Dir(path), 0700)
				require.NoFileExists(t, path)
				require.Equal(t, "<missing>", observed[i+3])
			}
			p.Stop()
			require.NoDirExists(t, p.StateDir)
			if tokenOnly {
				require.Equal(t, "incomplete-fixture-token", credentialFileValue(t, cfg.AuthTokenPath), "caller owns explicit fixtures")
			}
		})
	}
}

func TestProviderFailedLaunchCleansUpCredentialAndStateDirectories(t *testing.T) {
	for _, authenticated := range []bool{false, true} {
		name := "unauthenticated"
		if authenticated {
			name = "authenticated"
		}
		t.Run(name, func(t *testing.T) {
			protectOperatorCredentialFixtures(t)
			p := &Provider{
				BinaryPath: filepath.Join(t.TempDir(), "missing-executable"),
				Logger:     slog.New(slog.NewTextHandler(io.Discard, nil)),
			}
			t.Cleanup(p.Stop)
			cfg := DefaultProviderConfig()
			if authenticated {
				s := &Suite{Coordinator: &Coordinator{baseURL: "http://127.0.0.1:54321"}, PgStore: NewMemoryStore()}
				dir, paths, err := s.prepareProviderAuth(0)
				require.NoError(t, err)
				p.AuthDir = dir
				cfg.AuthTokenPath, cfg.ProviderAccountPath, cfg.ProviderIssuerPath = paths.token, paths.account, paths.issuer
			}
			err := p.Start(context.Background(), "http://127.0.0.1:54321", cfg)
			require.ErrorContains(t, err, "start provider:")
			require.NotEmpty(t, p.StateDir)
			require.NoDirExists(t, p.StateDir)
			if authenticated {
				require.NoDirExists(t, p.AuthDir)
			}
			require.Nil(t, p.cancel)
			require.False(t, p.Running())
		})
	}
}
