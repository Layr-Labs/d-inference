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

var providerNotificationRuntime = struct {
	heartbeatTimeout      time.Duration
	challengeMaxAge       time.Duration
	checkOperationTimeout time.Duration
	storeOperationTimeout time.Duration
	emailSendTimeout      time.Duration
	maxReasons            int
	maxTargets            int
}{
	heartbeatTimeout:      90 * time.Second,
	challengeMaxAge:       6 * time.Minute,
	checkOperationTimeout: 5 * time.Minute,
	storeOperationTimeout: 10 * time.Second,
	emailSendTimeout:      5 * time.Second,
	maxReasons:            7,
	maxTargets:            1000,
}

type ProviderNotifier struct {
	registry *registry.Registry
	store    store.Store
	send     func(context.Context, Email) error
	cfg      Config
	logger   *slog.Logger
}

type providerAlertCandidate struct {
	email     string
	state     providerState
	stableKey string
	reasons   []AlertReason
}

type ProviderNotifierOption func(*ProviderNotifier)

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

func (k AlertReasonKey) valid() bool {
	switch k {
	case alertReasonOffline,
		alertReasonVersionBelowMin,
		alertReasonRuntimeUnverified,
		alertReasonThermalCritical,
		alertReasonChallengeStale,
		alertReasonUntrusted,
		alertReasonTrustBelowMinimum:
		return true
	}
	return false
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
		send:     resendSender(cfg.Email.APIKey),
		cfg:      cfg,
		logger:   logger,
	}
	for _, opt := range opts {
		opt(notifier)
	}
	return notifier
}

func WithProviderNotificationSender(send func(context.Context, Email) error) ProviderNotifierOption {
	return func(n *ProviderNotifier) {
		n.send = send
	}
}

func resendSender(apiKey string) func(context.Context, Email) error {
	if apiKey == "" {
		return nil
	}
	client := NewResendClient(apiKey)
	if client == nil {
		return nil
	}
	return client.Send
}

func (n *ProviderNotifier) Start(ctx context.Context) {
	if n == nil || !n.cfg.Enabled {
		return
	}
	if n.send == nil {
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
	if n == nil || n.send == nil || n.store == nil || n.registry == nil {
		return
	}
	if ctx.Err() != nil {
		return
	}
	checkCtx, cancel := context.WithTimeout(ctx, providerNotificationRuntime.checkOperationTimeout)
	defer cancel()
	storeCtx, storeCancel := context.WithTimeout(checkCtx, providerNotificationRuntime.storeOperationTimeout)
	targets, err := n.store.ListProviderNotificationTargets(storeCtx)
	storeCancel()
	if err != nil {
		n.logger.Warn("provider notifications: list provider targets failed", "error", err)
		return
	}
	if len(targets) > providerNotificationRuntime.maxTargets {
		targets = targets[:providerNotificationRuntime.maxTargets]
	}
	candidates, checks := n.alertCandidates(targets)
	if len(checks) == 0 {
		return
	}
	storeCtx, storeCancel = context.WithTimeout(checkCtx, providerNotificationRuntime.storeOperationTimeout)
	dueByCheck, err := n.store.ProviderNotificationsDue(storeCtx, checks, n.cfg.AlertCooldown)
	storeCancel()
	if err != nil {
		n.logger.Warn("provider notifications: cooldown lookup failed", "error", err)
		return
	}
	sent := make([]store.ProviderNotificationCheck, 0, cap(checks))
	for _, candidate := range candidates {
		sent = append(sent, n.sendDue(checkCtx, candidate, dueByCheck)...)
	}
	storeCtx, storeCancel = context.WithTimeout(checkCtx, providerNotificationRuntime.storeOperationTimeout)
	err = n.store.RecordProviderNotificationsSent(storeCtx, sent, time.Now())
	storeCancel()
	if err != nil {
		n.logger.Warn("provider notifications: record sends failed", "error", err)
	}
}

func (n *ProviderNotifier) alertCandidates(targets []store.ProviderNotificationTarget) ([]providerAlertCandidate, []store.ProviderNotificationCheck) {
	candidateCapacity := len(targets)
	candidates := make([]providerAlertCandidate, 0, candidateCapacity)
	checkCapacity := candidateCapacity * providerNotificationRuntime.maxReasons
	checks := make([]store.ProviderNotificationCheck, 0, checkCapacity)
	seen := make(map[string]struct{}, len(targets))
	for _, target := range targets {
		rec := target.Provider
		if rec.AccountID == "" || target.Email == "" {
			continue
		}
		stableKey := notificationStableKey(rec)
		if _, ok := seen[stableKey]; ok {
			continue
		}
		state := providerStateFrom(rec, n.registry.GetProvider(rec.ID))
		reasons := n.reasons(state, time.Now())
		if len(reasons) == 0 {
			continue
		}
		candidates = append(candidates, providerAlertCandidate{
			email:     target.Email,
			state:     state,
			stableKey: stableKey,
			reasons:   reasons,
		})
		for _, reason := range reasons {
			if !reason.Key.valid() {
				continue
			}
			checks = append(checks, store.ProviderNotificationCheck{
				ProviderID: stableKey,
				AccountID:  state.accountID,
				ReasonKey:  store.ProviderNotificationReasonKey(reason.Key),
			})
		}
		seen[stableKey] = struct{}{}
	}
	return candidates, checks
}

func (n *ProviderNotifier) sendDue(ctx context.Context, candidate providerAlertCandidate, dueByCheck store.ProviderNotificationDueSet) []store.ProviderNotificationCheck {
	due := make([]AlertReason, 0, len(candidate.reasons))
	sent := make([]store.ProviderNotificationCheck, 0, len(candidate.reasons))
	for _, reason := range candidate.reasons {
		if !reason.Key.valid() {
			continue
		}
		check := store.ProviderNotificationCheck{
			ProviderID: candidate.stableKey,
			AccountID:  candidate.state.accountID,
			ReasonKey:  store.ProviderNotificationReasonKey(reason.Key),
		}
		if dueByCheck.Contains(check) {
			due = append(due, reason)
			sent = append(sent, check)
		}
	}
	if len(due) == 0 {
		return nil
	}
	email := n.buildEmail(candidate.email, candidate.state, due)
	sendCtx, cancel := context.WithTimeout(ctx, providerNotificationRuntime.emailSendTimeout)
	defer cancel()
	if err := n.send(sendCtx, email); err != nil {
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
	out := make([]AlertReason, 0, providerNotificationRuntime.maxReasons)
	if !p.online && now.Sub(p.lastSeen) >= providerNotificationRuntime.heartbeatTimeout {
		out = append(out, AlertReason{
			Key:    alertReasonOffline,
			Title:  "Machine offline",
			Detail: fmt.Sprintf("No heartbeat since %s.", p.lastSeen.UTC().Format(time.RFC822)),
			Action: "Start the provider with `darkbloom start` or check the machine/network.",
		})
	}
	providerVersion := semverCanonical(p.version)
	minVersion := semverCanonical(n.cfg.MinProviderVersion)
	if providerVersion != "" && minVersion != "" && semver.Compare(providerVersion, minVersion) < 0 {
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
	if p.online && p.lastChallengeVerified != nil && p.status != registry.StatusUntrusted && now.Sub(*p.lastChallengeVerified) > providerNotificationRuntime.challengeMaxAge {
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

func semverCanonical(v string) string {
	v = "v" + strings.TrimPrefix(strings.TrimSpace(v), "v")
	if v == "v" || !semver.IsValid(v) {
		return ""
	}
	return v
}
