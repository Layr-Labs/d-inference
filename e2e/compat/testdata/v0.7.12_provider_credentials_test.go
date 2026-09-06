package testbed

// Copied into the pinned released testbed by the adjacent verifier. Keeping
// this under testdata avoids compiling it against the candidate's newer API.
import (
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func reverseCompatRead(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	return strings.TrimSpace(string(data))
}

func reverseCompatMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	require.NoError(t, err)
	require.Equal(t, want, info.Mode().Perm(), path)
}

func TestReverseCompatProviderCredentials(t *testing.T) {
	for _, mode := range []string{"complete", "token_only", "absent"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			fakeHome := filepath.Join(root, "home")
			t.Setenv("HOME", fakeHome)
			keys := []string{"DARKBLOOM_AUTH_TOKEN_PATH", "DARKBLOOM_PROVIDER_ACCOUNT_PATH", "DARKBLOOM_PROVIDER_ISSUER_PATH"}
			names := []string{"auth_token", "provider_account", "provider_issuer"}
			// Poison overrides, canonical paths, and legacy migration paths with
			// synthetic operator files. Never read the runner's actual login.
			sentinels := map[string]string{}
			for _, dir := range []string{filepath.Join(root, "operator"), filepath.Join(fakeHome, ".darkbloom")} {
				require.NoError(t, os.MkdirAll(dir, 0700))
				for i, name := range names {
					path := filepath.Join(dir, name)
					sentinels[path] = "operator-" + name
					require.NoError(t, os.WriteFile(path, []byte(sentinels[path]+"\n"), 0600))
					if dir == filepath.Join(root, "operator") {
						t.Setenv(keys[i], path)
					}
				}
			}
			for _, path := range []string{
				filepath.Join(fakeHome, ".config", "eigeninference", "auth_token"),
				filepath.Join(fakeHome, "Library", "Application Support", "eigeninference", "auth_token"),
			} {
				sentinels[path] = "legacy-operator-token"
				require.NoError(t, os.MkdirAll(filepath.Dir(path), 0700))
				require.NoError(t, os.WriteFile(path, []byte(sentinels[path]+"\n"), 0600))
			}
			t.Cleanup(func() {
				for path, want := range sentinels {
					require.Equal(t, want, reverseCompatRead(t, path), "operator fixture changed: %s", path)
				}
			})

			binary, output := filepath.Join(root, "credential-probe"), filepath.Join(root, "observed")
			require.NoError(t, os.WriteFile(binary, []byte(`#!/bin/sh
set -eu
{
  printf '%s\n' "$DARKBLOOM_AUTH_TOKEN_PATH" "$DARKBLOOM_PROVIDER_ACCOUNT_PATH" "$DARKBLOOM_PROVIDER_ISSUER_PATH"
  for path in "$DARKBLOOM_AUTH_TOKEN_PATH" "$DARKBLOOM_PROVIDER_ACCOUNT_PATH" "$DARKBLOOM_PROVIDER_ISSUER_PATH"; do
    if [ -f "$path" ]; then cat "$path"; else printf '<missing>\n'; fi
  done
  printf '%s\n' "$4"
} > "$REVERSE_COMPAT_PROBE_OUTPUT"
: > "${DARKBLOOM_AUTH_TOKEN_PATH%/*}/.provider-credential.lock"
`), 0700))
			// BuildProvider must take its explicit-binary branch; this inert
			// metallib satisfies discovery only. No Swift or model is executed.
			require.NoError(t, os.WriteFile(filepath.Join(root, "mlx.metallib"), nil, 0600))
			t.Setenv("DARKBLOOM_PROVIDER_BINARY", binary)
			t.Setenv("REVERSE_COMPAT_PROBE_OUTPUT", output)
			s := &Suite{
				Ctx:         context.Background(),
				Logger:      slog.New(slog.NewTextHandler(io.Discard, nil)),
				Config:      SuiteConfig{ModelSpecs: []ModelSpec{{ModelID: "fixture-model", NumProviders: 1}}},
				Coordinator: &Coordinator{baseURL: "http://127.0.0.1:54321"},
				PgStore:     NewMemoryStore(),
			}
			p := &Provider{BinaryPath: binary, Logger: s.Logger}
			cfg := DefaultProviderConfig()
			if mode == "complete" {
				t.Cleanup(s.Stop)
				require.NoError(t, s.startProviders())
				require.Len(t, s.Providers, 1)
				p = s.Providers[0]
			} else {
				if mode == "token_only" {
					cfg.AuthTokenPath = filepath.Join(t.TempDir(), "auth_token")
					require.NoError(t, os.Chmod(filepath.Dir(cfg.AuthTokenPath), 0700))
					require.NoError(t, os.WriteFile(cfg.AuthTokenPath, []byte("partial-fixture-token\n"), 0600))
				}
				t.Cleanup(p.Stop)
				require.NoError(t, p.Start(s.Ctx, s.Coordinator.BaseURL(), cfg))
			}
			select {
			case <-p.done:
			case <-time.After(5 * time.Second):
				t.Fatal("credential probe did not exit")
			}
			observed := strings.Split(reverseCompatRead(t, output), "\n")
			require.Len(t, observed, 7)
			dir := p.StateDir
			if mode == "complete" {
				dir = filepath.Join(p.AuthDir, ".darkbloom")
			} else if mode == "token_only" {
				dir = filepath.Dir(cfg.AuthTokenPath)
			}
			for i, name := range names {
				if want := filepath.Join(dir, name); observed[i] != want {
					t.Errorf("REVERSE_COMPAT_CREDENTIAL_MISMATCH: %s got %q, want %q", keys[i], observed[i], want)
				}
			}
			reverseCompatMode(t, dir, 0700)
			require.Equal(t, "ws://127.0.0.1:54321/ws/provider", observed[6])
			if mode == "complete" {
				for _, name := range names {
					reverseCompatMode(t, filepath.Join(dir, name), 0600)
				}
				record, err := s.PgStore.GetProviderToken(observed[3])
				require.NoError(t, err)
				require.True(t, record.Active)
				require.Equal(t, "testbed-provider-0", record.AccountID)
				require.Equal(t, record.AccountID, observed[4])
				require.Equal(t, s.Coordinator.BaseURL(), observed[5])
			} else {
				for i, name := range names {
					if mode == "token_only" && i == 0 {
						require.Equal(t, "partial-fixture-token", observed[3])
						continue
					}
					require.NoFileExists(t, filepath.Join(dir, name))
					require.Equal(t, "<missing>", observed[i+3])
				}
			}
			p.Stop()
			require.NoDirExists(t, p.StateDir)
			if mode == "complete" {
				require.NoDirExists(t, p.AuthDir)
			} else if mode == "token_only" {
				require.Equal(t, "partial-fixture-token", reverseCompatRead(t, cfg.AuthTokenPath))
			}
		})
	}
}

func TestReverseCompatProviderCredentialIssuer(t *testing.T) {
	for _, tc := range []struct{ endpoint, issuer string }{
		{"http://127.0.0.1:54321", "http://127.0.0.1:54321"},
		{" \nWSS://Issuer.Example:443/ws/provider?region=one#fragment\t", "https://issuer.example:443"},
		{"https://Issuer.Example/other/path/", "https://issuer.example"},
		{"ws://[::1]:54321/ws/provider", "http://[::1]:54321"},
	} {
		t.Run(tc.endpoint, func(t *testing.T) {
			s := &Suite{Coordinator: &Coordinator{baseURL: tc.endpoint}, PgStore: NewMemoryStore()}
			dir, token, err := s.prepareProviderAuth(7)
			require.NoError(t, err)
			t.Cleanup(func() { require.NoError(t, os.RemoveAll(dir)) })
			require.Equal(t, tc.issuer, reverseCompatRead(t, filepath.Join(filepath.Dir(token), "provider_issuer")))
			require.Equal(t, "testbed-provider-7", reverseCompatRead(t, filepath.Join(filepath.Dir(token), "provider_account")))
		})
	}
	for _, endpoint := range []string{"", "http://user@localhost:54321", "ftp://localhost", "http://localhost:bad"} {
		t.Run("reject_"+endpoint, func(t *testing.T) {
			s := &Suite{Coordinator: &Coordinator{baseURL: endpoint}}
			_, _, err := s.prepareProviderAuth(0)
			require.Error(t, err)
		})
	}
}
