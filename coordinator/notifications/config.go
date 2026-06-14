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
)

type Config struct {
	Enabled            bool
	Provider           string
	ResendAPIKey       string
	From               string
	ConsoleURL         string
	UnsubscribeURL     string
	CheckInterval      time.Duration
	AlertCooldown      time.Duration
	HeartbeatTimeout   time.Duration
	ChallengeMaxAge    time.Duration
	MinProviderVersion string
}

func ReadConfig() Config {
	provider := strings.ToLower(strings.TrimSpace(os.Getenv(env.EnvPrefix + "_EMAIL_PROVIDER")))
	resendKey := strings.TrimSpace(os.Getenv(env.EnvPrefix + "_RESEND_API_KEY"))
	enabled := os.Getenv(env.EnvPrefix+"_PROVIDER_EMAIL_NOTIFICATIONS") == "true"
	if provider == "" && resendKey != "" {
		provider = "resend"
	}
	if provider != "" && resendKey != "" {
		enabled = true
	}

	consoleURL := strings.TrimRight(os.Getenv(env.EnvPrefix+"_CONSOLE_URL"), "/")
	if consoleURL != "" {
		consoleURL += defaultConsolePath
	}

	return Config{
		Enabled:            enabled,
		Provider:           provider,
		ResendAPIKey:       resendKey,
		From:               env.EnvOr(env.EnvPrefix+"_EMAIL_FROM", defaultEmailFrom),
		ConsoleURL:         consoleURL,
		UnsubscribeURL:     env.EnvOr(env.EnvPrefix+"_EMAIL_UNSUBSCRIBE_URL", defaultUnsubscribeURL),
		CheckInterval:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_CHECK_SECONDS", int(defaultCheckInterval.Seconds()))) * time.Second,
		AlertCooldown:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_COOLDOWN_HOURS", int(defaultAlertCooldown.Hours()))) * time.Hour,
		MinProviderVersion: strings.TrimSpace(os.Getenv(env.EnvPrefix + "_MIN_PROVIDER_VERSION")),
	}
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
	if c.HeartbeatTimeout <= 0 {
		c.HeartbeatTimeout = 90 * time.Second
	}
	if c.ChallengeMaxAge <= 0 {
		c.ChallengeMaxAge = 6 * time.Minute
	}
	return c
}

func (c Config) Check() error {
	if !c.Enabled {
		return nil
	}
	if c.Provider != "resend" {
		return fmt.Errorf("unsupported provider email service")
	}
	if strings.TrimSpace(c.ResendAPIKey) == "" {
		return fmt.Errorf("provider email service credentials are not configured")
	}
	if !strings.HasPrefix(strings.TrimSpace(c.ResendAPIKey), "re_") {
		return fmt.Errorf("provider email service credentials have an invalid format")
	}
	if strings.TrimSpace(c.From) == "" {
		return fmt.Errorf("provider email sender is not configured")
	}
	return nil
}
