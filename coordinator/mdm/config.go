package mdm

import (
	"fmt"
	"net/url"
	"os"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/env"
)

const defaultMDMApiKey = "eigeninference-micromdm-api"

// Config holds MicroMDM client configuration.
type Config struct {
	URL    string // MicroMDM server URL
	APIKey string // MDM API key
}

// ReadConfig reads MDM configuration from environment variables.
func ReadConfig() Config {
	apiKey := os.Getenv(env.EnvPrefix + "_MDM_API_KEY")
	if apiKey == "" {
		apiKey = defaultMDMApiKey
	}
	return Config{
		URL:    os.Getenv(env.EnvPrefix + "_MDM_URL"),
		APIKey: apiKey,
	}
}

func (c Config) Check() error {
	if strings.TrimSpace(c.URL) == "" {
		return nil
	}
	parsed, err := url.Parse(c.URL)
	if err != nil || parsed.Host == "" ||
		(parsed.Scheme != "http" && parsed.Scheme != "https") {
		return fmt.Errorf("MDM URL must be an absolute http or https URL")
	}
	if strings.TrimSpace(c.APIKey) == "" {
		return fmt.Errorf("MDM API key is required when MDM URL is configured")
	}
	return nil
}
