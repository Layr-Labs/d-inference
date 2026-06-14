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
	send     func(context.Context, Email) error
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

func NewProviderNotifier(reg *registry.Registry, st store.Store, cfg Config, logger *slog.Logger, send func(context.Context, Email) error) *ProviderNotifier {
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
	if send != nil {
		notifier.send = send
	} else if cfg.APIKey != "" {
		if client, err := NewResendClient(cfg.APIKey); err != nil {
			logger.Warn("provider email notifications enabled but email client configuration is invalid")
		} else {
			notifier.send = client.Send
		}
	}
	return notifier
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
	candidates := make([]providerNotificationCandidate, 0, len(targets))
	checks := make([]store.ProviderNotificationCheck, 0, len(targets)*maxProviderAlertReasons)
	reasonsByCheck := make([]AlertReason, 0, len(targets)*maxProviderAlertReasons)
	seen := make(map[string]struct{}, len(targets))
	assessor := n.healthAssessor()
	now := time.Now()
	for _, target := range targets {
		state, stableKey, reasons, ok := n.notificationCandidate(target, assessor, now, seen)
		if !ok {
			continue
		}
		start := len(checks)
		for _, reason := range reasons {
			check := store.ProviderNotificationCheck{
				ProviderID: stableKey,
				AccountID:  state.accountID,
				ReasonKey:  reason.Key,
			}
			if _, _, _, ok := check.DBValues(); !ok {
				continue
			}
			checks = append(checks, check)
			reasonsByCheck = append(reasonsByCheck, reason)
		}
		if start == len(checks) {
			continue
		}
		candidates = append(candidates, providerNotificationCandidate{
			email: target.Email,
			state: state,
			start: start,
			end:   len(checks),
		})
		seen[stableKey] = struct{}{}
	}
	if len(checks) == 0 {
		return
	}
	dueByCheck, ok := n.notificationsDue(checkCtx, checks)
	if !ok {
		return
	}
	sent := make([]store.ProviderNotificationCheck, 0, len(checks))
	for _, candidate := range candidates {
		if checkCtx.Err() != nil {
			return
		}
		sent = append(sent, n.sendDue(
			checkCtx,
			candidate.email,
			candidate.state,
			reasonsByCheck[candidate.start:candidate.end],
			checks[candidate.start:candidate.end],
			dueByCheck,
		)...)
	}
	n.recordNotificationsSent(checkCtx, sent)
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

func (n *ProviderNotifier) sendDue(
	ctx context.Context,
	to string,
	state providerState,
	reasons []AlertReason,
	checks []store.ProviderNotificationCheck,
	dueByCheck store.ProviderNotificationDueSet,
) []store.ProviderNotificationCheck {
	sent := make([]store.ProviderNotificationCheck, 0, len(checks))
	due := reasons[:0]
	for i, check := range checks {
		if dueByCheck.Contains(check) {
			due = append(due, reasons[i])
			sent = append(sent, check)
		}
	}
	if len(due) == 0 {
		return nil
	}
	email := buildProviderAlertEmail(n.cfg.From, to, providerDisplayName(state), due, n.cfg.ConsoleURL, n.cfg.UnsubscribeURL)
	sendCtx, cancel := context.WithTimeout(ctx, emailSendTimeout)
	defer cancel()
	if err := n.send(sendCtx, email); err != nil {
		n.logger.Warn("provider notifications: email send failed",
			"provider_id", state.id,
			"serial", state.serial,
			"error", err,
		)
		return nil
	}
	n.logger.Info("sent provider owner notification",
		"provider_id", state.id,
		"account_id", state.accountID,
		"reasons", reasonKeys(due),
	)
	return sent
}

func (n *ProviderNotifier) healthAssessor() providerHealthAssessor {
	return providerHealthAssessor{
		minProviderVersion: n.cfg.MinProviderVersion,
		minTrustLevel:      n.registry.MinTrustLevel,
	}
}
