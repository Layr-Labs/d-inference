// Package compiledpolicy builds immutable approved-release inventories.
package compiledpolicy

import (
	"maps"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type Entry struct {
	Version        string
	Platform       string
	Backend        string
	BinaryHash     string
	MetallibHash   string
	TemplateHashes map[string]string
}

// Snapshot is immutable after construction. Inventory returns detached entries.
type Snapshot struct {
	Generation uint64
	Required   bool
	entries    map[string][]Entry
}

func New(generation uint64, required bool) *Snapshot {
	return &Snapshot{Generation: generation, Required: required, entries: make(map[string][]Entry)}
}

func (s *Snapshot) Inventory() map[string][]Entry {
	out := make(map[string][]Entry)
	if s == nil {
		return out
	}
	for hash, entries := range s.entries {
		out[hash] = cloneEntries(entries)
	}
	return out
}

func cloneEntries(entries []Entry) []Entry {
	out := append([]Entry(nil), entries...)
	for i := range out {
		out[i].TemplateHashes = maps.Clone(out[i].TemplateHashes)
	}
	return out
}

// WithRelease returns a new inventory with a caller-validated binary hash.
// Parsing retains the release format's last-value-wins template semantics.
func (s *Snapshot) WithRelease(release *store.Release, normalizedHash string) *Snapshot {
	next := &Snapshot{Generation: s.Generation, Required: s.Required, entries: s.Inventory()}
	templates := make(map[string]string)
	for _, pair := range strings.Split(release.TemplateHashes, ",") {
		parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
		if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
			templates[parts[0]] = parts[1]
		}
	}
	next.entries[normalizedHash] = append(next.entries[normalizedHash], Entry{
		Version: release.Version, Platform: release.Platform, Backend: release.Backend,
		BinaryHash: normalizedHash, MetallibHash: release.MetallibHash, TemplateHashes: templates,
	})
	return next
}

// Retain starts a new generation excluding a replaced or deactivated release.
func Retain(last *Snapshot, generation uint64, required bool, version, platform string) *Snapshot {
	next := New(generation, required)
	for hash, entries := range last.Inventory() {
		for _, entry := range entries {
			if entry.Version != version || entry.Platform != platform {
				next.entries[hash] = append(next.entries[hash], entry)
			}
		}
	}
	return next
}
