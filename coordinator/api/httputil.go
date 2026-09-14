package api

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

type errorDetailOpt = httpresponse.ErrorDetail

func writeJSON(w http.ResponseWriter, status int, value any) {
	httpresponse.WriteJSON(w, status, value)
}
func errorResponse(kind, message string, opts ...errorDetailOpt) map[string]any {
	return httpresponse.ErrorBody(kind, message, opts...)
}
func withParam(param string) errorDetailOpt { return httpresponse.WithParam(param) }
func withCode(code string) errorDetailOpt   { return httpresponse.WithCode(code) }
