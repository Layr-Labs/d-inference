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

const (
	providerHeartbeatTimeout = 90 * time.Second
	challengeMaxAge          = 6 * time.Minute
	checkOperationTimeout    = 5 * time.Minute
	storeOperationTimeout    = 10 * time.Second
	emailSendTimeout         = 5 * time.Second
)

type ProviderNotifier struct {
	registry *registry.Registry
	store    store.Store
	email    EmailClient
	cfg      Config
	logger   *slog.Logger
}

type providerAlertCandidate struct {
	target    store.ProviderNotificationTarget
	state     providerState
	stableKey string
	reasons   []AlertReason
}

type AlertReason struct {
	Key    AlertReasonKey
	Title  string
	Detail string
	Action string
}

type AlertReasonKey string

const (
	alertReasonOffline           AlertReasonKey = "offline"
	alertReasonVersionBelowMin   AlertReasonKey = "version_below_min"
	alertReasonRuntimeUnverified AlertReasonKey = "runtime_unverified"
	alertReasonThermalCritical   AlertReasonKey = "thermal_critical"
	alertReasonChallengeStale    AlertReasonKey = "challenge_stale"
	alertReasonUntrusted         AlertReasonKey = "untrusted"
	alertReasonTrustBelowMinimum AlertReasonKey = "trust_below_minimum"
)

type providerState struct {
	id                    string
	accountID             string
	serial                string
	version               string
	status                registry.ProviderStatus
	trustLevel            registry.TrustLevel
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
	if cfg.Email.Provider == emailProviderResend && cfg.Email.APIKey != "" {
		client = NewResendClient(cfg.Email.APIKey)
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
		for {
			select {
			case <-ctx.Done():
				return
			default:
			}
			n.Check(ctx)
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
			}
		}
	})
}

func (n *ProviderNotifier) Check(ctx context.Context) {
	if n == nil || n.email == nil || n.store == nil || n.registry == nil {
		return
	}
	if ctx.Err() != nil {
		return
	}
	checkCtx, cancel := context.WithTimeout(ctx, checkOperationTimeout)
	defer cancel()
	storeCtx, storeCancel := context.WithTimeout(checkCtx, storeOperationTimeout)
	targets, err := n.store.ListProviderNotificationTargets(storeCtx)
	storeCancel()
	if err != nil {
		n.logger.Warn("provider notifications: list provider targets failed", "error", err)
		return
	}
	candidates := n.alertCandidates(targets)
	if len(candidates) == 0 {
		return
	}
	checkCount := providerNotificationCheckCount(candidates)
	checks := make([]store.ProviderNotificationCheck, checkCount)
	checkIndex := 0
	for _, candidate := range candidates {
		for _, reason := range candidate.reasons {
			checks[checkIndex] = store.ProviderNotificationCheck{
				ProviderID: candidate.stableKey,
				AccountID:  candidate.target.Provider.AccountID,
				ReasonKey:  string(reason.Key),
			}
			checkIndex++
		}
	}
	storeCtx, storeCancel = context.WithTimeout(checkCtx, storeOperationTimeout)
	dueByCheck, err := n.store.ProviderNotificationsDue(storeCtx, checks, n.cfg.AlertCooldown)
	storeCancel()
	if err != nil {
		n.logger.Warn("provider notifications: cooldown lookup failed", "error", err)
		return
	}
	sent := make([]store.ProviderNotificationCheck, 0, checkCount)
	for _, candidate := range candidates {
		sent = append(sent, n.sendDue(checkCtx, candidate, dueByCheck)...)
	}
	storeCtx, storeCancel = context.WithTimeout(checkCtx, storeOperationTimeout)
	err = n.store.RecordProviderNotificationsSent(storeCtx, sent, time.Now())
	storeCancel()
	if err != nil {
		n.logger.Warn("provider notifications: record sends failed", "error", err)
	}
}

func providerNotificationCheckCount(candidates []providerAlertCandidate) int {
	n := 0
	for _, candidate := range candidates {
		n += len(candidate.reasons)
	}
	return n
}

func (n *ProviderNotifier) alertCandidates(targets []store.ProviderNotificationTarget) []providerAlertCandidate {
	candidates := make([]providerAlertCandidate, 0, len(targets))
	for _, target := range targets {
		rec := target.Provider
		if rec.AccountID == "" || target.Email == "" {
			continue
		}
		state := providerStateFromRecord(rec)
		if live := n.registry.GetProvider(rec.ID); live != nil {
			state = providerStateFromLive(live, rec)
		}
		reasons := n.reasons(state, time.Now())
		if len(reasons) == 0 {
			continue
		}
		candidates = append(candidates, providerAlertCandidate{
			target:    target,
			state:     state,
			stableKey: notificationStableKey(rec),
			reasons:   reasons,
		})
	}
	return candidates
}

func (n *ProviderNotifier) sendDue(ctx context.Context, candidate providerAlertCandidate, dueByCheck map[store.ProviderNotificationCheck]bool) []store.ProviderNotificationCheck {
	rec := candidate.target.Provider
	due := make([]AlertReason, 0, len(candidate.reasons))
	sent := make([]store.ProviderNotificationCheck, 0, len(candidate.reasons))
	for _, reason := range candidate.reasons {
		check := store.ProviderNotificationCheck{
			ProviderID: candidate.stableKey,
			AccountID:  rec.AccountID,
			ReasonKey:  string(reason.Key),
		}
		if isDue, exists := dueByCheck[check]; exists && isDue {
			due = append(due, reason)
			sent = append(sent, check)
		}
	}
	if len(due) == 0 {
		return nil
	}
	email := n.buildEmail(candidate.target.Email, candidate.state, due)
	sendCtx, cancel := context.WithTimeout(ctx, emailSendTimeout)
	defer cancel()
	if err := n.email.Send(sendCtx, email); err != nil {
		n.logger.Warn("provider notifications: email send failed",
			"provider_id", rec.ID,
			"serial", rec.SerialNumber,
			"error", err,
		)
		return nil
	}
	n.logger.Info("sent provider owner notification",
		"provider_id", rec.ID,
		"account_id", rec.AccountID,
		"reasons", reasonKeys(due),
	)
	return sent
}

func (n *ProviderNotifier) reasons(p providerState, now time.Time) []AlertReason {
	out := make([]AlertReason, 0, 7)
	if !p.online && now.Sub(p.lastSeen) >= providerHeartbeatTimeout {
		out = append(out, AlertReason{
			Key:    alertReasonOffline,
			Title:  "Machine offline",
			Detail: fmt.Sprintf("No heartbeat since %s.", p.lastSeen.UTC().Format(time.RFC822)),
			Action: "Start the provider with `darkbloom start` or check the machine/network.",
		})
	}
	if n.cfg.MinProviderVersion != "" && p.version != "" && semverLess(p.version, n.cfg.MinProviderVersion) {
		out = append(out, AlertReason{
			Key:    alertReasonVersionBelowMin,
			Title:  "Provider update required",
			Detail: fmt.Sprintf("This machine is on v%s; the coordinator requires v%s or newer.", p.version, n.cfg.MinProviderVersion),
			Action: "Update with the Darkbloom install script, then restart the provider.",
		})
	}
	if !p.runtimeVerified {
		out = append(out, AlertReason{
			Key:    alertReasonRuntimeUnverified,
			Title:  "Runtime verification failed",
			Detail: "The provider runtime hashes do not match the known-good release manifest.",
			Action: "Reinstall with the latest Darkbloom installer to restore routing eligibility.",
		})
	}
	if p.thermalState == "critical" {
		out = append(out, AlertReason{
			Key:    alertReasonThermalCritical,
			Title:  "Machine is thermally throttled",
			Detail: "The Mac reported a critical thermal state, so the coordinator will not route work to it.",
			Action: "Cool the machine and make sure it has adequate ventilation.",
		})
	}
	if p.online && p.lastChallengeVerified != nil && p.status != registry.StatusUntrusted && now.Sub(*p.lastChallengeVerified) > challengeMaxAge {
		out = append(out, AlertReason{
			Key:    alertReasonChallengeStale,
			Title:  "Attestation challenge stale",
			Detail: fmt.Sprintf("The last verified attestation challenge was %d minutes ago.", int(now.Sub(*p.lastChallengeVerified).Minutes())),
			Action: "Restart the provider so it can complete a fresh attestation handshake.",
		})
	}
	if p.status == registry.StatusUntrusted || p.failedChallenges >= registry.MaxFailedChallenges {
		out = append(out, AlertReason{
			Key:    alertReasonUntrusted,
			Title:  "Attestation challenge failures",
			Detail: fmt.Sprintf("%d consecutive challenge failures; this machine is not receiving requests.", p.failedChallenges),
			Action: "Restart the provider and run `darkbloom doctor` if it does not recover.",
		})
	} else if trustRank(p.trustLevel) < trustRank(n.registry.MinTrustLevel) {
		out = append(out, AlertReason{
			Key:    alertReasonTrustBelowMinimum,
			Title:  "MDM enrollment or hardware verification required",
			Detail: fmt.Sprintf("This machine is %s trust; public routing requires %s trust.", displayTrust(p.trustLevel), displayTrust(n.registry.MinTrustLevel)),
			Action: "Run `darkbloom enroll` on the Mac and approve the Darkbloom device-management profile.",
		})
	}
	return out
}

func (n *ProviderNotifier) buildEmail(to string, p providerState, reasons []AlertReason) Email {
	name := providerDisplayName(p)
	subject := fmt.Sprintf("Action needed: %s needs attention on Darkbloom", name)
	if len(reasons) == 1 && reasons[0].Key == alertReasonOffline {
		subject = fmt.Sprintf("Action needed: %s is offline on Darkbloom", name)
	}
	text := buildTextEmail(name, reasons, n.cfg.ConsoleURL)
	htmlBody := buildHTMLEmail(name, reasons, n.cfg.ConsoleURL)
	return Email{
		From:           n.cfg.Email.From,
		To:             to,
		Subject:        subject,
		Text:           text,
		HTML:           htmlBody,
		UnsubscribeURL: n.cfg.UnsubscribeURL,
	}
}
