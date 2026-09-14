package catalog

import (
	"net/http"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

func (s *Controller) writeModelRegistryStoreError(w http.ResponseWriter, operation string, err error) {
	if isModelRegistryNotFound(err) {
		httpresponse.WriteJSON(w, http.StatusNotFound, httpresponse.ErrorBody("not_found", err.Error()))
		return
	}
	s.logger.Error("model registry store error", "operation", operation, "error", err)
	httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "model registry store error"))
}

func isModelRegistryNotFound(err error) bool {
	if err == nil {
		return false
	}
	return strings.Contains(strings.ToLower(err.Error()), "not found")
}
