package notifications

import (
	"fmt"
	"log/slog"
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
	Provider           EmailProvider
	ResendAPIKey       ResendAPIKey
	From               string
	ConsoleURL         string
	UnsubscribeURL     string
	CheckInterval      time.Duration
	AlertCooldown      time.Duration
	MinProviderVersion string
	validationErr      error
}

type EmailProvider string

const emailProviderResend EmailProvider = "resend"

type ResendAPIKey string

func (k ResendAPIKey) Value() string {
	return string(k)
}

func (k ResendAPIKey) String() string {
	if k == "" {
		return ""
	}
	return "[redacted]"
}

func (k ResendAPIKey) GoString() string {
	return k.String()
}

func (k ResendAPIKey) LogValue() slog.Value {
	return slog.StringValue(k.String())
}

func (k ResendAPIKey) Valid() bool {
	v := k.Value()
	return strings.HasPrefix(v, "re_") && !strings.ContainsAny(v, " \t\r\n")
}

func ReadConfig() Config {
	resendKey, validationErr := readResendAPIKeyFromEnv()
	var provider EmailProvider
	if resendKey != "" {
		provider = emailProviderResend
	}

	consoleURL := strings.TrimRight(os.Getenv(env.EnvPrefix+"_CONSOLE_URL"), "/")
	if consoleURL != "" {
		consoleURL += defaultConsolePath
	}

	return Config{
		Enabled:            resendKey != "",
		Provider:           provider,
		ResendAPIKey:       resendKey,
		From:               env.EnvOr(env.EnvPrefix+"_EMAIL_FROM", defaultEmailFrom),
		ConsoleURL:         consoleURL,
		UnsubscribeURL:     env.EnvOr(env.EnvPrefix+"_EMAIL_UNSUBSCRIBE_URL", defaultUnsubscribeURL),
		CheckInterval:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_CHECK_SECONDS", int(defaultCheckInterval.Seconds()))) * time.Second,
		AlertCooldown:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_COOLDOWN_HOURS", int(defaultAlertCooldown.Hours()))) * time.Hour,
		MinProviderVersion: strings.TrimSpace(os.Getenv(env.EnvPrefix + "_MIN_PROVIDER_VERSION")),
		validationErr:      validationErr,
	}
}

func readResendAPIKeyFromEnv() (ResendAPIKey, error) {
	key := ResendAPIKey(strings.TrimSpace(os.Getenv(env.EnvPrefix + "_RESEND_API_KEY")))
	if key == "" {
		return "", nil
	}
	if !key.Valid() {
		return key, fmt.Errorf("provider email service credentials have an invalid format")
	}
	return key, nil
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
	if c.validationErr != nil {
		return c.validationErr
	}
	if c.Provider != emailProviderResend {
		return fmt.Errorf("unsupported provider email service")
	}
	if strings.TrimSpace(c.ResendAPIKey.Value()) == "" {
		return fmt.Errorf("provider email service credentials are not configured")
	}
	if !c.ResendAPIKey.Valid() {
		return fmt.Errorf("provider email service credentials have an invalid format")
	}
	if strings.TrimSpace(c.From) == "" {
		return fmt.Errorf("provider email sender is not configured")
	}
	return nil
}
