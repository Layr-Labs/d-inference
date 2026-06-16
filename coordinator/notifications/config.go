package notifications

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

const (
	defaultEmailFrom      = "Darkbloom <providers@darkbloom.dev>"
	defaultCheckInterval  = 5 * time.Minute
	defaultAlertCooldown  = 24 * time.Hour
	defaultConsolePath    = "/providers"
	defaultUnsubscribeURL = "https://darkbloom.dev/unsubscribe"
	minResendAPIKeyLength = len("re_") + 21
	maxResendAPIKeyLength = 128
)

type Config struct {
	Enabled            bool
	APIKey             string
	From               string
	ConsoleURL         string
	UnsubscribeURL     string
	CheckInterval      time.Duration
	AlertCooldown      time.Duration
	MinProviderVersion string
}

func validatedResendAPIKey(raw string) (string, bool) {
	key := strings.TrimSpace(raw)
	if raw != key ||
		len(key) < minResendAPIKeyLength ||
		len(key) > maxResendAPIKeyLength ||
		!strings.HasPrefix(key, "re_") {
		return "", false
	}
	for _, ch := range key[len("re_"):] {
		if (ch < 'A' || ch > 'Z') && (ch < 'a' || ch > 'z') && (ch < '0' || ch > '9') {
			return "", false
		}
	}
	return key, true
}

func ReadConfig() Config {
	apiKey, ok := validatedResendAPIKey(os.Getenv(env.EnvPrefix + "_RESEND_API_KEY"))
	if !ok {
		return Config{Enabled: false}
	}
	consoleURL := strings.TrimRight(os.Getenv(env.EnvPrefix+"_CONSOLE_URL"), "/")
	if consoleURL != "" {
		consoleURL += defaultConsolePath
	}
	cfg := Config{
		Enabled:            true,
		APIKey:             apiKey,
		From:               env.EnvOr(env.EnvPrefix+"_EMAIL_FROM", defaultEmailFrom),
		ConsoleURL:         consoleURL,
		UnsubscribeURL:     env.EnvOr(env.EnvPrefix+"_EMAIL_UNSUBSCRIBE_URL", defaultUnsubscribeURL),
		CheckInterval:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_CHECK_SECONDS", int(defaultCheckInterval.Seconds()))) * time.Second,
		AlertCooldown:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_COOLDOWN_HOURS", int(defaultAlertCooldown.Hours()))) * time.Hour,
		MinProviderVersion: strings.TrimSpace(os.Getenv(env.EnvPrefix + "_MIN_PROVIDER_VERSION")),
	}
	if err := cfg.Check(); err != nil {
		return Config{Enabled: false}
	}
	return cfg
}

func (c Config) WithDefaults() Config {
	if c.From == "" {
		c.From = defaultEmailFrom
	}
	if c.CheckInterval <= 0 {
		c.CheckInterval = defaultCheckInterval
	}
	if c.AlertCooldown <= 0 {
		c.AlertCooldown = defaultAlertCooldown
	}
	return c
}

func (c Config) Check() error {
	if !c.Enabled {
		return nil
	}
	if strings.TrimSpace(c.APIKey) == "" {
		return fmt.Errorf("provider email service is not configured")
	}
	if _, ok := validatedResendAPIKey(c.APIKey); !ok {
		return fmt.Errorf("provider email service configuration is invalid")
	}
	if strings.TrimSpace(c.From) == "" {
		return fmt.Errorf("provider email sender is not configured")
	}
	return nil
}
