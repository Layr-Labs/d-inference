package mdm

import "os"

const defaultMDMApiKey = "eigeninference-micromdm-api"

// Config holds MicroMDM client configuration.
type Config struct {
	URL    string // MicroMDM server URL
	APIKey string // MDM API key
}

// ReadConfig reads MDM configuration from environment variables.
func ReadConfig() Config {
	apiKey := os.Getenv("EIGENINFERENCE_MDM_API_KEY")
	if apiKey == "" {
		apiKey = defaultMDMApiKey
	}
	return Config{
		URL:    os.Getenv("EIGENINFERENCE_MDM_URL"),
		APIKey: apiKey,
	}
}

func (c Config) Check() error { return nil }
