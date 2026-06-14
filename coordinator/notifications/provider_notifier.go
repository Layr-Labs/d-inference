package notifications

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
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
	maxConcurrentEmailSends  = 8
)

type providerStableKey string

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
	stableKey providerStableKey
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
	sent := n.sendDueBatch(checkCtx, candidates, dueByCheck, len(checks))
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
	seen := make(map[providerStableKey]struct{}, len(targets))
	assessor := n.healthAssessor()
	now := time.Now()
	for _, target := range targets {
		candidate, ok := n.alertCandidate(target, assessor, now)
		if !ok {
			continue
		}
		if _, ok := seen[candidate.stableKey]; ok {
			continue
		}
		checks = append(checks, candidate.checks...)
		candidates = append(candidates, candidate)
		seen[candidate.stableKey] = struct{}{}
	}
	return candidates, checks
}

func (n *ProviderNotifier) alertCandidate(target store.ProviderNotificationTarget, assessor providerHealthAssessor, now time.Time) (providerAlertCandidate, bool) {
	rec := target.Provider
	if rec.AccountID == "" || target.Email == "" {
		return providerAlertCandidate{}, false
	}
	stableKey := providerStableKey(store.ProviderNotificationStableKey(rec))
	state := providerStateFrom(rec, n.registry.GetProvider(rec.ID))
	reasons := assessor.reasons(state, now)
	if len(reasons) == 0 {
		return providerAlertCandidate{}, false
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
			ProviderID: string(stableKey),
			AccountID:  state.accountID,
			ReasonKey:  reason.Key,
		}
		candidate.reasons = append(candidate.reasons, reason)
		candidate.checks = append(candidate.checks, check)
	}
	if len(candidate.checks) == 0 {
		return providerAlertCandidate{}, false
	}
	return candidate, true
}

func (n *ProviderNotifier) sendDueBatch(
	ctx context.Context,
	candidates []providerAlertCandidate,
	dueByCheck store.ProviderNotificationDueSet,
	sentCapacity int,
) []store.ProviderNotificationCheck {
	concurrency := maxConcurrentEmailSends
	if len(candidates) < concurrency {
		concurrency = len(candidates)
	}
	if concurrency == 0 {
		return nil
	}
	results := make(chan []store.ProviderNotificationCheck, len(candidates))
	work := make(chan providerAlertCandidate)
	var wg sync.WaitGroup
	for i := 0; i < concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for candidate := range work {
				results <- n.sendDue(ctx, candidate, dueByCheck)
			}
		}()
	}
	for _, candidate := range candidates {
		work <- candidate
	}
	close(work)
	wg.Wait()
	close(results)
	sent := make([]store.ProviderNotificationCheck, 0, sentCapacity)
	for checks := range results {
		sent = append(sent, checks...)
	}
	return sent
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

func (n *ProviderNotifier) healthAssessor() providerHealthAssessor {
	return providerHealthAssessor{
		minProviderVersion: n.cfg.Alerts.MinProviderVersion,
		minTrustLevel:      n.registry.MinTrustLevel,
	}
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
