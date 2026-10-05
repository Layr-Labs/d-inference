package preload

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	sidecar "github.com/eigeninference/d-inference/coordinator/internal/promptcontract/sidecar"
)

const (
	defaultPreloadPollInterval = 250 * time.Millisecond
	defaultMetricsPollInterval = 5 * time.Second
	defaultFailureBackoffMin   = time.Second
	defaultFailureBackoffMax   = time.Minute
)

type Catalog interface {
	VerifiedPreloadArtifacts() (catalog.Snapshot, []VerifiedPreloadArtifact)
}

type ChildStatus struct {
	Running, Ready  bool
	ChildGeneration uint64
}
type Child interface{ Status() ChildStatus }

type Client interface {
	Preload(context.Context, []string) (sidecar.PreloadReport, error)
	Ready(context.Context) (bool, error)
	Metrics(context.Context) (sidecar.SidecarStatus, error)
	MaxPreloadIDs() int
}

type PreloadControllerConfig struct {
	PollInterval      time.Duration
	MetricsInterval   time.Duration
	FailureBackoffMin time.Duration
	FailureBackoffMax time.Duration
}

// PreloadControllerStatus contains only bounded aggregate operational state.
// ContractCount is acknowledged S, never selected D or verified V.
type PreloadControllerStatus struct {
	Ready             bool   `json:"ready"`
	CatalogGeneration uint64 `json:"catalog_generation"`
	ChildGeneration   uint64 `json:"child_generation"`
	ContractCount     int    `json:"contract_count"`
	Runs              uint64 `json:"runs"`
	Failures          uint64 `json:"failures"`
	Warm              uint64 `json:"warm"`
	Cold              uint64 `json:"cold"`
	LastError         string `json:"last_error,omitempty"`
}

// PreloadController publishes only acknowledged members of the exact current
// verified/selected identity and child. Requests never wait for preloading.
type PreloadController struct {
	provisioner Catalog
	supervisor  Child
	client      Client
	config      PreloadControllerConfig

	captureMu       sync.Mutex // Detached input capture through application only; never preload IO.
	mu              sync.RWMutex
	status          PreloadControllerStatus
	contracts       map[string]struct{}
	started         bool
	cancel          context.CancelFunc
	wg              sync.WaitGroup
	metricsAt       time.Time
	published       PreloadSelectionSnapshot
	fullyLoaded     bool
	retryIdentity   PreloadSelectionSnapshot
	failureBackoff  time.Duration
	operation       uint64
	inflight        uint64
	closed          bool
	selection       *preloadActiveSet
	selectionSource PreloadSelectionSource
	policyNow       func() time.Duration // Invoked only inside mu, never captured before waiting.
	publicAvailable []string             // Bounded advisory IDs; refreshed only by background reconcile.
}

func New(
	provisioner Catalog,
	supervisor Child,
	client Client,
	config PreloadControllerConfig,
) (*PreloadController, error) {
	if provisioner == nil || supervisor == nil || client == nil {
		return nil, catalog.ErrInvalidConfig
	}
	if config.PollInterval <= 0 {
		config.PollInterval = defaultPreloadPollInterval
	}
	if config.MetricsInterval <= 0 {
		config.MetricsInterval = defaultMetricsPollInterval
	}
	if config.FailureBackoffMin <= 0 {
		config.FailureBackoffMin = defaultFailureBackoffMin
	}
	if config.FailureBackoffMax <= 0 {
		config.FailureBackoffMax = defaultFailureBackoffMax
	}
	if config.FailureBackoffMax < config.FailureBackoffMin {
		return nil, catalog.ErrInvalidConfig
	}
	origin := time.Now()
	return &PreloadController{
		provisioner: provisioner, supervisor: supervisor, client: client,
		config: config, contracts: make(map[string]struct{}), selection: newPreloadActiveSet(),
		policyNow: func() time.Duration { return time.Since(origin) },
	}, nil
}

func (c *PreloadController) Start(parent context.Context) {
	if c == nil {
		return
	}
	c.mu.Lock()
	if c.started || c.closed {
		c.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(parent)
	c.cancel, c.started = cancel, true
	c.wg.Add(1)
	c.mu.Unlock()
	go c.run(ctx)
}

func (c *PreloadController) Close() {
	if c == nil {
		return
	}
	c.mu.Lock()
	c.closed = true
	c.invalidateLocked("controller stopped")
	cancel := c.cancel
	c.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	c.wg.Wait()
}

func (c *PreloadController) Status() PreloadControllerStatus {
	if c == nil {
		return PreloadControllerStatus{}
	}
	c.mu.RLock()
	status := c.status
	c.mu.RUnlock()
	return status
}

func (c *PreloadController) run(ctx context.Context) {
	defer c.wg.Done()
	ticker := time.NewTicker(c.config.PollInterval)
	defer ticker.Stop()
	c.Reconcile(ctx)
	for {
		select {
		case <-ctx.Done():
			c.setUnavailable("controller stopped")
			return
		case <-ticker.C:
			c.Reconcile(ctx)
		}
	}
}

// Reconcile performs one active-set preload pass on the background owner.
func (c *PreloadController) Reconcile(ctx context.Context) {
	if ctx.Err() != nil {
		c.setUnavailable("controller stopped")
		return
	}
	lease, token, refresh := c.prepareAttempt()
	if token == 0 {
		if refresh {
			c.refreshMetrics(ctx)
		}
		return
	}
	// The unchanged Client retains its exclusive all-permit replacement and
	// strict capacity/report validation. D is nonempty and never exceeds C.
	report, err := c.client.Preload(ctx, lease.key.Desired)
	var successful []string
	if err == nil {
		for _, result := range report.Results {
			if result.Status == "warm" || result.Status == "cold" {
				successful = append(successful, result.PromptContractID)
			}
		}
		if !report.Ready && len(successful) > 0 {
			ready, readyErr := c.client.Ready(ctx)
			if readyErr != nil {
				err = readyErr
			} else if !ready {
				err = sidecar.ErrPreloadRejected
			}
		}
	}
	c.finishAttempt(ctx, lease, token, report, successful, err)
}

func (c *PreloadController) prepareAttempt() (preloadSelectionLease, uint64, bool) {
	c.captureMu.Lock()
	defer c.captureMu.Unlock()
	provisioned, child, input := c.selectionInput(true)
	c.mu.Lock()
	defer c.mu.Unlock()
	key, valid := c.reconcileSelectionLocked(input)
	if c.closed || !valid {
		return preloadSelectionLease{}, 0, false
	}
	if !child.Running || child.ChildGeneration == 0 || len(key.Desired) == 0 {
		c.clearPublicationLocked(preloadUnavailableReason(provisioned, child, c.selection.reason()))
		return preloadSelectionLease{}, 0, false
	}
	if c.inflight != 0 {
		return preloadSelectionLease{}, 0, false
	}
	// No new native load is needed for completed full acknowledgement across
	// only admissibility drift. Participation still uses current exact policy.
	if c.status.Ready && c.fullyLoaded && c.published.nativeEqual(key) {
		return preloadSelectionLease{}, 0, true
	}
	if c.operation == ^uint64(0) {
		c.advanceOperationLocked()
		return preloadSelectionLease{}, 0, false
	}
	lease, admitted := c.selection.beginAttempt(c.policyNow())
	if !admitted {
		return preloadSelectionLease{}, 0, false
	}
	c.advanceOperationLocked()
	c.inflight = c.operation
	c.clearPublicationLocked("preload in progress")
	return lease, c.inflight, false
}

type preloadCompletionDiagnostic struct {
	failed, recovered            bool
	catalog, child               uint64
	verified, desired, contracts int
	backoff                      time.Duration
	reason                       string
}

func (c *PreloadController) finishAttempt(
	ctx context.Context, lease preloadSelectionLease, token uint64,
	report sidecar.PreloadReport, successful []string, err error,
) {
	c.captureMu.Lock()
	_, child, latest := c.selectionInput(false)
	c.mu.Lock()
	diagnostic := c.finishAttemptLocked(ctx, lease, token, report, successful, err, latest, child)
	c.mu.Unlock()
	c.captureMu.Unlock()
	if diagnostic.failed {
		slog.Warn("prompt sidecar active-set preload failed",
			"catalog_generation", diagnostic.catalog, "child_generation", diagnostic.child,
			"retry_in", diagnostic.backoff.String(), "reason", diagnostic.reason,
			"verified", diagnostic.verified, "desired", diagnostic.desired,
			"deferred", max(0, diagnostic.verified-diagnostic.desired))
	} else if diagnostic.recovered {
		slog.Info("prompt sidecar active-set preload recovered",
			"catalog_generation", diagnostic.catalog, "child_generation", diagnostic.child,
			"contracts", diagnostic.contracts)
	}
}

func (c *PreloadController) finishAttemptLocked(
	ctx context.Context, lease preloadSelectionLease, token uint64,
	report sidecar.PreloadReport, successful []string, err error,
	latest PreloadSelectionInput, child ChildStatus,
) preloadCompletionDiagnostic {
	if c.inflight != token {
		return preloadCompletionDiagnostic{}
	}
	c.inflight = 0
	key, current := c.reconcileSelectionLocked(latest)
	conflict := err != nil && isPreloadConflict(err)
	failed := err != nil || !report.Ready
	if failed && !conflict {
		c.status.Failures++
	}
	if c.closed || ctx.Err() != nil || c.operation != token || !current ||
		!child.Running || child.ChildGeneration == 0 || !lease.key.equal(key) {
		// Consume only this real callback, without publishing old S. The policy
		// retains any observed key/ABA invalidation until this exact retirement.
		c.selection.retireConflict(c.policyNow(), lease)
		c.clearPublicationLocked("preload identity changed or stopped")
		c.resetRetryLocked()
		return preloadCompletionDiagnostic{}
	}
	if conflict {
		c.selection.retireConflict(c.policyNow(), lease)
		c.clearPublicationLocked("sidecar preload already in progress")
		return preloadCompletionDiagnostic{}
	}
	previouslyFailed := c.failureBackoff != 0
	if failed {
		c.recordRetryLocked(key)
	} else {
		c.resetRetryLocked()
	}
	if err != nil {
		successful = nil
	}
	backoff := c.failureBackoff
	if backoff == 0 {
		backoff = c.config.FailureBackoffMin // Defensive invalid reports still fail closed.
	}
	accepted := c.selection.completeAttempt(c.policyNow(), lease, successful, backoff)
	if !accepted {
		c.clearPublicationLocked("preload_failed")
		return preloadCompletionDiagnostic{}
	}
	acknowledged := c.selection.successes()
	c.status.LastError = c.selection.reason()
	if err == nil && len(acknowledged) > 0 {
		c.contracts = make(map[string]struct{}, len(acknowledged))
		for _, id := range acknowledged {
			c.contracts[id] = struct{}{}
		}
		c.published = key
		c.fullyLoaded = report.Ready
		c.status.Ready = true
		c.status.CatalogGeneration = key.CatalogGeneration
		c.status.ChildGeneration = key.ChildGeneration
		c.status.ContractCount = len(acknowledged)
		if report.Ready {
			c.status.Runs++
		}
		c.status.Warm += uint64(report.Warm)
		c.status.Cold += uint64(report.Cold)
		c.metricsAt = time.Now()
	}
	return preloadCompletionDiagnostic{failed: failed, recovered: previouslyFailed,
		catalog: key.CatalogGeneration, child: key.ChildGeneration,
		verified: len(preloadContracts(key.Verified)), desired: len(key.Desired), contracts: len(acknowledged),
		backoff: c.failureBackoff, reason: c.status.LastError}
}

func (c *PreloadController) clearPublicationLocked(reason string) {
	c.status.Ready = false
	c.status.CatalogGeneration = 0
	c.status.ChildGeneration = 0
	c.status.ContractCount = 0
	c.status.LastError = catalog.BoundedStatusError(reason)
	c.contracts = nil
	c.published = PreloadSelectionSnapshot{}
	c.fullyLoaded = false
}

func (c *PreloadController) advanceOperationLocked() bool {
	if c.operation == ^uint64(0) {
		c.closed = true
		c.clearPublicationLocked("preload operation generation exhausted")
		return false
	}
	c.operation++
	return true
}

func (c *PreloadController) invalidateLocked(reason string) {
	c.advanceOperationLocked()
	c.selection.invalidate()
	c.clearPublicationLocked(reason)
	c.resetRetryLocked()
	// Keep both in-flight tickets until their actual caller returns.
}

func (c *PreloadController) setUnavailable(reason string) {
	c.mu.Lock()
	c.invalidateLocked(reason)
	c.mu.Unlock()
}

func (c *PreloadController) recordRetryLocked(key PreloadSelectionSnapshot) {
	if !c.retryIdentity.equal(key) || c.failureBackoff == 0 {
		c.failureBackoff = c.config.FailureBackoffMin
	} else if c.failureBackoff >= c.config.FailureBackoffMax/2 {
		c.failureBackoff = c.config.FailureBackoffMax
	} else {
		c.failureBackoff *= 2
	}
	c.retryIdentity = key
}

func (c *PreloadController) resetRetryLocked() {
	c.retryIdentity = PreloadSelectionSnapshot{}
	c.failureBackoff = 0
}

func (c *PreloadController) refreshMetrics(ctx context.Context) {
	c.mu.RLock()
	due := time.Since(c.metricsAt) >= c.config.MetricsInterval
	c.mu.RUnlock()
	if !due {
		return
	}
	if _, err := c.client.Metrics(ctx); err != nil {
		return
	}
	c.mu.Lock()
	c.metricsAt = time.Now()
	c.mu.Unlock()
}

func isPreloadConflict(err error) bool {
	return errors.Is(err, sidecar.ErrPreloadRejected) && strings.Contains(err.Error(), "HTTP 409")
}
