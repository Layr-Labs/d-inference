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
}

type EmailProvider string

const emailProviderResend EmailProvider = "resend"

type ResendAPIKey struct {
	value string
}

func (k ResendAPIKey) Value() string {
	return k.value
}

func (k ResendAPIKey) IsSet() bool {
	return k.value != ""
}

func (k ResendAPIKey) String() string {
	if k.value == "" {
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
	resendRaw := strings.TrimSpace(os.Getenv(env.EnvPrefix + "_RESEND_API_KEY"))
	resendKey, validResendKey := newResendAPIKey(resendRaw)
	var provider EmailProvider
	if resendRaw != "" {
		provider = emailProviderResend
	}

	consoleURL := strings.TrimRight(os.Getenv(env.EnvPrefix+"_CONSOLE_URL"), "/")
	if consoleURL != "" {
		consoleURL += defaultConsolePath
	}

	cfg := Config{
		Enabled:            resendRaw != "",
		Provider:           provider,
		ResendAPIKey:       resendKey,
		From:               env.EnvOr(env.EnvPrefix+"_EMAIL_FROM", defaultEmailFrom),
		ConsoleURL:         consoleURL,
		UnsubscribeURL:     env.EnvOr(env.EnvPrefix+"_EMAIL_UNSUBSCRIBE_URL", defaultUnsubscribeURL),
		CheckInterval:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_CHECK_SECONDS", int(defaultCheckInterval.Seconds()))) * time.Second,
		AlertCooldown:      time.Duration(env.EnvInt(env.EnvPrefix+"_PROVIDER_ALERT_COOLDOWN_HOURS", int(defaultAlertCooldown.Hours()))) * time.Hour,
		MinProviderVersion: strings.TrimSpace(os.Getenv(env.EnvPrefix + "_MIN_PROVIDER_VERSION")),
	}
	if resendRaw != "" && !validResendKey {
		cfg.ResendAPIKey = ResendAPIKey{}
	}
	return cfg
}

func newResendAPIKey(raw string) (ResendAPIKey, bool) {
	key := ResendAPIKey{value: strings.TrimSpace(raw)}
	if key.value == "" {
		return ResendAPIKey{}, true
	}
	if !key.Valid() {
		return ResendAPIKey{}, false
	}
	return key, true
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
