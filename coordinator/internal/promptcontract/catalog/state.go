// Package catalog owns the generation-fenced artifact readiness handoff.
package catalog

import (
	"context"
	"errors"
	"log/slog"
	"sort"
	"strings"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/identity"
	"github.com/eigeninference/d-inference/coordinator/mediawork"
)

type Status struct {
	MediaProfile         *mediawork.Profile `json:"-"`
	ModelID              string
	PromptContractID     string
	ModelAggregateSHA256 string
	Path                 string
	ArtifactReady        bool
	LastError            string
}

type Counts struct{ Ready, Pending, Failed int }

// Snapshot omits private model identities, paths and error details.
type Snapshot struct {
	Generation  uint64
	Counts      Counts
	ContractIDs []string
}

type State struct {
	mu           sync.RWMutex
	generation   uint64
	statuses     map[string]Status
	catalogError string
}

var ErrInvalidConfig = errors.New("invalid prompt-sidecar configuration")

func New() *State { return &State{statuses: make(map[string]Status)} }

func (p *State) Reconcile(manifests []identity.Manifest, maxModels int) (uint64, error) {
	var statuses []Status
	var err error
	if len(manifests) > maxModels {
		err = ErrInvalidConfig
	} else {
		statuses, err = prepare(manifests)
	}
	if err != nil {
		p.reject(err)
		return 0, err
	}
	return p.Replace(statuses), nil
}

// Replace starts a new catalog generation with pending artifact identities.
// Completed work must carry the returned generation to Record.
func (p *State) Replace(statuses []Status) uint64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.generation++
	p.statuses = make(map[string]Status, len(statuses))
	for _, status := range statuses {
		p.statuses[status.ModelID] = status
	}
	p.catalogError = ""
	return p.generation
}

func (p *State) reject(err error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.generation++
	p.statuses = make(map[string]Status)
	p.catalogError = err.Error()
}

// prepare validates a complete replacement before publishing any identities.
func prepare(manifests []identity.Manifest) ([]Status, error) {
	seen := make(map[string]bool, len(manifests))
	statuses := make([]Status, 0, len(manifests))
	for _, manifest := range manifests {
		if manifest.ModelID == "" || seen[manifest.ModelID] {
			return nil, identity.ErrInvalidArtifact
		}
		seen[manifest.ModelID] = true
		artifacts, err := identity.PromptArtifacts(manifest.Files)
		if err != nil {
			return nil, err
		}
		contractID, err := identity.ContractID(artifacts, identity.CurrentVersions())
		if err != nil {
			return nil, err
		}
		statuses = append(statuses, Status{ModelID: manifest.ModelID, PromptContractID: contractID,
			ModelAggregateSHA256: strings.ToLower(strings.TrimSpace(manifest.AggregateSHA256))})
	}
	return statuses, nil
}

func (p *State) Status(modelID string) (Status, bool) {
	p.mu.RLock()
	defer p.mu.RUnlock()
	status, ok := p.statuses[modelID]
	return status, ok
}

func (p *State) Statuses() []Status {
	p.mu.RLock()
	statuses := make([]Status, 0, len(p.statuses))
	for _, status := range p.statuses {
		statuses = append(statuses, status)
	}
	p.mu.RUnlock()
	sort.Slice(statuses, func(i, j int) bool { return statuses[i].ModelID < statuses[j].ModelID })
	return statuses
}

func (p *State) Counts() Counts {
	if p == nil {
		return Counts{}
	}
	p.mu.RLock()
	defer p.mu.RUnlock()
	var counts Counts
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

func (p *State) Snapshot() Snapshot {
	if p == nil {
		return Snapshot{}
	}
	p.mu.RLock()
	snapshot := Snapshot{Generation: p.generation}
	if p.catalogError != "" {
		snapshot.Counts.Failed++
	}
	contracts := make(map[string]struct{}, len(p.statuses))
	for _, status := range p.statuses {
		switch {
		case status.ArtifactReady:
			snapshot.Counts.Ready++
			if _, err := identity.ParseDigest(status.PromptContractID); err == nil {
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

func (p *State) Record(generation uint64, modelID, contractPath string, mediaProfile *mediawork.Profile, err error) {
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
	status.Path, status.MediaProfile, status.ArtifactReady = contractPath, mediaProfile, err == nil
	if err != nil && !errors.Is(err, context.Canceled) {
		status.LastError = BoundedStatusError(err.Error())
	}
	p.statuses[modelID] = status
	pending, failed := 0, 0
	for _, current := range p.statuses {
		switch {
		case current.ArtifactReady:
		case current.LastError != "":
			failed++
		default:
			pending++
		}
	}
	errorText, modelCount := status.LastError, len(p.statuses)
	p.mu.Unlock()
	if errorText != "" {
		slog.Warn("prompt artifact provisioning failed", "catalog_generation", generation, "error", errorText)
	}
	if pending == 0 && failed == 0 {
		slog.Info("prompt artifact catalog ready", "catalog_generation", generation, "models", modelCount)
	}
}

// BoundedStatusError applies the shared operational-status privacy bound.
func BoundedStatusError(value string) string {
	value = strings.TrimSpace(value)
	if len(value) <= 512 {
		return value
	}
	return value[:512]
}
