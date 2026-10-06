package httpx

import (
	"fmt"
	"net/http"
)

// UnimplementedEndpoint keeps unknown API routes on the structured error contract.
func UnimplementedEndpoint(w http.ResponseWriter, r *http.Request) {
	WriteJSON(w, http.StatusNotFound, ErrorResponse(
		"invalid_request_error",
		fmt.Sprintf("endpoint %s %s is not implemented", r.Method, r.URL.Path),
	))
}
