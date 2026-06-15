package api

import (
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/env"
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
	ServiceReservations  bool
}

// ReadServerConfig reads server configuration from environment variables.
func ReadServerConfig() ServerConfig {
	return ServerConfig{
		Port:                 env.EnvOr(env.EnvPrefix+"_PORT", "8080"),
		ConsoleURL:           os.Getenv(env.EnvPrefix + "_CONSOLE_URL"),
		CORSOrigin:           os.Getenv("CORS_ORIGIN"),
		BaseURL:              os.Getenv(env.EnvPrefix + "_BASE_URL"),
		R2CDNURL:             os.Getenv(env.EnvPrefix + "_R2_CDN_URL"),
		R2SitePackagesCDNURL: os.Getenv(env.EnvPrefix + "_R2_SITE_PACKAGES_CDN_URL"),
		MinProviderVersion:   os.Getenv(env.EnvPrefix + "_MIN_PROVIDER_VERSION"),
		AdminKey:             os.Getenv(env.EnvPrefix + "_ADMIN_KEY"),
		AdminEmails:          ParseCommaList(env.EnvOr(env.EnvPrefix+"_ADMIN_EMAILS", "")),
		ReleaseKey:           os.Getenv(env.EnvPrefix + "_RELEASE_KEY"),
		ServiceReservations:  env.EnvBool(env.EnvPrefix+"_SERVICE_RESERVATIONS_ENABLED", false),
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
