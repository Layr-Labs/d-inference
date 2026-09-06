package testbed

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type providerCredentialPaths struct {
	token   string
	account string
	issuer  string
}

func providerCredentialPathsIn(dir string) providerCredentialPaths {
	return providerCredentialPaths{
		token:   filepath.Join(dir, "auth_token"),
		account: filepath.Join(dir, "provider_account"),
		issuer:  filepath.Join(dir, "provider_issuer"),
	}
}

// canonicalProviderIssuer mirrors Swift's canonicalCoordinatorIssuer for test
// coordinator URLs: HTTP(S) origin, lowercase host, non-default ports preserved,
// no userinfo, default port, path, query, or fragment.
func canonicalProviderIssuer(rawURL string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || u.Hostname() == "" || u.User != nil {
		return "", fmt.Errorf("invalid testbed coordinator URL")
	}
	switch strings.ToLower(u.Scheme) {
	case "http", "ws":
		u.Scheme = "http"
	case "https", "wss":
		u.Scheme = "https"
	default:
		return "", fmt.Errorf("invalid testbed coordinator URL scheme")
	}
	port, err := strconv.Atoi(u.Port())
	if err == nil && ((u.Scheme == "https" && port == 443) || (u.Scheme == "http" && port == 80)) {
		u.Host = strings.TrimSuffix(u.Host, ":"+u.Port())
	}
	return (&url.URL{Scheme: u.Scheme, Host: strings.ToLower(u.Host)}).String(), nil
}

// prepareProviderAuth registers a fixture token with the test coordinator and
// writes its complete credential. None of these values come from local login
// state. The returned directory is owned by Provider.Stop, including the Swift
// credential store's lock sidecar.
func (s *Suite) prepareProviderAuth(providerIdx int) (authDir string, paths providerCredentialPaths, err error) {
	issuer, err := canonicalProviderIssuer(s.Coordinator.BaseURL())
	if err != nil {
		return "", paths, err
	}
	authDir, err = os.MkdirTemp("", fmt.Sprintf("darkbloom-testbed-provider-%d-", providerIdx))
	if err != nil {
		return "", paths, err
	}
	defer func() {
		if err != nil {
			_ = os.RemoveAll(authDir)
		}
	}()
	paths = providerCredentialPathsIn(authDir)

	rawToken := fmt.Sprintf("testbed-provider-token-%d-%d", providerIdx, time.Now().UnixNano())
	accountID := fmt.Sprintf("testbed-provider-%d", providerIdx)
	// Publish metadata before the token, matching ProviderCredentialStore.
	for _, file := range []struct{ path, value string }{
		{paths.account, accountID},
		{paths.issuer, issuer},
		{paths.token, rawToken},
	} {
		if err = os.WriteFile(file.path, []byte(file.value+"\n"), 0600); err != nil {
			return authDir, paths, fmt.Errorf("write provider credential %s: %w", filepath.Base(file.path), err)
		}
	}
	tokenHash := sha256.Sum256([]byte(rawToken))
	err = s.PgStore.CreateProviderToken(&store.ProviderToken{
		TokenHash: hex.EncodeToString(tokenHash[:]),
		AccountID: accountID,
		Label:     accountID,
		Active:    true,
		CreatedAt: time.Now(),
	})
	return authDir, paths, err
}

// providerCredentialEnvironment replaces every inherited credential override.
// Missing config paths point to absent files, never operator defaults or legacy
// token migration paths. Partial fixtures stay partial for negative auth tests.
func providerCredentialEnvironment(base []string, cfg ProviderConfig, stateDir string) ([]string, error) {
	paths := providerCredentialPaths{cfg.AuthTokenPath, cfg.ProviderAccountPath, cfg.ProviderIssuerPath}
	if paths.token == "" || paths.account == "" || paths.issuer == "" {
		dir, err := os.MkdirTemp(stateDir, "credentials-")
		if err != nil {
			return nil, err
		}
		missing := providerCredentialPathsIn(dir)
		if paths.token == "" {
			paths.token = missing.token
		}
		if paths.account == "" {
			paths.account = missing.account
		}
		if paths.issuer == "" {
			paths.issuer = missing.issuer
		}
	}

	env := make([]string, 0, len(base)+3)
	for _, entry := range base {
		key, _, _ := strings.Cut(entry, "=")
		switch key {
		case "DARKBLOOM_AUTH_TOKEN_PATH", "DARKBLOOM_PROVIDER_ACCOUNT_PATH", "DARKBLOOM_PROVIDER_ISSUER_PATH":
			continue
		}
		env = append(env, entry)
	}
	return append(env,
		"DARKBLOOM_AUTH_TOKEN_PATH="+paths.token,
		"DARKBLOOM_PROVIDER_ACCOUNT_PATH="+paths.account,
		"DARKBLOOM_PROVIDER_ISSUER_PATH="+paths.issuer,
	), nil
}
