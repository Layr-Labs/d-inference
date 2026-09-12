package testbed

import (
	"fmt"
	"net"
	"net/url"
	"path/filepath"
	"strconv"
)

// ProviderStartSpec is the resolved, host-local description shared by the
// existing local launcher and the explicitly selected owned-host launcher.
// Authentication stays in a private file; argv and logs contain no token.
type ProviderStartSpec struct {
	Arguments   []string          `json:"arguments"`
	Environment map[string]string `json:"environment"`
	Config      string            `json:"config"`
	Root        string            `json:"root"`
}

func providerWebSocketURL(coordinatorURL string) (string, error) {
	u, err := url.Parse(coordinatorURL)
	if err != nil || u.User != nil || u.Host == "" || u.RawQuery != "" || u.Fragment != "" {
		return "", fmt.Errorf("invalid testbed coordinator URL")
	}
	switch u.Scheme {
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	default:
		return "", fmt.Errorf("coordinator URL must use HTTP or HTTPS")
	}
	if u.Path != "" && u.Path != "/" && u.Path != "/ws/provider" {
		return "", fmt.Errorf("invalid provider endpoint path")
	}
	u.Path = "/ws/provider"
	return u.String(), nil
}

func buildProviderStartSpec(coordinatorURL, root string, cfg ProviderConfig, index int) (ProviderStartSpec, error) {
	var s ProviderStartSpec
	ws, err := providerWebSocketURL(coordinatorURL)
	if err != nil {
		return s, err
	}
	if !filepath.IsAbs(root) || filepath.Clean(root) != root {
		return s, fmt.Errorf("provider root must be a clean absolute path")
	}
	config, err := BuildProviderTOML(cfg, index)
	if err != nil {
		return s, err
	}
	args := []string{"start", "--foreground", "--coordinator-url", ws}
	ids := cfg.ModelIDs
	if len(ids) == 0 && cfg.ModelID != "" {
		ids = []string{cfg.ModelID}
	}
	for _, id := range ids {
		args = append(args, "--model", id)
	}
	args = append(args, "--config", filepath.Join(root, "provider.toml"))
	env := map[string]string{
		"DARKBLOOM_PID_FILE":           filepath.Join(root, "provider.pid"),
		"DARKBLOOM_NO_UPDATE_CHECK":    "1",
		"DARKBLOOM_STATE_FILE":         filepath.Join(root, "daemon-state.json"),
		"DARKBLOOM_LOADED_MODELS_FILE": filepath.Join(root, "loaded-models.json"),
		"DARKBLOOM_LOCAL_DIR":          filepath.Join(root, "local"),
		"DARKBLOOM_KV_BACKEND_GUARD":   filepath.Join(root, "kv-backend-guard.json"),
		"TMPDIR":                       filepath.Join(root, "tmp"),
	}
	if cfg.AuthTokenPath != "" {
		env["DARKBLOOM_AUTH_TOKEN_PATH"] = cfg.AuthTokenPath
	}
	if cfg.EnableEphemeralPrefixCache {
		env["DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL"] = "1"
		env["DARKBLOOM_PREFIX_CACHE_TEST_ROOT"] = filepath.Join(root, "prefix-cache")
	}
	if cfg.PrefixCacheMode != "" {
		if cfg.PrefixCacheMode != "off" && cfg.PrefixCacheMode != "ssd" {
			return s, fmt.Errorf("explicit cache mode must be off or ssd")
		}
		env["DARKBLOOM_PREFIX_CACHE"] = "0"
		if cfg.PrefixCacheMode == "ssd" {
			env["DARKBLOOM_PREFIX_CACHE"] = "1"
		}
	}
	return ProviderStartSpec{Arguments: args, Environment: env, Config: config, Root: root}, nil
}

// Only a loopback provider relay may be advertised through the owned tunnel.
// This never makes the coordinator's admin listener network-accessible.
func loopbackRelayPort(endpoint string) (string, error) {
	u, err := url.Parse(endpoint)
	if err != nil || u.Scheme != "http" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return "", fmt.Errorf("owned target needs a loopback HTTP relay")
	}
	host, port, err := net.SplitHostPort(u.Host)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return "", fmt.Errorf("owned target needs an explicit loopback relay port")
	}
	number, err := strconv.Atoi(port)
	if err != nil || number < 1 || number > 65535 {
		return "", fmt.Errorf("invalid loopback relay port")
	}
	return port, nil
}
