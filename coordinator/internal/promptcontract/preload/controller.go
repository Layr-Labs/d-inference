package preload

import (
	"context"
	"errors"
	"log/slog"
	"slices"
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

type Catalog interface{ Snapshot() catalog.Snapshot }

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
// The active contract set remains internal so status endpoints cannot become
// an inventory oracle.
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

// A requested identity and its successfully loaded subset are different things.
// Provisioning can grow this exact sorted set without a new catalog generation.
type preloadIdentity struct {
	catalogGeneration uint64
	childGeneration   uint64
	contractIDs       []string
}

func (k preloadIdentity) matches(provisioned catalog.Snapshot, child ChildStatus) bool {
	return k.catalogGeneration == provisioned.Generation &&
		k.childGeneration == child.ChildGeneration && slices.Equal(k.contractIDs, provisioned.ContractIDs)
}

func (k preloadIdentity) equal(other preloadIdentity) bool {
	return k.catalogGeneration == other.catalogGeneration && k.childGeneration == other.childGeneration &&
		slices.Equal(k.contractIDs, other.contractIDs)
}

// PreloadController publishes only acknowledged members of the current verified
// set and child generation. Unrelated provisioning/load failures remain visible
// without suppressing a confirmed member. Ordinary inference never waits here.
type PreloadController struct {
	provisioner Catalog
	supervisor  Child
	client      Client
	config      PreloadControllerConfig

	mu             sync.RWMutex
	status         PreloadControllerStatus
	contracts      map[string]struct{}
	started        bool
	cancel         context.CancelFunc
	wg             sync.WaitGroup
	metricsAt      time.Time
	published      preloadIdentity
	fullyLoaded    bool
	retryIdentity  preloadIdentity
	retryAt        time.Time
	failureBackoff time.Duration
	operation      uint64
	inflight       uint64
	closed         bool
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
	return &PreloadController{
		provisioner: provisioner,
		supervisor:  supervisor,
		client:      client,
		config:      config,
		contracts:   make(map[string]struct{}),
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
	c.cancel = cancel
	c.started = true
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

// ReadyFor is the final per-request gate. It re-reads both upstream
// generations so a catalog update or child restart closes routing immediately,
// even before the controller's next polling tick.
func (c *PreloadController) ReadyFor(promptContractID string) bool {
	if c == nil || !sidecar.ValidHash(promptContractID) {
		return false
	}
	provisioned := c.provisioner.Snapshot()
	child := c.supervisor.Status()
	c.mu.RLock()
	_, included := c.contracts[promptContractID]
	status := c.status
	current := c.published.matches(provisioned, child)
	closed := c.closed
	c.mu.RUnlock()
	return !closed && status.Ready && included && current && child.Running && child.Ready &&
		provisioned.Generation != 0 && child.ChildGeneration != 0 &&
		len(provisioned.ContractIDs) > 0 && len(provisioned.ContractIDs) <= c.client.MaxPreloadIDs() &&
		slices.Contains(provisioned.ContractIDs, promptContractID)
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
	provisioned := c.provisioner.Snapshot()
	child := c.supervisor.Status()
	if provisioned.Generation == 0 {
		c.setUnavailable("awaiting model catalog")
		return
	}
	if !child.Running || child.ChildGeneration == 0 {
		c.setUnavailable("awaiting prompt sidecar")
		return
	}
	if len(provisioned.ContractIDs) == 0 {
		reason := "no verified prompt contracts"
		if provisioned.Counts.Pending != 0 {
			reason = "awaiting prompt artifacts"
		} else if provisioned.Counts.Failed != 0 {
			reason = "prompt artifact provisioning failed"
		}
		// No empty preload is sent: this closes Go participation, not the
		// Rust process's previously accepted set.
		c.setUnavailable(reason)
		return
	}

	key := preloadIdentity{provisioned.Generation, child.ChildGeneration,
		slices.Clone(provisioned.ContractIDs)}
	token, refresh := c.beginAttempt(key)
	if token == 0 {
		if refresh {
			c.refreshMetrics(ctx)
		}
		return
	}
	// Keep Client's capacity and strict whole-report validation authoritative.
	// An oversized set is rejected before HTTP and retains failed-batch counts.
	report, err := c.client.Preload(ctx, key.contractIDs)
	var successful []string
	if err == nil {
		for _, result := range report.Results {
			if result.Status == "warm" || result.Status == "cold" {
				successful = append(successful, result.PromptContractID)
			}
		}
		if !report.Ready && len(successful) > 0 {
			// Old Rust stays globally degraded after a partial batch. The
			// Supervisor's cached ready bit can still describe the old batch.
			ready, readyErr := c.client.Ready(ctx)
			if readyErr != nil {
				err = readyErr
			} else if !ready {
				err = sidecar.ErrPreloadRejected
			}
		}
	}
	latestProvisioned := c.provisioner.Snapshot()
	latestChild := c.supervisor.Status()
	c.finishAttempt(ctx, key, token, report, successful, err, latestProvisioned, latestChild)
}

// beginAttempt serializes real operations, but does not hold mu across network
// work. Backoff and published successes are separate: an unchanged partial set
// remains usable while its failed members wait for the next attempt.
func (c *PreloadController) beginAttempt(key preloadIdentity) (uint64, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.inflight != 0 {
		return 0, false
	}
	if !c.retryIdentity.equal(key) {
		c.resetRetryLocked()
	}
	if c.status.Ready && c.fullyLoaded && c.published.equal(key) {
		return 0, true
	}
	if c.retryIdentity.equal(key) && !c.retryAt.IsZero() && time.Now().Before(c.retryAt) {
		return 0, false
	}
	if !c.advanceOperationLocked() {
		return 0, false
	}
	c.inflight = c.operation
	c.clearPublicationLocked("preload in progress")
	return c.inflight, false
}

func (c *PreloadController) finishAttempt(
	ctx context.Context, key preloadIdentity, token uint64,
	report sidecar.PreloadReport, successful []string, err error,
	provisioned catalog.Snapshot, child ChildStatus,
) {
	c.mu.Lock()
	if c.inflight != token {
		c.mu.Unlock()
		return
	}
	c.inflight = 0
	conflict := err != nil && isPreloadConflict(err)
	failed := err != nil || !report.Ready
	// Preserve the returned-error/rejected-batch population, including a
	// partial batch whose subsequent readiness confirmation also failed.
	if failed && !conflict {
		c.status.Failures++
	}
	if c.closed || ctx.Err() != nil || c.operation != token ||
		!child.Running || child.ChildGeneration == 0 ||
		!key.matches(provisioned, child) {
		c.clearPublicationLocked("preload identity changed or stopped")
		c.resetRetryLocked()
		c.mu.Unlock()
		return
	}
	if conflict {
		c.clearPublicationLocked("sidecar preload already in progress")
		c.mu.Unlock()
		return
	}

	previouslyFailed := c.failureBackoff != 0
	if failed {
		c.recordRetryLocked(key)
		c.status.LastError = catalog.BoundedStatusError(sidecar.ErrPreloadRejected.Error())
		if err != nil {
			c.status.LastError = catalog.BoundedStatusError(err.Error())
		}
	} else {
		c.resetRetryLocked()
		c.status.LastError = ""
	}
	// A transport/unknown-readiness failure cannot restore the old subset.
	if err == nil && len(successful) > 0 {
		c.contracts = make(map[string]struct{}, len(successful))
		for _, contractID := range successful {
			c.contracts[contractID] = struct{}{}
		}
		c.published = key
		c.fullyLoaded = report.Ready
		c.status.Ready = true
		c.status.CatalogGeneration = key.catalogGeneration
		c.status.ChildGeneration = key.childGeneration
		c.status.ContractCount = len(successful)
		if report.Ready {
			c.status.Runs++
		}
		c.status.Warm += uint64(report.Warm)
		c.status.Cold += uint64(report.Cold)
		c.metricsAt = time.Now()
	}
	backoff, errorText := c.failureBackoff, c.status.LastError
	c.mu.Unlock()

	if failed {
		slog.Warn("prompt sidecar active-set preload failed",
			"catalog_generation", key.catalogGeneration,
			"child_generation", key.childGeneration,
			"retry_in", backoff.String(), "error", errorText)
	} else if previouslyFailed {
		slog.Info("prompt sidecar active-set preload recovered",
			"catalog_generation", key.catalogGeneration,
			"child_generation", key.childGeneration, "contracts", len(successful))
	}
}

func (c *PreloadController) clearPublicationLocked(reason string) {
	c.status.Ready = false
	c.status.CatalogGeneration = 0
	c.status.ChildGeneration = 0
	c.status.ContractCount = 0
	c.status.LastError = catalog.BoundedStatusError(reason)
	c.contracts = nil
	c.published = preloadIdentity{}
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
	c.clearPublicationLocked(reason)
	c.resetRetryLocked()
	// Keep an in-flight ticket until its actual caller returns. Invalidating
	// publication must not manufacture another overlapping local operation.
}

func (c *PreloadController) setUnavailable(reason string) {
	c.mu.Lock()
	c.invalidateLocked(reason)
	c.mu.Unlock()
}

func (c *PreloadController) recordRetryLocked(key preloadIdentity) {
	if !c.retryIdentity.equal(key) || c.failureBackoff == 0 {
		c.failureBackoff = c.config.FailureBackoffMin
	} else if c.failureBackoff >= c.config.FailureBackoffMax/2 {
		c.failureBackoff = c.config.FailureBackoffMax
	} else {
		c.failureBackoff *= 2
	}
	c.retryIdentity = key
	c.retryAt = time.Now().Add(c.failureBackoff)
}

func (c *PreloadController) resetRetryLocked() {
	c.retryIdentity = preloadIdentity{}
	c.retryAt = time.Time{}
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
