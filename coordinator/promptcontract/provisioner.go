package promptcontract

import (
	"context"
	"errors"
	"log/slog"
	"sort"
	"strings"
	"sync"
)

const (
	defaultProvisionConcurrency = 2
	defaultProvisionMaxModels   = 128
)

type ProvisionerConfig struct {
	MaxConcurrent int
	MaxModels     int
}

type ProvisionStatus struct {
	ModelID              string
	PromptContractID     string
	ModelAggregateSHA256 string
	Path                 string
	ArtifactReady        bool
	LastError            string
}

type ProvisionCounts struct {
	Ready   int
	Pending int
	Failed  int
}

// ProvisionSnapshot is a bounded, privacy-safe handoff from artifact
// provisioning to sidecar preloading. Contract IDs are public artifact
// identities; model IDs, paths, URLs, and error strings are intentionally
// omitted.
type ProvisionSnapshot struct {
	Generation  uint64
	Counts      ProvisionCounts
	ContractIDs []string
}

type Provisioner struct {
	cache         *ArtifactCache
	maxConcurrent int
	maxModels     int
	context       context.Context
	cancel        context.CancelFunc

	mu           sync.RWMutex
	generation   uint64
	runCancel    context.CancelFunc
	statuses     map[string]ProvisionStatus
	catalogError string
	closed       bool
	wg           sync.WaitGroup
}

func NewProvisioner(
	parent context.Context,
	cache *ArtifactCache,
	config ProvisionerConfig,
) (*Provisioner, error) {
	if cache == nil {
		return nil, ErrInvalidConfig
	}
	if config.MaxConcurrent <= 0 {
		config.MaxConcurrent = defaultProvisionConcurrency
	}
	if config.MaxModels <= 0 {
		config.MaxModels = defaultProvisionMaxModels
	}
	if config.MaxConcurrent > config.MaxModels {
		config.MaxConcurrent = config.MaxModels
	}
	ctx, cancel := context.WithCancel(parent)
	return &Provisioner{
		cache:         cache,
		maxConcurrent: config.MaxConcurrent,
		maxModels:     config.MaxModels,
		context:       ctx,
		cancel:        cancel,
		statuses:      make(map[string]ProvisionStatus),
	}, nil
}

// Reconcile cancels obsolete catalog work and starts a bounded background
// provisioning pass. It never waits for downloads and is not on the inference
// path.
func (p *Provisioner) Reconcile(manifests []Manifest) error {
	if len(manifests) > p.maxModels {
		return p.rejectCatalog(ErrInvalidConfig)
	}
	copied := make([]Manifest, len(manifests))
	copy(copied, manifests)
	seen := make(map[string]bool, len(copied))
	statuses := make(map[string]ProvisionStatus, len(copied))
	for _, manifest := range copied {
		if manifest.ModelID == "" || seen[manifest.ModelID] {
			return p.rejectCatalog(ErrInvalidArtifact)
		}
		seen[manifest.ModelID] = true
		artifacts, err := PromptArtifacts(manifest.Files)
		if err != nil {
			return p.rejectCatalog(err)
		}
		contractID, err := ContractID(artifacts, CurrentVersions())
		if err != nil {
			return p.rejectCatalog(err)
		}
		statuses[manifest.ModelID] = ProvisionStatus{
			ModelID:              manifest.ModelID,
			PromptContractID:     contractID,
			ModelAggregateSHA256: strings.ToLower(strings.TrimSpace(manifest.AggregateSHA256)),
		}
	}

	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return context.Canceled
	}
	if p.runCancel != nil {
		p.runCancel()
	}
	runContext, runCancel := context.WithCancel(p.context)
	p.runCancel = runCancel
	p.generation++
	generation := p.generation
	p.statuses = statuses
	p.catalogError = ""
	p.wg.Add(1)
	p.mu.Unlock()

	go p.run(runContext, generation, copied)
	return nil
}

// rejectCatalog advances the handoff generation and removes every previously
// ready model. A malformed replacement catalog must fail closed instead of
// leaving the old prompt contract eligible indefinitely.
func (p *Provisioner) rejectCatalog(err error) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return context.Canceled
	}
	if p.runCancel != nil {
		p.runCancel()
	}
	p.generation++
	p.statuses = make(map[string]ProvisionStatus)
	p.catalogError = err.Error()
	return err
}

func (p *Provisioner) Status(modelID string) (ProvisionStatus, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	status, ok := p.statuses[modelID]
	return status, ok
}

func (p *Provisioner) Statuses() []ProvisionStatus {
	p.mu.RLock()
	statuses := make([]ProvisionStatus, 0, len(p.statuses))
	for _, status := range p.statuses {
		statuses = append(statuses, status)
	}
	p.mu.RUnlock()
	sort.Slice(statuses, func(i, j int) bool {
		return statuses[i].ModelID < statuses[j].ModelID
	})
	return statuses
}

// Counts returns the bounded aggregate used by rollout status/metrics without
// allocating or exposing per-model status. statuses is capped by maxModels.
func (p *Provisioner) Counts() ProvisionCounts {
	if p == nil {
		return ProvisionCounts{}
	}
	p.mu.RLock()
	defer p.mu.RUnlock()
	var counts ProvisionCounts
	if p.catalogError != "" {
		counts.Failed++
	}
	for _, status := range p.statuses {
		switch {
		case status.ArtifactReady:
			counts.Ready++
		case status.LastError != "":
			counts.Failed++
		default:
			counts.Pending++
		}
	}
	return counts
}

// Snapshot returns the current catalog generation and the sorted, deduplicated
// set of contracts whose artifacts are fully verified. A caller must require
// Pending==0 and Failed==0 before treating ContractIDs as the active preload
// set; partial readiness is never enough to open cache routing.
func (p *Provisioner) Snapshot() ProvisionSnapshot {
	if p == nil {
		return ProvisionSnapshot{}
	}
	p.mu.RLock()
	snapshot := ProvisionSnapshot{Generation: p.generation}
	if p.catalogError != "" {
		snapshot.Counts.Failed++
	}
	contracts := make(map[string]struct{}, len(p.statuses))
	for _, status := range p.statuses {
		switch {
		case status.ArtifactReady:
			snapshot.Counts.Ready++
			if validHash(status.PromptContractID) {
				contracts[status.PromptContractID] = struct{}{}
			} else {
				snapshot.Counts.Ready--
				snapshot.Counts.Failed++
			}
		case status.LastError != "":
			snapshot.Counts.Failed++
		default:
			snapshot.Counts.Pending++
		}
	}
	p.mu.RUnlock()
	snapshot.ContractIDs = make([]string, 0, len(contracts))
	for contractID := range contracts {
		snapshot.ContractIDs = append(snapshot.ContractIDs, contractID)
	}
	sort.Strings(snapshot.ContractIDs)
	return snapshot
}

func (p *Provisioner) Close() {
	p.mu.Lock()
	if !p.closed {
		p.closed = true
		if p.runCancel != nil {
			p.runCancel()
		}
		p.cancel()
	}
	p.mu.Unlock()
	p.wg.Wait()
}

func (p *Provisioner) run(ctx context.Context, generation uint64, manifests []Manifest) {
	defer p.wg.Done()
	jobs := make(chan Manifest)
	var workers sync.WaitGroup
	workers.Add(p.maxConcurrent)
	for range p.maxConcurrent {
		go func() {
			defer workers.Done()
			for manifest := range jobs {
				contractPath, err := p.cache.Ensure(ctx, manifest)
				if errors.Is(err, context.Canceled) && ctx.Err() == nil {
					contractPath, err = p.cache.Ensure(ctx, manifest)
				}
				p.record(generation, manifest.ModelID, contractPath, err)
			}
		}()
	}
	for _, manifest := range manifests {
		select {
		case <-ctx.Done():
			close(jobs)
			workers.Wait()
			return
		case jobs <- manifest:
		}
	}
	close(jobs)
	workers.Wait()
}

func (p *Provisioner) record(generation uint64, modelID, contractPath string, err error) {
	p.mu.Lock()
	if generation != p.generation {
		p.mu.Unlock()
		return
	}
	status, ok := p.statuses[modelID]
	if !ok {
		p.mu.Unlock()
		return
	}
	status.Path = contractPath
	status.ArtifactReady = err == nil
	if err != nil && !errors.Is(err, context.Canceled) {
		status.LastError = boundedStatusError(err.Error())
	}
	p.statuses[modelID] = status
	pending := 0
	failed := 0
	for _, current := range p.statuses {
		switch {
		case current.ArtifactReady:
		case current.LastError != "":
			failed++
		default:
			pending++
		}
	}
	errorText := status.LastError
	modelCount := len(p.statuses)
	p.mu.Unlock()
	if errorText != "" {
		slog.Warn("prompt artifact provisioning failed",
			"catalog_generation", generation,
			"error", errorText,
		)
	}
	if pending == 0 && failed == 0 {
		slog.Info("prompt artifact catalog ready",
			"catalog_generation", generation,
			"models", modelCount,
		)
	}
}
