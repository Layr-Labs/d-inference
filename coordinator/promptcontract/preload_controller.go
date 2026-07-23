package promptcontract

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"time"
)

const (
	defaultPreloadPollInterval = 250 * time.Millisecond
	defaultMetricsPollInterval = 5 * time.Second
	defaultFailureBackoffMin   = time.Second
	defaultFailureBackoffMax   = time.Minute
	maxPreloadStatusErrorBytes = 512
)

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

// PreloadController closes cache routing across both catalog and child process
// generations until the exact verified active contract set has been loaded by
// that child. It never restarts the child and never blocks ordinary inference.
type PreloadController struct {
	provisioner *Provisioner
	supervisor  *Supervisor
	client      *Client
	config      PreloadControllerConfig

	mu                     sync.RWMutex
	status                 PreloadControllerStatus
	contracts              map[string]struct{}
	started                bool
	cancel                 context.CancelFunc
	wg                     sync.WaitGroup
	metricsAt              time.Time
	retryCatalogGeneration uint64
	retryChildGeneration   uint64
	retryAt                time.Time
	failureBackoff         time.Duration
}

func NewPreloadController(
	provisioner *Provisioner,
	supervisor *Supervisor,
	config PreloadControllerConfig,
) (*PreloadController, error) {
	if provisioner == nil || supervisor == nil || supervisor.Client() == nil {
		return nil, ErrInvalidConfig
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
		return nil, ErrInvalidConfig
	}
	return &PreloadController{
		provisioner: provisioner,
		supervisor:  supervisor,
		client:      supervisor.Client(),
		config:      config,
		contracts:   make(map[string]struct{}),
	}, nil
}

func (c *PreloadController) Start(parent context.Context) {
	if c == nil {
		return
	}
	c.mu.Lock()
	if c.started {
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
	if c == nil || !validHash(promptContractID) {
		return false
	}
	provisioned := c.provisioner.Snapshot()
	child := c.supervisor.Status()
	c.mu.RLock()
	_, included := c.contracts[promptContractID]
	status := c.status
	c.mu.RUnlock()
	return status.Ready && included && child.Running && child.Ready &&
		child.ChildGeneration != 0 &&
		status.CatalogGeneration == provisioned.Generation &&
		status.ChildGeneration == child.ChildGeneration &&
		provisioned.Counts.Pending == 0 && provisioned.Counts.Failed == 0
}

func (c *PreloadController) run(ctx context.Context) {
	defer c.wg.Done()
	ticker := time.NewTicker(c.config.PollInterval)
	defer ticker.Stop()
	c.reconcile(ctx)
	for {
		select {
		case <-ctx.Done():
			c.setUnavailable("controller stopped")
			return
		case <-ticker.C:
			c.reconcile(ctx)
		}
	}
}

func (c *PreloadController) reconcile(ctx context.Context) {
	provisioned := c.provisioner.Snapshot()
	child := c.supervisor.Status()
	if provisioned.Generation == 0 {
		c.setUnavailable("awaiting model catalog")
		return
	}
	if provisioned.Counts.Pending != 0 {
		c.setUnavailable("awaiting prompt artifacts")
		return
	}
	if provisioned.Counts.Failed != 0 {
		c.setUnavailable("prompt artifact provisioning failed")
		return
	}
	if !child.Running || child.ChildGeneration == 0 {
		c.setUnavailable("awaiting prompt sidecar")
		return
	}
	if c.retryDeferred(provisioned.Generation, child.ChildGeneration, time.Now()) {
		return
	}
	if c.matches(provisioned, child) {
		c.refreshMetrics(ctx)
		return
	}
	if len(provisioned.ContractIDs) == 0 {
		c.setReady(provisioned.Generation, child.ChildGeneration, nil, PreloadReport{})
		c.refreshMetrics(ctx)
		return
	}

	c.setUnavailable("preload in progress")
	report, err := c.client.Preload(ctx, provisioned.ContractIDs)
	if err != nil {
		if isPreloadConflict(err) {
			c.setUnavailable("sidecar preload already in progress")
			return
		}
		c.recordFailure(err, provisioned.Generation, child.ChildGeneration)
		return
	}
	if !report.Ready {
		c.recordFailure(ErrPreloadRejected, provisioned.Generation, child.ChildGeneration)
		return
	}
	// Discard a successful response from a child or catalog generation that
	// changed while the potentially slow preload was in progress.
	latestProvisioned := c.provisioner.Snapshot()
	latestChild := c.supervisor.Status()
	if latestProvisioned.Generation != provisioned.Generation ||
		latestChild.ChildGeneration != child.ChildGeneration || !latestChild.Running {
		c.setUnavailable("preload generation changed")
		return
	}
	c.setReady(provisioned.Generation, child.ChildGeneration, provisioned.ContractIDs, report)
}

func (c *PreloadController) matches(provisioned ProvisionSnapshot, child SupervisorStatus) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	if !c.status.Ready || c.status.CatalogGeneration != provisioned.Generation ||
		c.status.ChildGeneration != child.ChildGeneration ||
		len(c.contracts) != len(provisioned.ContractIDs) {
		return false
	}
	for _, contractID := range provisioned.ContractIDs {
		if _, ok := c.contracts[contractID]; !ok {
			return false
		}
	}
	return true
}

func (c *PreloadController) setUnavailable(reason string) {
	c.mu.Lock()
	c.status.Ready = false
	c.status.CatalogGeneration = 0
	c.status.ChildGeneration = 0
	c.status.ContractCount = 0
	c.status.LastError = boundedStatusError(reason)
	c.contracts = make(map[string]struct{})
	c.mu.Unlock()
}

func (c *PreloadController) recordFailure(
	err error,
	catalogGeneration, childGeneration uint64,
) {
	errorText := boundedStatusError(err.Error())
	c.mu.Lock()
	if c.retryCatalogGeneration != catalogGeneration ||
		c.retryChildGeneration != childGeneration || c.failureBackoff == 0 {
		c.failureBackoff = c.config.FailureBackoffMin
	} else if c.failureBackoff >= c.config.FailureBackoffMax/2 {
		c.failureBackoff = c.config.FailureBackoffMax
	} else {
		c.failureBackoff *= 2
	}
	c.retryCatalogGeneration = catalogGeneration
	c.retryChildGeneration = childGeneration
	c.retryAt = time.Now().Add(c.failureBackoff)
	c.status.Ready = false
	c.status.CatalogGeneration = 0
	c.status.ChildGeneration = 0
	c.status.ContractCount = 0
	c.status.Failures++
	c.status.LastError = errorText
	c.contracts = make(map[string]struct{})
	backoff := c.failureBackoff
	c.mu.Unlock()
	slog.Warn("prompt sidecar active-set preload failed",
		"catalog_generation", catalogGeneration,
		"child_generation", childGeneration,
		"retry_in", backoff.String(),
		"error", errorText,
	)
}

func (c *PreloadController) retryDeferred(
	catalogGeneration, childGeneration uint64,
	now time.Time,
) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.retryCatalogGeneration != catalogGeneration ||
		c.retryChildGeneration != childGeneration {
		c.resetRetryLocked()
		return false
	}
	return !c.retryAt.IsZero() && now.Before(c.retryAt)
}

func (c *PreloadController) setReady(
	catalogGeneration, childGeneration uint64,
	contractIDs []string,
	report PreloadReport,
) {
	contracts := make(map[string]struct{}, len(contractIDs))
	for _, contractID := range contractIDs {
		contracts[contractID] = struct{}{}
	}
	c.mu.Lock()
	recovered := c.failureBackoff != 0
	c.status.Ready = true
	c.status.CatalogGeneration = catalogGeneration
	c.status.ChildGeneration = childGeneration
	c.status.ContractCount = len(contractIDs)
	if len(contractIDs) > 0 {
		c.status.Runs++
	}
	c.status.Warm += uint64(report.Warm)
	c.status.Cold += uint64(report.Cold)
	c.status.LastError = ""
	c.contracts = contracts
	c.metricsAt = time.Now()
	c.resetRetryLocked()
	c.mu.Unlock()
	if recovered {
		slog.Info("prompt sidecar active-set preload recovered",
			"catalog_generation", catalogGeneration,
			"child_generation", childGeneration,
			"contracts", len(contractIDs),
		)
	}
}

func (c *PreloadController) resetRetryLocked() {
	c.retryCatalogGeneration = 0
	c.retryChildGeneration = 0
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

func boundedStatusError(value string) string {
	value = strings.TrimSpace(value)
	if len(value) <= maxPreloadStatusErrorBytes {
		return value
	}
	return value[:maxPreloadStatusErrorBytes]
}

func isPreloadConflict(err error) bool {
	return errors.Is(err, ErrPreloadRejected) && strings.Contains(err.Error(), "HTTP 409")
}
