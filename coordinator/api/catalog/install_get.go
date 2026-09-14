package catalog

import (
	"net/http"
	"net/url"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

func (s *Controller) GetInstallModel(w http.ResponseWriter, r *http.Request) {
	modelID, ok := parseModelCatalogPath(r.URL.Path)
	if !ok || modelID == "" {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "model not found"))
		return
	}
	rec, err := s.store().GetModelRegistryRecord(modelID)
	if err != nil {
		s.writeModelRegistryStoreError(w, "get model", err)
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, catalogModelFromRegistryRecord(rec))
}

func (s *Controller) GetInstallManifest(w http.ResponseWriter, r *http.Request) {
	modelID, ok := parseModelCatalogManifestPath(r.URL.Path)
	if !ok || modelID == "" {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", "model manifest not found"))
		return
	}
	m, err := s.store().GetModelManifest(modelID)
	if err != nil {
		s.writeModelRegistryStoreError(w, "get manifest", err)
		return
	}
	httpresponse.WriteJSON(w, http.StatusOK, m)
}

func parseModelCatalogPath(p string) (string, bool) {
	rest := strings.TrimPrefix(p, "/v1/models/catalog/")
	if rest == p || rest == "" {
		return "", false
	}
	modelID, err := url.PathUnescape(rest)
	if err != nil {
		return "", false
	}
	return modelID, true
}

func parseModelCatalogManifestPath(p string) (string, bool) {
	rest := strings.TrimPrefix(p, "/v1/models/catalog/manifest/")
	if rest == p || rest == "" {
		return "", false
	}
	modelID, err := url.PathUnescape(rest)
	if err != nil {
		return "", false
	}
	return modelID, true
}
