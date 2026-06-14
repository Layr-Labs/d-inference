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
	plan := n.notificationPlan(targets)
	if len(plan.checks) == 0 {
		return
	}
	dueByCheck, ok := n.notificationsDue(checkCtx, plan.checks)
	if !ok {
		return
	}
	n.recordNotificationsSent(checkCtx, n.sendDueNotifications(checkCtx, plan, dueByCheck))
}

type providerNotificationPlan struct {
	candidates     []providerNotificationCandidate
	checks         []store.ProviderNotificationCheck
	reasonsByCheck []AlertReason
}

func newProviderNotificationPlan(targetCount int) providerNotificationPlan {
	checkCapacity := targetCount * maxProviderAlertReasons
	return providerNotificationPlan{
		candidates:     make([]providerNotificationCandidate, 0, targetCount),
		checks:         make([]store.ProviderNotificationCheck, 0, checkCapacity),
		reasonsByCheck: make([]AlertReason, 0, checkCapacity),
	}
}

func (n *ProviderNotifier) notificationPlan(targets []store.ProviderNotificationTarget) providerNotificationPlan {
	plan := newProviderNotificationPlan(len(targets))
	if len(targets) == 0 {
		return plan
	}
	seen := make(map[string]struct{}, len(targets))
	assessor := n.healthAssessor()
	now := time.Now()
	for _, target := range targets {
		state, stableKey, reasons, ok := n.notificationCandidate(target, assessor, now, seen)
		if !ok {
			continue
		}
		if n.appendNotificationCandidate(&plan, target.Email, state, stableKey, reasons) {
			seen[stableKey] = struct{}{}
		}
	}
	return plan
}

func (n *ProviderNotifier) appendNotificationCandidate(plan *providerNotificationPlan, email string, state providerState, stableKey string, reasons []AlertReason) bool {
	start := len(plan.checks)
	for _, reason := range reasons {
		check := store.ProviderNotificationCheck{
			ProviderID: stableKey,
			AccountID:  state.accountID,
			ReasonKey:  reason.Key,
		}
		if _, _, _, ok := check.DBValues(); !ok {
			continue
		}
		plan.checks = append(plan.checks, check)
		plan.reasonsByCheck = append(plan.reasonsByCheck, reason)
	}
	if start == len(plan.checks) {
		return false
	}
	plan.candidates = append(plan.candidates, providerNotificationCandidate{
		email: email,
		state: state,
		start: start,
		end:   len(plan.checks),
	})
	return true
}

func (n *ProviderNotifier) sendDueNotifications(ctx context.Context, plan providerNotificationPlan, dueByCheck store.ProviderNotificationDueSet) []store.ProviderNotificationCheck {
	sent := make([]store.ProviderNotificationCheck, 0, len(plan.checks))
	for _, candidate := range plan.candidates {
		if ctx.Err() != nil {
			return sent
		}
		reasons := plan.reasonsByCheck[candidate.start:candidate.start]
		sentStart := len(sent)
		for i := candidate.start; i < candidate.end; i++ {
			if dueByCheck.Contains(plan.checks[i]) {
				reasons = append(reasons, plan.reasonsByCheck[i])
				sent = append(sent, plan.checks[i])
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
	assessor providerHealthAssessor,
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
	reasons := assessor.reasons(state, now)
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

func (n *ProviderNotifier) healthAssessor() providerHealthAssessor {
	return providerHealthAssessor{
		minProviderVersion: n.cfg.MinProviderVersion,
		minTrustLevel:      n.registry.MinTrustLevel,
	}
}
