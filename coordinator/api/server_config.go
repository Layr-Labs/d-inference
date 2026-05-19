package api

import (
	"os"
	"strings"
)

// ServerConfig holds coordinator HTTP server and URL configuration.
// Each field corresponds to a Set* method on Server that is called during
// wiring in main.go.
type ServerConfig struct {
	Port                 string
	ConsoleURL           string
	CORSOrigin           string
	BaseURL              string
	R2CDNURL             string
	R2SitePackagesCDNURL string
	MinProviderVersion   string
	AdminKey             string
	AdminEmails          []string
	ReleaseKey           string
}

// ReadServerConfig reads server configuration from environment variables.
func ReadServerConfig() ServerConfig {
	return ServerConfig{
		Port:                 envOr("EIGENINFERENCE_PORT", "8080"),
		ConsoleURL:           os.Getenv("EIGENINFERENCE_CONSOLE_URL"),
		CORSOrigin:           os.Getenv("CORS_ORIGIN"),
		BaseURL:              os.Getenv("EIGENINFERENCE_BASE_URL"),
		R2CDNURL:             os.Getenv("EIGENINFERENCE_R2_CDN_URL"),
		R2SitePackagesCDNURL: os.Getenv("EIGENINFERENCE_R2_SITE_PACKAGES_CDN_URL"),
		MinProviderVersion:   os.Getenv("EIGENINFERENCE_MIN_PROVIDER_VERSION"),
		AdminKey:             os.Getenv("EIGENINFERENCE_ADMIN_KEY"),
		AdminEmails:          ParseCommaList(envOr("EIGENINFERENCE_ADMIN_EMAILS", "")),
		ReleaseKey:           os.Getenv("EIGENINFERENCE_RELEASE_KEY"),
	}
}

// ParseCommaList splits a comma-separated environment variable and trims
// whitespace from each element. Returns nil when the input is empty.
func ParseCommaList(raw string) []string {
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	result := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			result = append(result, p)
		}
	}
	return result
}

// envOr reads key from the environment and returns fallback when the key is
// missing or empty.
func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
