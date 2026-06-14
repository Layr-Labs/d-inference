package notifications

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

const (
	resendAPIKeyPrefix    = "re_"
	minResendAPIKeyLength = 24
	maxResendAPIKeyLength = 128
)

const (
	defaultEmailFrom      = "Darkbloom <providers@darkbloom.dev>"
	defaultCheckInterval  = 5 * time.Minute
	defaultAlertCooldown  = 24 * time.Hour
	defaultConsolePath    = "/providers"
	defaultUnsubscribeURL = "https://darkbloom.dev/unsubscribe"
)

type Config struct {
	Enabled            bool
	Email              EmailConfig
	ConsoleURL         string
	UnsubscribeURL     string
	CheckInterval      time.Duration
	AlertCooldown      time.Duration
	MinProviderVersion string
}

type EmailConfig struct {
	APIKey string
	From   string
}

func validResendAPIKey(key string) bool {
	return key == strings.TrimSpace(key) &&
		len(key) >= minResendAPIKeyLength &&
		len(key) <= maxResendAPIKeyLength &&
		strings.HasPrefix(key, resendAPIKeyPrefix)
}

func ReadConfig() Config {
	resendRaw := strings.TrimSpace(os.Getenv(env.EnvPrefix + "_RESEND_API_KEY"))
	if resendRaw == "" || !validResendAPIKey(resendRaw) {
		return Config{Enabled: false}
	}

	consoleURL := strings.TrimRight(os.Getenv(env.EnvPrefix+"_CONSOLE_URL"), "/")
	if consoleURL != "" {
		consoleURL += defaultConsolePath
	}

	cfg := Config{
		Enabled: true,
		Email: EmailConfig{
			APIKey: resendRaw,
			From:   env.EnvOr(env.EnvPrefix+"_EMAIL_FROM", defaultEmailFrom),
		},
		ConsoleURL:         consoleURL,
		UnsubscribeURL:     env.EnvOr(env.EnvPrefix+"_EMAIL_UNSUBSCRIBE_URL", defaultUnsubscribeURL),
		CheckInterval:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_CHECK_SECONDS", int(defaultCheckInterval.Seconds()))) * time.Second,
		AlertCooldown:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_COOLDOWN_HOURS", int(defaultAlertCooldown.Hours()))) * time.Hour,
		MinProviderVersion: strings.TrimSpace(os.Getenv(env.EnvPrefix + "_MIN_PROVIDER_VERSION")),
	}
	return cfg
}

func (c Config) WithDefaults() Config {
	if c.Email.From == "" {
		c.Email.From = defaultEmailFrom
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
	if strings.TrimSpace(c.Email.APIKey) == "" {
		return fmt.Errorf("provider email service credentials are not configured")
	}
	if !validResendAPIKey(c.Email.APIKey) {
		return fmt.Errorf("provider email service credentials have an invalid format")
	}
	if strings.TrimSpace(c.Email.From) == "" {
		return fmt.Errorf("provider email sender is not configured")
	}
	return nil
}
