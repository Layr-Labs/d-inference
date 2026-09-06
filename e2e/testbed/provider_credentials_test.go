package testbed

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/stretchr/testify/require"
)

func credentialTestSuite(t *testing.T) *Suite {
	t.Helper()
	s := NewSuite(DefaultSuiteConfig())
	s.Ctx = context.Background()
	s.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	s.PgStore = NewMemoryStore()
	require.NoError(t, s.startCoordinator())
	t.Cleanup(func() {
		require.NoError(t, s.Coordinator.Stop())
		s.Coordinator.Server.Close()
	})
	return s
}

func credentialFileValue(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	require.NoError(t, err)
	return strings.TrimSpace(string(data))
}

func requireCredentialPermissions(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	require.NoError(t, err)
	require.Equal(t, mode, info.Mode().Perm(), path)
}

func TestPrepareProviderAuthWritesCompleteCoordinatorCredential(t *testing.T) {
	s := credentialTestSuite(t)
	var previousDir, previousToken string
	for _, index := range []int{0, 0, 1} {
		dir, paths, err := s.prepareProviderAuth(index)
		require.NoError(t, err)
		t.Cleanup(func() { require.NoError(t, os.RemoveAll(dir)) })
		require.NotEqual(t, previousDir, dir)
		requireCredentialPermissions(t, dir, 0700)
		for _, path := range []string{paths.token, paths.account, paths.issuer} {
			require.Equal(t, dir, filepath.Dir(path))
			requireCredentialPermissions(t, path, 0600)
		}

		token := credentialFileValue(t, paths.token)
		require.NotEmpty(t, token)
		require.NotEqual(t, previousToken, token)
		account := fmt.Sprintf("testbed-provider-%d", index)
		require.Equal(t, account, credentialFileValue(t, paths.account))
		require.Equal(t, s.Coordinator.BaseURL(), credentialFileValue(t, paths.issuer))
		// Look up the actual file token through the same store API used by
		// coordinator provider authentication, including its SHA-256 hash.
		record, err := s.PgStore.GetProviderToken(token)
		require.NoError(t, err)
		require.Equal(t, account, record.AccountID)
		require.True(t, record.Active)
		hash := sha256.Sum256([]byte(token))
		require.Equal(t, hex.EncodeToString(hash[:]), record.TokenHash)
		previousDir, previousToken = dir, token
	}
}

func TestCanonicalProviderIssuerMatchesSwiftOriginContract(t *testing.T) {
	for _, tc := range []struct{ input, want string }{
		{"http://127.0.0.1:54321", "http://127.0.0.1:54321"},
		{"ws://127.0.0.1:54321/ws/provider", "http://127.0.0.1:54321"},
		{" \nWSS://Issuer.Example:443/ws/provider?region=one#fragment\t", "https://issuer.example:443"},
		{"https://Issuer.Example/other/path/", "https://issuer.example"},
		{"wss://Issuer.Example/ws/provider", "https://issuer.example"},
		{"http://Issuer.Example:80/", "http://issuer.example:80"},
		{"ws://[::1]:54321/ws/provider", "http://[::1]:54321"},
		{"https://[2001:DB8::1]:8443/api/", "https://[2001:db8::1]:8443"},
	} {
		t.Run(tc.input, func(t *testing.T) {
			got, err := canonicalProviderIssuer(tc.input)
			require.NoError(t, err)
			require.Equal(t, tc.want, got)
		})
	}
	for _, invalid := range []string{
		"", "/ws/provider", "localhost:1234", "https:///no-host", "ftp://issuer.example",
		"http://user:password@issuer.example", "http://user@issuer.example", "http://@issuer.example",
		"http://issuer.example:bad", "http://[::1", "http://%zz",
	} {
		t.Run("invalid_"+invalid, func(t *testing.T) {
			_, err := canonicalProviderIssuer(invalid)
			require.Error(t, err)
		})
	}
	issuer, err := canonicalProviderIssuer("ws://localhost:54321/ws/provider")
	require.NoError(t, err)
	for _, other := range []string{
		"ws://localhost:54322/ws/provider", "wss://localhost:54321/ws/provider", "ws://other.example:54321/ws/provider",
	} {
		got, err := canonicalProviderIssuer(other)
		require.NoError(t, err)
		require.NotEqual(t, issuer, got, "host, port, and transport must stay bound")
	}
}

type failingCredentialStore struct {
	store.Store
	err error
}

func (s failingCredentialStore) CreateProviderToken(*store.ProviderToken) error { return s.err }

func TestPrepareProviderAuthCleansUpWhenTokenRegistrationFails(t *testing.T) {
	root := t.TempDir()
	t.Setenv("TMPDIR", root)
	failure := errors.New("fixture token store unavailable")
	s := &Suite{
		Coordinator: &Coordinator{baseURL: "http://127.0.0.1:54321"},
		PgStore:     failingCredentialStore{err: failure},
	}
	dir, _, err := s.prepareProviderAuth(0)
	require.ErrorIs(t, err, failure)
	require.NoDirExists(t, dir)
	entries, err := os.ReadDir(root)
	require.NoError(t, err)
	require.Empty(t, entries, "failed fixture must leave no credential files")
}

func TestPrepareProviderAuthRejectsInvalidIssuerBeforeCreatingFiles(t *testing.T) {
	root := t.TempDir()
	t.Setenv("TMPDIR", root)
	// No store is needed: validation must fail before attempting issuance.
	s := &Suite{Coordinator: &Coordinator{baseURL: "http://user@localhost:54321"}}
	_, _, err := s.prepareProviderAuth(0)
	require.Error(t, err)
	entries, err := os.ReadDir(root)
	require.NoError(t, err)
	require.Empty(t, entries)
}

func TestProviderCredentialEnvironmentReplacesEveryInheritedOverride(t *testing.T) {
	stateDir := t.TempDir()
	paths := providerCredentialPathsIn(t.TempDir())
	cfg := ProviderConfig{
		AuthTokenPath: paths.token, ProviderAccountPath: paths.account, ProviderIssuerPath: paths.issuer,
	}
	base := []string{
		"PATH=/test/bin", "KEEP=value=with=equals", "DARKBLOOM_PROVIDER_ACCOUNT_PATH_EXTRA=keep",
		"DARKBLOOM_AUTH_TOKEN_PATH=/operator/token", "DARKBLOOM_AUTH_TOKEN_PATH=/stale/token",
		"DARKBLOOM_PROVIDER_ACCOUNT_PATH=/operator/account", "DARKBLOOM_PROVIDER_ACCOUNT_PATH=/stale/account",
		"DARKBLOOM_PROVIDER_ISSUER_PATH=/operator/issuer", "DARKBLOOM_PROVIDER_ISSUER_PATH=/stale/issuer",
	}
	before := append([]string(nil), base...)
	env, err := providerCredentialEnvironment(base, cfg, stateDir)
	require.NoError(t, err)
	require.Equal(t, before, base, "must not mutate caller environment")
	require.ElementsMatch(t, []string{
		"PATH=/test/bin", "KEEP=value=with=equals", "DARKBLOOM_PROVIDER_ACCOUNT_PATH_EXTRA=keep",
		"DARKBLOOM_AUTH_TOKEN_PATH=" + paths.token,
		"DARKBLOOM_PROVIDER_ACCOUNT_PATH=" + paths.account,
		"DARKBLOOM_PROVIDER_ISSUER_PATH=" + paths.issuer,
	}, env)
	for _, path := range []string{paths.token, paths.account, paths.issuer} {
		require.NoFileExists(t, path, "env setup must not write supplied credential paths")
	}
}
