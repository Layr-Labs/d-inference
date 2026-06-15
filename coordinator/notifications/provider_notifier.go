package notifications

import (
	"context"
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
	maxProviderAlertReasons  = 7
	maxProviderAlertTargets  = 1000
)

type providerThermalState string

const thermalStateCritical providerThermalState = "critical"

type ProviderNotifier struct {
	registry *registry.Registry
	store    store.Store
	sender   EmailSender
	cfg      Config
	logger   *slog.Logger
}

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

type providerState struct {
	id                    string
	accountID             string
	serial                string
	version               string
	status                registry.ProviderStatus
	trustLevel            registry.TrustLevel
	runtimeVerified       bool
	thermalState          providerThermalState
	lastSeen              time.Time
	lastChallengeVerified *time.Time
	failedChallenges      int
	online                bool
}

func NewProviderNotifier(reg *registry.Registry, st store.Store, cfg Config, logger *slog.Logger, sender EmailSender) *ProviderNotifier {
	if logger == nil {
		logger = slog.Default()
	}
	cfg = cfg.WithDefaults()
	notifier := &ProviderNotifier{
		registry: reg,
		store:    st,
		cfg:      cfg,
		logger:   logger,
	}
	if sender != nil {
		notifier.sender = sender
	} else if cfg.APIKey != "" {
		if client, err := NewResendClient(cfg.APIKey); err != nil {
			logger.Warn("provider email notifications enabled but email client configuration is invalid")
		} else {
			notifier.sender = client
		}
	}
	return notifier
}

func (n *ProviderNotifier) Start(ctx context.Context) {
	if n == nil || !n.cfg.Enabled {
		return
	}
	if n.sender == nil {
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
	candidates, checks, reasonsByCheck := n.notificationCandidates(targets)
	if len(checks) == 0 {
		return
	}
	dueByCheck, ok := n.notificationsDue(checkCtx, checks)
	if !ok {
		return
	}
	n.recordNotificationsSent(checkCtx, n.sendDueNotifications(checkCtx, candidates, checks, reasonsByCheck, dueByCheck))
}

func (n *ProviderNotifier) notificationCandidates(targets []store.ProviderNotificationTarget) ([]providerNotificationCandidate, []store.ProviderNotificationCheck, []AlertReason) {
	checkCapacity := len(targets) * maxProviderAlertReasons
	candidates := make([]providerNotificationCandidate, 0, len(targets))
	checks := make([]store.ProviderNotificationCheck, 0, checkCapacity)
	reasonsByCheck := make([]AlertReason, 0, checkCapacity)
	if len(targets) == 0 {
		return candidates, checks, reasonsByCheck
	}
	seen := make(map[string]struct{}, len(targets))
	now := time.Now()
	for _, target := range targets {
		state, stableKey, reasons, ok := n.notificationCandidate(target, now, seen)
		if !ok {
			continue
		}
		start := len(checks)
		checks, reasonsByCheck = appendNotificationChecks(checks, reasonsByCheck, stableKey, state.accountID, reasons)
		if start < len(checks) {
			candidates = append(candidates, providerNotificationCandidate{
				email: target.Email,
				state: state,
				start: start,
				end:   len(checks),
			})
			seen[stableKey] = struct{}{}
		}
	}
	return candidates, checks, reasonsByCheck
}

func appendNotificationChecks(
	checks []store.ProviderNotificationCheck,
	reasonsByCheck []AlertReason,
	stableKey string,
	accountID string,
	reasons []AlertReason,
) ([]store.ProviderNotificationCheck, []AlertReason) {
	for _, reason := range reasons {
		check := store.ProviderNotificationCheck{
			ProviderID: stableKey,
			AccountID:  accountID,
			ReasonKey:  reason.Key,
		}
		if _, _, _, ok := check.DBValues(); !ok {
			continue
		}
		checks = append(checks, check)
		reasonsByCheck = append(reasonsByCheck, reason)
	}
	return checks, reasonsByCheck
}

func (n *ProviderNotifier) sendDueNotifications(
	ctx context.Context,
	candidates []providerNotificationCandidate,
	checks []store.ProviderNotificationCheck,
	reasonsByCheck []AlertReason,
	dueByCheck store.ProviderNotificationDueSet,
) []store.ProviderNotificationCheck {
	sent := make([]store.ProviderNotificationCheck, 0, len(checks))
	for _, candidate := range candidates {
		if ctx.Err() != nil {
			return sent
		}
		if candidate.start < 0 || candidate.start > candidate.end ||
			candidate.end > len(checks) || candidate.end > len(reasonsByCheck) {
			continue
		}
		reasons := make([]AlertReason, 0, candidate.end-candidate.start)
		sentStart := len(sent)
		for i := candidate.start; i < candidate.end; i++ {
			if dueByCheck.Contains(checks[i]) {
				reasons = append(reasons, reasonsByCheck[i])
				sent = append(sent, checks[i])
			}
		}
		if len(reasons) == 0 {
			continue
		}
		if !n.sendAlertEmail(ctx, candidate.email, candidate.state, reasons) {
			sent = sent[:sentStart]
		}
	}
	return sent
}

type providerNotificationCandidate struct {
	email string
	state providerState
	start int
	end   int
}

func (n *ProviderNotifier) notificationCandidate(
	target store.ProviderNotificationTarget,
	now time.Time,
	seen map[string]struct{},
) (providerState, string, []AlertReason, bool) {
	rec := target.Provider
	if rec.AccountID == "" || target.Email == "" {
		return providerState{}, "", nil, false
	}
	stableKey := store.ProviderNotificationStableKey(rec)
	if _, ok := seen[stableKey]; ok {
		return providerState{}, "", nil, false
	}
	state := providerStateFrom(rec, n.registry.GetProvider(rec.ID))
	reasons := assessProviderHealth(state, now, n.cfg.MinProviderVersion, n.registry.MinTrustLevel)
	if len(reasons) == 0 {
		return providerState{}, "", nil, false
	}
	return state, stableKey, reasons, true
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
	dueByCheck, err := n.store.ProviderNotificationsDue(storeCtx, checks, n.cfg.AlertCooldown)
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

func (n *ProviderNotifier) sendAlertEmail(
	ctx context.Context,
	to string,
	state providerState,
	reasons []AlertReason,
) bool {
	email := buildProviderAlertEmail(n.cfg.From, to, providerDisplayName(state), reasons, n.cfg.ConsoleURL, n.cfg.UnsubscribeURL)
	sendCtx, cancel := context.WithTimeout(ctx, emailSendTimeout)
	defer cancel()
	if err := n.sender.Send(sendCtx, email); err != nil {
		n.logger.Warn("provider notifications: email send failed",
			"provider_id", state.id,
			"serial", state.serial,
			"error", err,
		)
		return false
	}
	n.logger.Info("sent provider owner notification",
		"provider_id", state.id,
		"account_id", state.accountID,
		"reasons", reasonKeys(reasons),
	)
	return true
}
