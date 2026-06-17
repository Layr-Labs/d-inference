package api

import (
	"encoding/json"
	"fmt"
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
func (s *Server) SyncRuntimeManifest() {
	releases := s.store.ListReleases()

	// Guard: if the store returns nil (e.g. Postgres timeout), do NOT nuke
	// a previously-good manifest. A transient DB failure should not
	// instantly deroute every provider on the network.
	if releases == nil {
		s.logger.Warn("SyncRuntimeManifest: ListReleases returned nil (DB timeout?), keeping existing manifest")
		return
	}

	// Minimum provider version is set manually via EIGENINFERENCE_MIN_PROVIDER_VERSION
	// env var. It is NOT auto-derived from the latest release — pushing a new release
	// should not instantly knock all existing providers offline.

	manifest := &RuntimeManifest{
		PythonHashes:   make(map[string]bool),
		RuntimeHashes:  make(map[string]bool),
		TemplateHashes: make(map[string]string),
	}

	// Sort releases ascending by version so newer releases' template hashes
	// overwrite older ones (templates are keyed by name; binary/runtime hashes
	// accumulate as a set).
	sortedReleases := append([]store.Release(nil), releases...)
	sort.SliceStable(sortedReleases, func(i, j int) bool {
		return semverGreater(sortedReleases[j].Version, sortedReleases[i].Version)
	})

	hasAny := false
	for _, r := range sortedReleases {
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
		if r.TemplateHashes != "" {
			// Parse "name=hash,name=hash" format
			for _, pair := range strings.Split(r.TemplateHashes, ",") {
				parts := strings.SplitN(strings.TrimSpace(pair), "=", 2)
				if len(parts) == 2 {
					manifest.TemplateHashes[parts[0]] = parts[1]
					hasAny = true
				}
			}
		}
		if r.MetallibHash != "" {
			normalized, err := normalizeSHA256Hex(r.MetallibHash, "release.metallib_hash")
			if err != nil {
				s.logger.Warn("invalid release metallib hash ignored",
					"version", r.Version,
					"platform", r.Platform,
					"error", err,
				)
			} else {
				manifest.TemplateHashes["mlx_metallib"] = normalized
				hasAny = true
			}
		}
	}

	if hasAny {
		s.knownRuntimeManifest = manifest
		s.logger.Info("runtime manifest synced from releases",
			"python_hashes", len(manifest.PythonHashes),
			"runtime_hashes", len(manifest.RuntimeHashes),
			"template_hashes", len(manifest.TemplateHashes),
		)
	} else if len(releases) > 0 {
		// Explicit empty: releases exist but none have hashes. Clear manifest.
		s.knownRuntimeManifest = nil
		s.logger.Info("runtime manifest cleared: releases exist but none have runtime hashes")
	} else {
		// Empty releases slice (not nil — nil is handled above). No releases
		// at all, which is only expected on a fresh coordinator. Keep
		// existing manifest if one exists.
		if s.knownRuntimeManifest != nil {
			s.logger.Warn("SyncRuntimeManifest: zero releases returned, keeping existing manifest")
			return
		}
		s.knownRuntimeManifest = nil
	}

	s.revalidateConnectedProvidersAgainstRuntimePolicy()
}

func (s *Server) revalidateConnectedProvidersAgainstRuntimePolicy() {
	// Note: the DB-timeout case (ListReleases returns nil) is already guarded
	// in SyncRuntimeManifest — it returns early before reaching this function.
	// A nil manifest here means releases exist but none carry runtime hashes,
	// i.e. an intentional manifest withdrawal. Providers must be derouted.

	for _, providerID := range s.registry.ProviderIDs() {
		provider := s.registry.GetProvider(providerID)
		if provider == nil {
			continue
		}

		provider.Mu().Lock()
		pythonHash := provider.PythonHash
		runtimeHash := provider.RuntimeHash
		templateHashes := registry.CloneStringMap(provider.TemplateHashes)
		version := provider.Version
		backend := provider.Backend

		if s.knownRuntimeManifest == nil {
			// Manifest was withdrawn — deroute provider until the next
			// successful challenge re-verifies it.
			provider.RuntimeVerified = false
			provider.RuntimeManifestChecked = false
		} else if s.minProviderVersion != "" &&
			version != "" &&
			semverLess(version, s.minProviderVersion) {
			provider.RuntimeVerified = false
			provider.RuntimeManifestChecked = false
			s.ddIncr("provider_version_below_minimum", []string{"gate:manifest_sync", "version:" + version})
		} else {
			runtimeOK, _ := s.verifyRuntimeHashesForBackend(
				backend,
				pythonHash,
				runtimeHash,
				templateHashes,
			)
			if !runtimeOK {
				provider.RuntimeVerified = false
				provider.RuntimeManifestChecked = false
			}
		}
		provider.Mu().Unlock()
	}
}

// RuntimeManifest holds the set of accepted hashes for provider runtime components.
// When configured, the coordinator verifies provider-reported hashes against
// this manifest at registration and during periodic attestation challenges.
type RuntimeManifest struct {
	PythonHashes   map[string]bool   `json:"python_hashes"`   // set of accepted Python runtime hashes
	RuntimeHashes  map[string]bool   `json:"runtime_hashes"`  // set of accepted inference runtime hashes
	TemplateHashes map[string]string `json:"template_hashes"` // template_name -> expected hash
}

// SetRuntimeManifest configures the known-good runtime manifest for provider
// verification. Pass nil to disable runtime verification (all providers pass).
// semverGreater returns true if version a is greater than version b.
// Compares numeric components (e.g. "0.2.31" > "0.2.9" = true).
func semverGreater(a, b string) bool {
	if a == "" {
		return false
	}
	if b == "" {
		return true
	}
	aParts := strings.Split(a, ".")
	bParts := strings.Split(b, ".")
	for i := 0; i < len(aParts) || i < len(bParts); i++ {
		var ai, bi int
		if i < len(aParts) {
			fmt.Sscanf(aParts[i], "%d", &ai)
		}
		if i < len(bParts) {
			fmt.Sscanf(bParts[i], "%d", &bi)
		}
		if ai > bi {
			return true
		}
		if ai < bi {
			return false
		}
	}
	return false // equal
}

// semverLess returns true if version a is less than version b.
func semverLess(a, b string) bool {
	return semverGreater(b, a)
}

func (s *Server) SetRuntimeManifest(m *RuntimeManifest) {
	s.knownRuntimeManifest = m
}

func (s *Server) verifyRuntimeHashesForBackend(backend, pythonHash, runtimeHash string, templateHashes map[string]string) (bool, []protocol.RuntimeMismatch) {
	if s.knownRuntimeManifest == nil {
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

	manifest := s.knownRuntimeManifest
	scoped := &RuntimeManifest{
		PythonHashes:   map[string]bool{},
		RuntimeHashes:  map[string]bool{},
		TemplateHashes: map[string]string{},
	}
	scopedReportedTemplates := make(map[string]string)

	if expected := manifest.TemplateHashes["mlx_metallib"]; expected != "" {
		scoped.TemplateHashes["mlx_metallib"] = expected
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
		for name, expected := range manifest.TemplateHashes {
			got, ok := templateHashes[name]
			if !ok || got == "" {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       "(missing)",
				})
				continue
			}
			if got != expected {
				mismatches = append(mismatches, protocol.RuntimeMismatch{
					Component: "template:" + name,
					Expected:  expected,
					Got:       got,
				})
			}
		}
		for name, got := range templateHashes {
			if _, ok := manifest.TemplateHashes[name]; !ok {
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
	const cacheKey = "runtime_manifest:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}
	var resp map[string]any
	if s.knownRuntimeManifest == nil {
		resp = map[string]any{"configured": false}
	} else {
		resp = map[string]any{
			"configured":      true,
			"python_hashes":   s.knownRuntimeManifest.PythonHashes,
			"runtime_hashes":  s.knownRuntimeManifest.RuntimeHashes,
			"template_hashes": s.knownRuntimeManifest.TemplateHashes,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode manifest"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}
