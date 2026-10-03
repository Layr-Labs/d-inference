package releases

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

// HandleRuntimeManifest returns the current runtime manifest as JSON.
// No auth required — hashes are not secrets.
func (s *Owner) HandleRuntimeManifest(w http.ResponseWriter, r *http.Request) {
	if cached, ok := s.readCache.Get(runtimeManifestCacheKey); ok {
		httpx.WriteCachedJSON(w, cached)
		return
	}
	var resp map[string]any
	manifest := s.runtimeManifest.Load()
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
			"template_hashes": templates,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to encode manifest"))
		return
	}
	s.readCache.Set(runtimeManifestCacheKey, body, time.Minute)
	httpx.WriteCachedJSON(w, body)
}
