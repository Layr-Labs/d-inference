package releases

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/releasepolicy"
)

// RuntimeManifest returns the current runtime manifest as JSON.
// No auth required — hashes are not secrets.
func (s *Controller) RuntimeManifest(w http.ResponseWriter, r *http.Request) {
	if cached, ok := s.cache().Get(runtimeManifestCacheKey); ok {
		httpresponse.WriteCachedJSON(w, cached)
		return
	}
	var resp map[string]any
	if s.policy().RuntimeManifest() == nil {
		resp = map[string]any{"configured": false}
	} else {
		// template_hashes is rendered as name -> sorted list of every hash
		// accepted across the active releases: the manifest is a union, not a
		// single expected value per template.
		templates := make(map[string][]string, len(s.policy().RuntimeManifest().TemplateHashes))
		for name, accepted := range s.policy().RuntimeManifest().TemplateHashes {
			templates[name] = releasepolicy.SortedTemplateHashes(accepted)
		}
		resp = map[string]any{
			"configured":      true,
			"python_hashes":   s.policy().RuntimeManifest().PythonHashes,
			"runtime_hashes":  s.policy().RuntimeManifest().RuntimeHashes,
			"template_hashes": templates,
		}
	}
	body, err := json.Marshal(resp)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to encode manifest"))
		return
	}
	s.cache().Set(runtimeManifestCacheKey, body, time.Minute)
	httpresponse.WriteCachedJSON(w, body)
}
