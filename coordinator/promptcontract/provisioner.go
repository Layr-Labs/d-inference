package promptcontract

import (
	"context"
	"errors"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/catalog"
	"github.com/eigeninference/d-inference/coordinator/mediawork"
)

const (
	defaultProvisionConcurrency = 2
	defaultProvisionMaxModels   = 128
)

type ProvisionerConfig struct{ MaxConcurrent, MaxModels int }
type ProvisionStatus = catalog.Status
type ProvisionCounts = catalog.Counts
type ProvisionSnapshot = catalog.Snapshot

type Provisioner struct {
	cache         *ArtifactCache
	maxConcurrent int
	maxModels     int
	context       context.Context
	cancel        context.CancelFunc
	catalog       *catalog.State

	mu        sync.RWMutex
	runCancel context.CancelFunc
	closed    bool
	wg        sync.WaitGroup
}

func NewProvisioner(parent context.Context, cache *ArtifactCache, config ProvisionerConfig) (*Provisioner, error) {
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
	return &Provisioner{cache: cache, maxConcurrent: config.MaxConcurrent, maxModels: config.MaxModels,
		context: ctx, cancel: cancel, catalog: catalog.New()}, nil
}

// Reconcile cancels obsolete catalog work and starts a bounded background
// provisioning pass. It never waits for downloads and is not on the inference path.
func (p *Provisioner) Reconcile(manifests []Manifest) error {
	copied := manifests
	if len(manifests) <= p.maxModels {
		copied = make([]Manifest, len(manifests))
		copy(copied, manifests)
	}
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return context.Canceled
	}
	generation, err := p.catalog.Reconcile(copied, p.maxModels)
	if p.runCancel != nil {
		p.runCancel()
	}
	if err != nil {
		p.mu.Unlock()
		return err
	}
	runContext, runCancel := context.WithCancel(p.context)
	p.runCancel = runCancel
	p.wg.Add(1)
	p.mu.Unlock()
	go p.run(runContext, generation, copied)
	return nil
}

func (p *Provisioner) Status(modelID string) (ProvisionStatus, bool) {
	return p.catalog.Status(modelID)
}
func (p *Provisioner) Statuses() []ProvisionStatus { return p.catalog.Statuses() }
func (p *Provisioner) Counts() ProvisionCounts {
	if p == nil {
		return ProvisionCounts{}
	}
	return p.catalog.Counts()
}

// Snapshot returns the current catalog generation and the sorted, deduplicated
// set of contracts whose artifacts are fully verified. Unrelated pending or
// failed models are not members. Runtime participation additionally requires
// current-generation, per-contract preload acknowledgement.
func (p *Provisioner) Snapshot() ProvisionSnapshot {
	if p == nil {
		return ProvisionSnapshot{}
	}
	return p.catalog.Snapshot()
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
				var mediaProfile *mediawork.Profile
				if err == nil {
					mediaProfile = p.cache.cache.MediaProfile(manifest)
				}
				p.catalog.Record(generation, manifest.ModelID, contractPath, mediaProfile, err)
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
