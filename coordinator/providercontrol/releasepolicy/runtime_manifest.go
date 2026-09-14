package releasepolicy

import (
	"fmt"
	"sort"
	"strings"
)

// RuntimeManifest holds the set of accepted hashes for provider runtime components.
// When configured, the coordinator verifies provider-reported hashes against
// this manifest at registration and during periodic attestation challenges.
//
// Every field is a SET: the manifest is the UNION of every ACTIVE release's
// runtime facts, and a provider passes when its reported value is one of the
// accepted values for that component. TemplateHashes is a set PER template
// name (mlx_metallib included). It must never collapse to a single value per
// name: releases overlap in production for the whole self-update window, and a
// single-valued mlx_metallib entry derouted ~1,180 providers still running the
// previous release the moment the next one was registered (2026-09-03).
// Deactivating a release is the mechanism that removes its values.
type RuntimeManifest struct {
	PythonHashes   map[string]bool            `json:"python_hashes"`   // set of accepted Python runtime hashes
	RuntimeHashes  map[string]bool            `json:"runtime_hashes"`  // set of accepted inference runtime hashes
	TemplateHashes map[string]map[string]bool `json:"template_hashes"` // template_name -> set of accepted hashes
}

// NewRuntimeManifest returns an empty manifest with every set allocated.
func NewRuntimeManifest() *RuntimeManifest {
	return &RuntimeManifest{
		PythonHashes:   make(map[string]bool),
		RuntimeHashes:  make(map[string]bool),
		TemplateHashes: make(map[string]map[string]bool),
	}
}

// AddTemplateHash records value as an accepted hash for template name and
// reports whether anything was recorded. Values are trimmed and lower-cased so
// membership is case-insensitive (SHA-256 hex) and identical on the
// registration, challenge, and revalidation paths; empty names/values are
// ignored.
func (m *RuntimeManifest) AddTemplateHash(name, value string) bool {
	name = strings.TrimSpace(name)
	value = strings.ToLower(strings.TrimSpace(value))
	if name == "" || value == "" {
		return false
	}
	if m.TemplateHashes == nil {
		m.TemplateHashes = make(map[string]map[string]bool)
	}
	accepted := m.TemplateHashes[name]
	if accepted == nil {
		accepted = make(map[string]bool)
		m.TemplateHashes[name] = accepted
	}
	accepted[value] = true
	return true
}

// addTemplateHashPairs unions a release row's "name=hash,name=hash" list into
// the manifest and reports whether any entry was recorded.
func (m *RuntimeManifest) addTemplateHashPairs(raw string) bool {
	added := false
	for _, pair := range strings.Split(raw, ",") {
		parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
		if len(parts) == 2 && m.AddTemplateHash(parts[0], parts[1]) {
			added = true
		}
	}
	return added
}

// clone deep-copies the manifest; a nil receiver yields an empty manifest.
func (m *RuntimeManifest) clone() *RuntimeManifest {
	out := NewRuntimeManifest()
	if m == nil {
		return out
	}
	for hash := range m.PythonHashes {
		out.PythonHashes[hash] = true
	}
	for hash := range m.RuntimeHashes {
		out.RuntimeHashes[hash] = true
	}
	for name, accepted := range m.TemplateHashes {
		for hash := range accepted {
			out.AddTemplateHash(name, hash)
		}
	}
	return out
}

// templateHashSetSizes renders "name=count" pairs (sorted by name) for logs,
// so a sync line shows how many releases' values each template accepts.
func (m *RuntimeManifest) templateHashSetSizes() string {
	names := make([]string, 0, len(m.TemplateHashes))
	for name := range m.TemplateHashes {
		names = append(names, name)
	}
	sort.Strings(names)
	parts := make([]string, 0, len(names))
	for _, name := range names {
		parts = append(parts, fmt.Sprintf("%s=%d", name, len(m.TemplateHashes[name])))
	}
	return strings.Join(parts, ",")
}

// SortedTemplateHashes lists a template's accepted hashes deterministically
// for diagnostics and the public manifest endpoint.
func SortedTemplateHashes(accepted map[string]bool) []string {
	out := make([]string, 0, len(accepted))
	for hash := range accepted {
		out = append(out, hash)
	}
	sort.Strings(out)
	return out
}

// SetRuntimeManifest configures the known-good runtime manifest for provider
// verification. Pass nil to disable runtime verification (all providers pass).
func (s *Manager) SetRuntimeManifest(m *RuntimeManifest) {
	s.knownRuntimeManifest = m
}
