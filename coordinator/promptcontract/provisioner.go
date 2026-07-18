package promptcontract

import (
	"context"
	"errors"
	"sort"
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
	ModelID          string
	PromptContractID string
	Path             string
	ArtifactReady    bool
	LastError        string
}

type ProvisionCounts struct {
	Ready   int
	Pending int
	Failed  int
}

type Provisioner struct {
	cache         *ArtifactCache
	maxConcurrent int
	maxModels     int
	context       context.Context
	cancel        context.CancelFunc

	mu         sync.RWMutex
	generation uint64
	runCancel  context.CancelFunc
	statuses   map[string]ProvisionStatus
	closed     bool
	wg         sync.WaitGroup
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
		return ErrInvalidConfig
	}
	copied := make([]Manifest, len(manifests))
	copy(copied, manifests)
	seen := make(map[string]bool, len(copied))
	statuses := make(map[string]ProvisionStatus, len(copied))
	for _, manifest := range copied {
		if manifest.ModelID == "" || seen[manifest.ModelID] {
			return ErrInvalidArtifact
		}
		seen[manifest.ModelID] = true
		artifacts, err := PromptArtifacts(manifest.Files)
		if err != nil {
			return err
		}
		contractID, err := ContractID(artifacts, CurrentVersions())
		if err != nil {
			return err
		}
		statuses[manifest.ModelID] = ProvisionStatus{
			ModelID:          manifest.ModelID,
			PromptContractID: contractID,
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
	p.wg.Add(1)
	p.mu.Unlock()

	go p.run(runContext, generation, copied)
	return nil
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
	defer p.mu.Unlock()
	if generation != p.generation {
		return
	}
	status, ok := p.statuses[modelID]
	if !ok {
		return
	}
	status.Path = contractPath
	status.ArtifactReady = err == nil
	if err != nil && !errors.Is(err, context.Canceled) {
		status.LastError = err.Error()
	}
	p.statuses[modelID] = status
}
