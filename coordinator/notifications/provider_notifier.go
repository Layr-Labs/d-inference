package notifications

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"golang.org/x/mod/semver"
)

const (
	providerHeartbeatTimeout = 90 * time.Second
	challengeMaxAge          = 6 * time.Minute
	checkOperationTimeout    = 5 * time.Minute
	storeOperationTimeout    = 10 * time.Second
	emailSendTimeout         = 5 * time.Second
	maxProviderAlertReasons  = 7
	maxProviderAlertTargets  = 1000
)

type ProviderNotifier struct {
	registry *registry.Registry
	store    store.Store
	sender   EmailSender
	cfg      Config
	logger   *slog.Logger
}

type providerAlertCandidate struct {
	email     string
	state     providerState
	stableKey string
	reasons   []AlertReason
	checks    []store.ProviderNotificationCheck
}

type ProviderNotifierOption func(*ProviderNotifier)

type AlertReason struct {
	Key    store.ProviderNotificationReasonKey
	Title  string
	Detail string
	Action string
}

const (
	alertReasonOffline           = store.ProviderNotificationReasonOffline
	alertReasonVersionBelowMin   = store.ProviderNotificationReasonVersionBelowMin
	alertReasonRuntimeUnverified = store.ProviderNotificationReasonRuntimeUnverified
	alertReasonThermalCritical   = store.ProviderNotificationReasonThermalCritical
	alertReasonChallengeStale    = store.ProviderNotificationReasonChallengeStale
	alertReasonUntrusted         = store.ProviderNotificationReasonUntrusted
	alertReasonTrustBelowMinimum = store.ProviderNotificationReasonTrustBelowMinimum
)

func validAlertReasonKey(k store.ProviderNotificationReasonKey) bool {
	return k.Valid()
}

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

func NewProviderNotifier(reg *registry.Registry, st store.Store, cfg Config, logger *slog.Logger, opts ...ProviderNotifierOption) *ProviderNotifier {
	if logger == nil {
		logger = slog.Default()
	}
	cfg = cfg.WithDefaults()
	notifier := &ProviderNotifier{
		registry: reg,
		store:    st,
		sender:   resendSender(cfg.Email.APIKey),
		cfg:      cfg,
		logger:   logger,
	}
	for _, opt := range opts {
		opt(notifier)
	}
	return notifier
}

func WithProviderNotificationSender(sender EmailSender) ProviderNotifierOption {
	return func(n *ProviderNotifier) {
		n.sender = sender
	}
}

func resendSender(apiKey string) EmailSender {
	if apiKey == "" {
		return nil
	}
	client, err := NewResendClient(apiKey)
	if err != nil {
		return nil
	}
	return client
}

func (n *ProviderNotifier) Start(ctx context.Context) {
	if n == nil || !n.cfg.Enabled {
		return
	}
	if n.sender == nil {
		n.logger.Warn("provider email notifications enabled but no email client configured")
		return
	}
	ticker := time.NewTicker(n.cfg.Alerts.CheckInterval)
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
	if n == nil || n.sender == nil || n.store == nil || n.registry == nil {
		return
	}
	if ctx.Err() != nil {
		return
	}
	checkCtx, cancel := context.WithTimeout(ctx, checkOperationTimeout)
	defer cancel()
	targets, ok := n.notificationTargets(checkCtx)
	if !ok {
		return
	}
	if len(targets) > maxProviderAlertTargets {
		targets = targets[:maxProviderAlertTargets]
	}
	if len(targets) == 0 {
		return
	}
	candidateCapacity := len(targets)
	checkCapacity := candidateCapacity * maxProviderAlertReasons
	candidates := make([]providerAlertCandidate, 0, candidateCapacity)
	checks := make([]store.ProviderNotificationCheck, 0, checkCapacity)
	candidates, checks = n.alertCandidates(targets, candidates, checks)
	if len(checks) == 0 {
		return
	}
	dueByCheck, ok := n.notificationsDue(checkCtx, checks)
	if !ok {
		return
	}
	sent := make([]store.ProviderNotificationCheck, 0, len(checks))
	for _, candidate := range candidates {
		sent = append(sent, n.sendDue(checkCtx, candidate, dueByCheck)...)
	}
	n.recordNotificationsSent(checkCtx, sent)
}

func (n *ProviderNotifier) notificationTargets(ctx context.Context) ([]store.ProviderNotificationTarget, bool) {
	storeCtx, cancel := context.WithTimeout(ctx, storeOperationTimeout)
	defer cancel()
	targets, err := n.store.ListProviderNotificationTargets(storeCtx)
	if err != nil {
		n.logger.Warn("provider notifications: list provider targets failed", "error", err)
		return nil, false
	}
	return targets, true
}

func (n *ProviderNotifier) notificationsDue(ctx context.Context, checks []store.ProviderNotificationCheck) (store.ProviderNotificationDueSet, bool) {
	storeCtx, cancel := context.WithTimeout(ctx, storeOperationTimeout)
	defer cancel()
	dueByCheck, err := n.store.ProviderNotificationsDue(storeCtx, checks, n.cfg.Alerts.AlertCooldown)
	if err != nil {
		n.logger.Warn("provider notifications: cooldown lookup failed", "error", err)
		return nil, false
	}
	return dueByCheck, true
}

func (n *ProviderNotifier) recordNotificationsSent(ctx context.Context, sent []store.ProviderNotificationCheck) {
	storeCtx, cancel := context.WithTimeout(ctx, storeOperationTimeout)
	defer cancel()
	if err := n.store.RecordProviderNotificationsSent(storeCtx, sent, time.Now()); err != nil {
		n.logger.Warn("provider notifications: record sends failed", "error", err)
	}
}

func (n *ProviderNotifier) alertCandidates(
	targets []store.ProviderNotificationTarget,
	candidates []providerAlertCandidate,
	checks []store.ProviderNotificationCheck,
) ([]providerAlertCandidate, []store.ProviderNotificationCheck) {
	seen := make(map[string]struct{}, len(targets))
	for _, target := range targets {
		rec := target.Provider
		if rec.AccountID == "" || target.Email == "" {
			continue
		}
		stableKey := store.ProviderNotificationStableKey(rec)
		if _, ok := seen[stableKey]; ok {
			continue
		}
		state := providerStateFrom(rec, n.registry.GetProvider(rec.ID))
		reasons := n.reasons(state, time.Now())
		if len(reasons) == 0 {
			continue
		}
		candidate := providerAlertCandidate{
			email:     target.Email,
			state:     state,
			stableKey: stableKey,
			reasons:   reasons[:0],
			checks:    make([]store.ProviderNotificationCheck, 0, len(reasons)),
		}
		for _, reason := range reasons {
			if !validAlertReasonKey(reason.Key) {
				continue
			}
			check := store.ProviderNotificationCheck{
				ProviderID: stableKey,
				AccountID:  state.accountID,
				ReasonKey:  reason.Key,
			}
			candidate.reasons = append(candidate.reasons, reason)
			candidate.checks = append(candidate.checks, check)
			checks = append(checks, check)
		}
		if len(candidate.checks) == 0 {
			continue
		}
		candidates = append(candidates, candidate)
		seen[stableKey] = struct{}{}
	}
	return candidates, checks
}

func (n *ProviderNotifier) sendDue(ctx context.Context, candidate providerAlertCandidate, dueByCheck store.ProviderNotificationDueSet) []store.ProviderNotificationCheck {
	sent := make([]store.ProviderNotificationCheck, 0, len(candidate.checks))
	due := candidate.reasons[:0]
	for i, check := range candidate.checks {
		if dueByCheck.Contains(check) {
			due = append(due, candidate.reasons[i])
			sent = append(sent, check)
		}
	}
	if len(due) == 0 {
		return nil
	}
	email := n.buildEmail(candidate.email, candidate.state, due)
	sendCtx, cancel := context.WithTimeout(ctx, emailSendTimeout)
	defer cancel()
	if err := n.sender.Send(sendCtx, email); err != nil {
		n.logger.Warn("provider notifications: email send failed",
			"provider_id", candidate.state.id,
			"serial", candidate.state.serial,
			"error", err,
		)
		return nil
	}
	n.logger.Info("sent provider owner notification",
		"provider_id", candidate.state.id,
		"account_id", candidate.state.accountID,
		"reasons", reasonKeys(due),
	)
	return sent
}

func (n *ProviderNotifier) reasons(p providerState, now time.Time) []AlertReason {
	providerVersion := semverCanonical(p.version)
	minVersion := semverCanonical(n.cfg.Alerts.MinProviderVersion)
	out := make([]AlertReason, 0, maxProviderAlertReasons)
	if !p.online && now.Sub(p.lastSeen) >= providerHeartbeatTimeout {
		out = append(out, AlertReason{
			Key:    alertReasonOffline,
			Title:  "Machine offline",
			Detail: fmt.Sprintf("No heartbeat since %s.", p.lastSeen.UTC().Format(time.RFC822)),
			Action: "Start the provider with `darkbloom start` or check the machine/network.",
		})
	}
	if providerVersion != "" && minVersion != "" && semver.Compare(providerVersion, minVersion) < 0 {
		out = append(out, AlertReason{
			Key:    alertReasonVersionBelowMin,
			Title:  "Provider update required",
			Detail: fmt.Sprintf("This machine is on v%s; the coordinator requires v%s or newer.", p.version, n.cfg.Alerts.MinProviderVersion),
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
	}
	if p.status != registry.StatusUntrusted && p.failedChallenges < registry.MaxFailedChallenges && trustRank(p.trustLevel) < trustRank(n.registry.MinTrustLevel) {
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
	text := buildTextEmail(name, reasons, n.cfg.Alerts.ConsoleURL)
	htmlBody := buildHTMLEmail(name, reasons, n.cfg.Alerts.ConsoleURL)
	return Email{
		From:           n.cfg.Email.From,
		To:             to,
		Subject:        subject,
		Text:           text,
		HTML:           htmlBody,
		UnsubscribeURL: n.cfg.Alerts.UnsubscribeURL,
	}
}

func semverCanonical(v string) string {
	v = "v" + strings.TrimPrefix(strings.TrimSpace(v), "v")
	if v == "v" || !semver.IsValid(v) {
		return ""
	}
	return v
}
