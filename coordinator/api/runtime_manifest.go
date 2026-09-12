package api

import (
	"encoding/json"
	"fmt"
	"maps"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// SyncRuntimeManifest builds the runtime manifest from active releases.
// Called after a release is registered to auto-update the expected hashes.
func (s *Server) SyncRuntimeManifest() error {
	s.runtimeManifestSyncMu.Lock()
	defer s.runtimeManifestSyncMu.Unlock()

	releases, err := s.store.ListReleasesWithError()
	if err != nil {
		s.logger.Warn("SyncRuntimeManifest: release inventory unavailable; keeping existing manifest",
			"error", err)
		return fmt.Errorf("sync runtime manifest: %w", err)
	}

	// Minimum provider version is set manually via EIGENINFERENCE_MIN_PROVIDER_VERSION
	// env var. It is NOT auto-derived from the latest release — pushing a new release
	// should not instantly knock all existing providers offline.

	// Every hash — python, runtime, AND each template name including
	// mlx_metallib — is unioned into a SET across ALL active releases.
	// Releases overlap in production for the whole self-update window
	// (providers poll for updates every 30 minutes), so the manifest must
	// accept the runtime facts of every release a connected provider may
	// legitimately be running. Template hashes used to be single-valued per
	// name (newest release wins): registering v0.8.16 replaced the v0.8.15
	// metallib hash and derouted ~1,180 still-current providers at their next
	// challenge (2026-09-03 fleet brownout). Deactivating a release is the
	// mechanism that removes its hashes; iteration order is irrelevant.
	manifest := NewRuntimeManifest()
	hasAny := false
	for _, r := range releases {
		if !r.Active {
			continue
		}
		if r.PythonHash != "" {
			manifest.PythonHashes[r.PythonHash] = true
			hasAny = true
		}
		if r.RuntimeHash != "" {
			manifest.RuntimeHashes[r.RuntimeHash] = true
			hasAny = true
		}
		if manifest.addTemplateHashPairs(r.TemplateHashes) {
			hasAny = true
		}
		if r.MetallibHash != "" {
			normalized, err := normalizeSHA256Hex(r.MetallibHash, "release.metallib_hash")
			if err != nil {
				s.logger.Warn("invalid release metallib hash ignored",
					"version", r.Version,
					"platform", r.Platform,
					"error", err,
				)
			} else if manifest.AddTemplateHash("mlx_metallib", normalized) {
				hasAny = true
			}
		}
	}

	if hasAny {
		s.knownRuntimeManifest.Store(manifest)
		s.logger.Info("runtime manifest synced from releases",
			"python_hashes", len(manifest.PythonHashes),
			"runtime_hashes", len(manifest.RuntimeHashes),
			"template_hashes", len(manifest.TemplateHashes),
			"template_hash_sets", manifest.templateHashSetSizes(),
		)
	} else if len(releases) > 0 {
		// Explicit empty: releases exist but none have hashes. Clear manifest.
		s.knownRuntimeManifest.Store(nil)
		s.logger.Info("runtime manifest cleared: releases exist but none have runtime hashes")
	} else {
		// Empty releases slice (not nil — nil is handled above). No releases
		// at all, which is only expected on a fresh coordinator. Keep
		// existing manifest if one exists.
		if s.knownRuntimeManifest.Load() != nil {
			s.logger.Warn("SyncRuntimeManifest: zero releases returned, keeping existing manifest")
			return nil
		}
		s.knownRuntimeManifest.Store(nil)
	}

	s.revalidateConnectedProvidersAgainstRuntimePolicy()
	return nil
}

// convergeRuntimeManifestWithCommittedRelease folds an already-committed
// release registration into the runtime manifest when the post-mutation
// inventory read failed, so a transient store hiccup cannot leave the manifest
// rejecting the runtime facts of the release that /v1/releases/latest is
// already distributing. Every hash set — including each per-template-name
// set — is additive, exactly like a full rebuild (which unions every active
// release): the previous release's fleet keeps passing while the newly saved
// release is accepted too. The next successful sync rebuilds from the exact
// inventory.
func (s *Server) convergeRuntimeManifestWithCommittedRelease(release *store.Release, cause error) {
	s.runtimeManifestSyncMu.Lock()
	defer s.runtimeManifestSyncMu.Unlock()

	merged := s.knownRuntimeManifest.Load().clone()
	contributed := false
	if release.PythonHash != "" {
		merged.PythonHashes[release.PythonHash] = true
		contributed = true
	}
	if release.RuntimeHash != "" {
		merged.RuntimeHashes[release.RuntimeHash] = true
		contributed = true
	}
	if merged.addTemplateHashPairs(release.TemplateHashes) {
		contributed = true
	}
	if release.MetallibHash != "" {
		if normalized, err := normalizeSHA256Hex(release.MetallibHash, "release.metallib_hash"); err == nil &&
			merged.AddTemplateHash("mlx_metallib", normalized) {
			contributed = true
		}
	}
	if !contributed {
		// The committed release carries no runtime facts; a full rebuild would
		// republish the union of the remaining releases — the current manifest.
		return
	}
	s.knownRuntimeManifest.Store(merged)
	s.logger.Warn("release inventory unreadable after registration; converged runtime manifest from the committed release",
		"version", release.Version,
		"platform", release.Platform,
		"error", cause,
	)
	s.revalidateConnectedProvidersAgainstRuntimePolicy()
}

// convergeRuntimeManifestWithCommittedDeactivation folds an already-committed
// release deactivation into the runtime manifest when the post-mutation
// inventory read failed. Unlike registration (where the new release's facts
// are simply unioned in), deactivation cannot blindly subtract the pulled
// release's hashes — another active release may share them — so the manifest
// is rebuilt from the live release trust snapshot, which at this point already
// excludes the deactivated version/platform (SyncBinaryHashes either succeeded
// or was converged from the same committed deactivation first). Every hash
// set — including each per-template-name set — is the union of the remaining
// authorized releases, exactly like the full rebuild. Active releases whose
// binary hash failed normalization are absent from the snapshot and thus from
// this approximation; the next successful sync rebuilds from the exact
// inventory.
func (s *Server) convergeRuntimeManifestWithCommittedDeactivation(version, platform string, cause error) {
	s.runtimeManifestSyncMu.Lock()
	defer s.runtimeManifestSyncMu.Unlock()

	merged := NewRuntimeManifest()
	hasAny := false
	if snapshot := s.releaseTrustPolicy.Load(); snapshot != nil {
		for _, policies := range snapshot.ByBinaryHash {
			for _, policy := range policies {
				if policy.PythonHash != "" {
					merged.PythonHashes[policy.PythonHash] = true
					hasAny = true
				}
				if policy.RuntimeHash != "" {
					merged.RuntimeHashes[policy.RuntimeHash] = true
					hasAny = true
				}
				for name, hash := range policy.TemplateHashes {
					if merged.AddTemplateHash(name, hash) {
						hasAny = true
					}
				}
				if policy.MetallibHash != "" {
					if normalized, err := normalizeSHA256Hex(policy.MetallibHash, "release.metallib_hash"); err == nil &&
						merged.AddTemplateHash("mlx_metallib", normalized) {
						hasAny = true
					}
				}
			}
		}
	}
	if !hasAny {
		// The deactivated row committed, so releases exist(ed) but none of the
		// remaining authorized ones carry runtime facts: explicit withdrawal,
		// exactly like the full rebuild's "releases exist but none have
		// hashes" branch. Providers proving the pulled release's facts must
		// not keep passing the manifest gate.
		merged = nil
	}
	s.knownRuntimeManifest.Store(merged)
	s.logger.Warn("release inventory unreadable after deactivation; converged runtime manifest from the retained policy snapshot",
		"version", version,
		"platform", platform,
		"error", cause,
	)
	s.revalidateConnectedProvidersAgainstRuntimePolicy()
}

func (s *Server) revalidateConnectedProvidersAgainstRuntimePolicy() {
	// Release-inventory errors are already guarded in SyncRuntimeManifest, which
	// returns the error before reaching this function.
	// A nil manifest here means releases exist but none carry runtime hashes,
	// i.e. an intentional manifest withdrawal. Providers must be derouted.

	for _, providerID := range s.registry.ProviderIDs() {
		provider := s.registry.GetProvider(providerID)
		if provider == nil {
			continue
		}

		provider.Mu().Lock()
		manifest := s.knownRuntimeManifest.Load()
		pythonHash := provider.PythonHash
		runtimeHash := provider.RuntimeHash
		templateHashes := registry.CloneStringMap(provider.TemplateHashes)
		version := provider.Version
		backend := provider.Backend

		// Manifest policy is coordinator-owned and can be withdrawn, rotated,
		// or rolled back independently of the connected process. Rebuild all
		// policy-derived state from scratch, but preserve FreshCodeAttested:
		// that proof remains bound to this connection's token, keys, and code.
		// The token/key/code/trust invalidation paths clear it separately.
		provider.RuntimeVerified = false
		provider.RuntimeManifestChecked = false
		provider.MetallibVerified = false
		provider.RuntimeCapabilities = nil

		if manifest == nil {
			// Manifest was withdrawn — keep the process proof, but deroute the
			// provider until policy once again approves its reported runtime.
		} else if s.minProviderVersion != "" &&
			version != "" &&
			semverLess(version, s.minProviderVersion) {
			s.ddIncr("provider_version_below_minimum", []string{"gate:manifest_sync", "version:" + version})
		} else {
			runtimeOK, _ := s.verifyRuntimeHashesForBackendWithManifest(
				manifest, backend,
				pythonHash,
				runtimeHash,
				templateHashes,
			)
			provider.RuntimeVerified = runtimeOK
			provider.RuntimeManifestChecked = runtimeOK
			provider.MetallibVerified = runtimeOK &&
				runtimeManifestApprovesMetallib(
					manifest, templateHashes)
		}
		provider.Mu().Unlock()
		if err := s.registry.ReconcileAttestedRuntimeCapabilities(providerID); err != nil {
			s.logger.Warn("runtime policy capability reconciliation failed",
				"provider_id", providerID, "error", err)
		}
		if cleared := s.registry.ClearIneligiblePendingModelLoads(providerID); cleared > 0 {
			s.logger.Info("cleared pending model loads after runtime policy revocation",
				"provider_id", providerID, "count", cleared)
		}
	}
}

func runtimeManifestApprovesMetallib(
	manifest *RuntimeManifest,
	reported map[string]string,
) bool {
	if manifest == nil {
		return false
	}
	return templateHashAccepted(manifest.TemplateHashes["mlx_metallib"], reported["mlx_metallib"])
}

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

// templateHashAccepted reports whether got is one of the accepted hashes for
// a template (case-insensitive; empty values never match).
func templateHashAccepted(accepted map[string]bool, got string) bool {
	got = strings.ToLower(strings.TrimSpace(got))
	return got != "" && accepted[got]
}

// sortedTemplateHashes lists a template's accepted hashes deterministically
// for diagnostics and the public manifest endpoint.
func sortedTemplateHashes(accepted map[string]bool) []string {
	out := make([]string, 0, len(accepted))
	for hash := range accepted {
		out = append(out, hash)
	}
	sort.Strings(out)
	return out
}

// SetRuntimeManifest configures the known-good runtime manifest for provider
// verification. Pass nil to remove the manifest; the low-level matcher then
// has no hash policy, but provider routing still requires a checked manifest.
func (s *Server) SetRuntimeManifest(m *RuntimeManifest) {
	s.runtimeManifestSyncMu.Lock()
	defer s.runtimeManifestSyncMu.Unlock()
	s.knownRuntimeManifest.Store(m.snapshot())
}

func (s *Server) verifyRuntimeHashesForBackend(backend, pythonHash, runtimeHash string, templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	return s.verifyRuntimeHashesForBackendWithManifest(s.knownRuntimeManifest.Load(), backend, pythonHash, runtimeHash, templateHashes)
}

func (s *Server) verifyRuntimeHashesForBackendWithManifest(manifest *RuntimeManifest, backend, pythonHash, runtimeHash string, templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	if manifest == nil {
		return true, nil
	}

	// Only mlx-swift backends are supported. Non-Swift backends (legacy
	// Python/inprocess-mlx) are deprecated and immediately rejected.
	if !registry.BackendUsesSwiftRuntime(backend) {
		return false, []protocol.RuntimeMismatch{{
			Component: "backend",
			Expected:  "mlx-swift",
			Got:       backend,
		}}
	}

	scoped := NewRuntimeManifest()
	scopedReportedTemplates := make(map[string]string)

	if accepted := manifest.TemplateHashes["mlx_metallib"]; len(accepted) > 0 {
		scoped.TemplateHashes["mlx_metallib"] = accepted
	}
	if got := templateHashes["mlx_metallib"]; got != "" {
		scopedReportedTemplates["mlx_metallib"] = got
	}

	return s.verifyRuntimeHashesAgainstManifest(scoped, pythonHash, runtimeHash, scopedReportedTemplates)
}

func (s *Server) verifyRuntimeHashesAgainstManifest(manifest *RuntimeManifest, pythonHash, runtimeHash string, templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	if manifest == nil {
		return true, nil
	}

	var mismatches []protocol.RuntimeMismatch

	requireOneOf := func(component, got string, accepted map[string]bool) {
		if len(accepted) == 0 {
			return
		}
		if got == "" {
			mismatches = append(mismatches, protocol.RuntimeMismatch{
				Component: component,
				Expected:  "reported hash matching one of known-good values",
				Got:       "(missing)",
			})
			return
		}
		if !accepted[got] {
			mismatches = append(mismatches, protocol.RuntimeMismatch{
				Component: component,
				Expected:  "one of known-good hashes",
				Got:       got,
			})
		}
	}

	requireOneOf("python", pythonHash, manifest.PythonHashes)
	requireOneOf("runtime", runtimeHash, manifest.RuntimeHashes)

	if len(manifest.TemplateHashes) > 0 {
		// Each template name maps to the SET of hashes accepted across every
		// active release; the reported value must be one of them.
		for name, accepted := range manifest.TemplateHashes {
			if len(accepted) == 0 {
				continue
			}
			expected := "one of " + strings.Join(sortedTemplateHashes(accepted), ",")
			got, ok := templateHashes[name]
			if !ok || strings.TrimSpace(got) == "" {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       "(missing)",
				})
				continue
			}
			if !templateHashAccepted(accepted, got) {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       got,
				})
			}
		}
		for name, got := range templateHashes {
			if len(manifest.TemplateHashes[name]) == 0 {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  "template listed in runtime manifest",
					Got:       got,
				})
			}
		}
	}

	return len(mismatches) == 0, mismatches
}

// handleRuntimeManifest returns the current runtime manifest as JSON.
// No auth required — hashes are not secrets.
func (s *Server) handleRuntimeManifest(w http.ResponseWriter, r *http.Request) {
	if cached, ok := s.readCache.Get(runtimeManifestCacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}
	manifest := s.knownRuntimeManifest.Load()
	var resp map[string]any
	if manifest == nil {
		resp = map[string]any{"configured": false}
	} else {
		// template_hashes is rendered as name -> sorted list of every hash
		// accepted across the active releases: the manifest is a union, not a
		// single expected value per template.
		templates := make(map[string][]string, len(manifest.TemplateHashes))
		for name, accepted := range manifest.TemplateHashes {
			templates[name] = sortedTemplateHashes(accepted)
		}
		resp = map[string]any{
			"configured":      true,
			"python_hashes":   manifest.PythonHashes,
			"runtime_hashes":  manifest.RuntimeHashes,
			"template_hashes": templates,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode manifest"))
		return
	}
	s.readCache.Set(runtimeManifestCacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}

// snapshot owns every map while preserving nil sets and membership values.
// Once published, a manifest is immutable; readers keep one snapshot through
// verification and the matching provider-state update.
func (m *RuntimeManifest) snapshot() *RuntimeManifest {
	if m == nil {
		return nil
	}
	out := *m
	out.PythonHashes = maps.Clone(m.PythonHashes)
	out.RuntimeHashes = maps.Clone(m.RuntimeHashes)
	out.TemplateHashes = maps.Clone(m.TemplateHashes)
	for name, hashes := range out.TemplateHashes {
		out.TemplateHashes[name] = maps.Clone(hashes)
	}
	return &out
}
