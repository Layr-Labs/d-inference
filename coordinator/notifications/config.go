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
	Enabled bool
	Email   EmailConfig
	Alerts  AlertConfig
}

type EmailConfig struct {
	APIKey string
	From   string
}

type AlertConfig struct {
	ConsoleURL         string
	UnsubscribeURL     string
	CheckInterval      time.Duration
	AlertCooldown      time.Duration
	MinProviderVersion string
}

func validResendAPIKey(key string) bool {
	if key != strings.TrimSpace(key) ||
		len(key) < minResendAPIKeyLength ||
		len(key) > maxResendAPIKeyLength ||
		!strings.HasPrefix(key, resendAPIKeyPrefix) {
		return false
	}
	for _, r := range key {
		if !validResendAPIKeyChar(r) {
			return false
		}
	}
	return true
}

func validResendAPIKeyChar(r rune) bool {
	return r >= 'a' && r <= 'z' ||
		r >= 'A' && r <= 'Z' ||
		r >= '0' && r <= '9' ||
		r == '_' || r == '-'
}

func validatedResendAPIKey(raw string) (string, bool) {
	key := strings.TrimSpace(raw)
	if !validResendAPIKey(key) {
		return "", false
	}
	return key, true
}

func ReadConfig() Config {
	apiKey, ok := resendAPIKeyFromEnv()
	if !ok {
		return Config{Enabled: false}
	}
	consoleURL := strings.TrimRight(os.Getenv(env.EnvPrefix+"_CONSOLE_URL"), "/")
	if consoleURL != "" {
		consoleURL += defaultConsolePath
	}
	cfg := Config{
		Enabled: true,
		Email: EmailConfig{
			APIKey: apiKey,
			From:   env.EnvOr(env.EnvPrefix+"_EMAIL_FROM", defaultEmailFrom),
		},
		Alerts: AlertConfig{
			ConsoleURL:         consoleURL,
			UnsubscribeURL:     env.EnvOr(env.EnvPrefix+"_EMAIL_UNSUBSCRIBE_URL", defaultUnsubscribeURL),
			CheckInterval:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_CHECK_SECONDS", int(defaultCheckInterval.Seconds()))) * time.Second,
			AlertCooldown:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_COOLDOWN_HOURS", int(defaultAlertCooldown.Hours()))) * time.Hour,
			MinProviderVersion: strings.TrimSpace(os.Getenv(env.EnvPrefix + "_MIN_PROVIDER_VERSION")),
		},
	}
	if err := cfg.Check(); err != nil {
		return Config{Enabled: false}
	}
	return cfg
}

func resendAPIKeyFromEnv() (string, bool) {
	return validatedResendAPIKey(os.Getenv(env.EnvPrefix + "_RESEND_API_KEY"))
}

func (c Config) WithDefaults() Config {
	if c.Email.From == "" {
		c.Email.From = defaultEmailFrom
	}
	if c.Alerts.CheckInterval <= 0 {
		c.Alerts.CheckInterval = defaultCheckInterval
	}
	if c.Alerts.AlertCooldown <= 0 {
		c.Alerts.AlertCooldown = defaultAlertCooldown
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
	if _, ok := validatedResendAPIKey(c.Email.APIKey); !ok {
		return fmt.Errorf("provider email service credentials have an invalid format")
	}
	if strings.TrimSpace(c.Email.From) == "" {
		return fmt.Errorf("provider email sender is not configured")
	}
	return nil
}
