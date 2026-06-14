package notifications

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type ProviderNotifier struct {
	registry *registry.Registry
	store    store.Store
	email    EmailClient
	cfg      Config
	logger   *slog.Logger
}

type AlertReason struct {
	Key    string
	Title  string
	Detail string
	Action string
}

type providerState struct {
	id                    string
	accountID             string
	serial                string
	version               string
	status                string
	trustLevel            string
	runtimeVerified       bool
	thermalState          string
	lastSeen              time.Time
	lastChallengeVerified *time.Time
	failedChallenges      int
	online                bool
}

func NewProviderNotifier(reg *registry.Registry, st store.Store, cfg Config, logger *slog.Logger) *ProviderNotifier {
	cfg = cfg.WithDefaults()
	var client EmailClient
	if cfg.Provider == "resend" && cfg.ResendAPIKey != "" {
		client = NewResendClient(cfg.ResendAPIKey)
	}
	return NewProviderNotifierWithEmail(reg, st, cfg, logger, client)
}

func NewProviderNotifierWithEmail(reg *registry.Registry, st store.Store, cfg Config, logger *slog.Logger, email EmailClient) *ProviderNotifier {
	if logger == nil {
		logger = slog.Default()
	}
	return &ProviderNotifier{
		registry: reg,
		store:    st,
		email:    email,
		cfg:      cfg.WithDefaults(),
		logger:   logger,
	}
}

func (n *ProviderNotifier) Start(ctx context.Context) {
	if n == nil || !n.cfg.Enabled {
		return
	}
	if n.email == nil {
		n.logger.Warn("provider email notifications enabled but no email client configured")
		return
	}
	ticker := time.NewTicker(n.cfg.CheckInterval)
	saferun.Go(n.logger, "providerEmailNotifier", func() {
		defer ticker.Stop()
		n.Check(ctx)
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				n.Check(ctx)
			}
		}
	})
}

func (n *ProviderNotifier) Check(ctx context.Context) {
	if n == nil || n.email == nil || n.store == nil || n.registry == nil {
		return
	}
	targets, err := n.store.ListProviderNotificationTargets(ctx)
	if err != nil {
		n.logger.Warn("provider notifications: list provider targets failed", "error", err)
		return
	}
	for _, target := range latestProviderNotificationTargets(targets) {
		if err := n.checkProvider(ctx, target); err != nil {
			n.logger.Warn("provider notifications: provider check failed",
				"provider_id", target.Provider.ID,
				"serial", target.Provider.SerialNumber,
				"error", err,
			)
		}
	}
}

func (n *ProviderNotifier) checkProvider(ctx context.Context, target store.ProviderNotificationTarget) error {
	rec := target.Provider
	if rec.AccountID == "" || target.Email == "" {
		return nil
	}
	state := providerStateFromRecord(rec)
	if live := n.registry.GetProvider(rec.ID); live != nil {
		state = providerStateFromLive(live, rec)
	}
	reasons := n.reasons(state, time.Now())
	if len(reasons) == 0 {
		return nil
	}
	var due []AlertReason
	stableKey := notificationStableKey(rec)
	dueByReason, err := n.store.ProviderNotificationsDue(ctx, stableKey, rec.AccountID, reasonKeys(reasons), n.cfg.AlertCooldown)
	if err != nil {
		return err
	}
	for _, reason := range reasons {
		if dueByReason[reason.Key] {
			due = append(due, reason)
		}
	}
	if len(due) == 0 {
		return nil
	}
	email := n.buildEmail(target.Email, state, due)
	sendCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	if err := n.email.Send(sendCtx, email); err != nil {
		return err
	}
	sentAt := time.Now()
	if err := n.store.RecordProviderNotificationsSent(ctx, stableKey, rec.AccountID, reasonKeys(due), sentAt); err != nil {
		n.logger.Warn("provider notifications: record send failed",
			"provider_id", rec.ID,
			"reasons", reasonKeys(due),
			"error", err,
		)
	}
	n.logger.Info("sent provider owner notification",
		"provider_id", rec.ID,
		"account_id", rec.AccountID,
		"reasons", reasonKeys(due),
	)
	return nil
}

func (n *ProviderNotifier) reasons(p providerState, now time.Time) []AlertReason {
	var out []AlertReason
	if !p.online && now.Sub(p.lastSeen) >= n.cfg.HeartbeatTimeout {
		out = append(out, AlertReason{
			Key:    "offline",
			Title:  "Machine offline",
			Detail: fmt.Sprintf("No heartbeat since %s.", p.lastSeen.UTC().Format(time.RFC822)),
			Action: "Start the provider with `darkbloom start` or check the machine/network.",
		})
	}
	if n.cfg.MinProviderVersion != "" && p.version != "" && semverLess(p.version, n.cfg.MinProviderVersion) {
		out = append(out, AlertReason{
			Key:    "version_below_min",
			Title:  "Provider update required",
			Detail: fmt.Sprintf("This machine is on v%s; the coordinator requires v%s or newer.", p.version, n.cfg.MinProviderVersion),
			Action: "Update with the Darkbloom install script, then restart the provider.",
		})
	}
	if !p.runtimeVerified {
		out = append(out, AlertReason{
			Key:    "runtime_unverified",
			Title:  "Runtime verification failed",
			Detail: "The provider runtime hashes do not match the known-good release manifest.",
			Action: "Reinstall with the latest Darkbloom installer to restore routing eligibility.",
		})
	}
	if p.thermalState == "critical" {
		out = append(out, AlertReason{
			Key:    "thermal_critical",
			Title:  "Machine is thermally throttled",
			Detail: "The Mac reported a critical thermal state, so the coordinator will not route work to it.",
			Action: "Cool the machine and make sure it has adequate ventilation.",
		})
	}
	if p.online && p.lastChallengeVerified != nil && p.status != string(registry.StatusUntrusted) && now.Sub(*p.lastChallengeVerified) > n.cfg.ChallengeMaxAge {
		out = append(out, AlertReason{
			Key:    "challenge_stale",
			Title:  "Attestation challenge stale",
			Detail: fmt.Sprintf("The last verified attestation challenge was %d minutes ago.", int(now.Sub(*p.lastChallengeVerified).Minutes())),
			Action: "Restart the provider so it can complete a fresh attestation handshake.",
		})
	}
	if p.status == string(registry.StatusUntrusted) || p.failedChallenges >= registry.MaxFailedChallenges {
		out = append(out, AlertReason{
			Key:    "untrusted",
			Title:  "Attestation challenge failures",
			Detail: fmt.Sprintf("%d consecutive challenge failures; this machine is not receiving requests.", p.failedChallenges),
			Action: "Restart the provider and run `darkbloom doctor` if it does not recover.",
		})
	} else if trustRank(p.trustLevel) < trustRank(string(n.registry.MinTrustLevel)) {
		out = append(out, AlertReason{
			Key:    "trust_below_minimum",
			Title:  "MDM enrollment or hardware verification required",
			Detail: fmt.Sprintf("This machine is %s trust; public routing requires %s trust.", displayTrust(p.trustLevel), displayTrust(string(n.registry.MinTrustLevel))),
			Action: "Run `darkbloom enroll` on the Mac and approve the Darkbloom device-management profile.",
		})
	}
	return out
}

func (n *ProviderNotifier) buildEmail(to string, p providerState, reasons []AlertReason) Email {
	name := providerDisplayName(p)
	subject := fmt.Sprintf("Action needed: %s needs attention on Darkbloom", name)
	if len(reasons) == 1 && reasons[0].Key == "offline" {
		subject = fmt.Sprintf("Action needed: %s is offline on Darkbloom", name)
	}
	text := buildTextEmail(name, reasons, n.cfg.ConsoleURL)
	htmlBody := buildHTMLEmail(name, reasons, n.cfg.ConsoleURL)
	return Email{
		From:           n.cfg.From,
		To:             to,
		Subject:        subject,
		Text:           text,
		HTML:           htmlBody,
		UnsubscribeURL: n.cfg.UnsubscribeURL,
	}
}
