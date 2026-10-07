package rejection

import (
	"net/http"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// PreContentTerminal retains the real HTTP status: no pre-content path has
// written headers or bytes. retryAfterSec <= 0 omits Retry-After.
func (s *Recorder) PreContentTerminal(w http.ResponseWriter, r *http.Request, rec *store.RejectionRecord, decision Servability, retryAfterSec int, errType, message, code string) {
	s.Record(r, rec, decision)
	if retryAfterSec > 0 {
		w.Header().Set("Retry-After", strconv.Itoa(retryAfterSec))
	}
	httpx.WriteJSON(w, rec.HTTPStatus, httpx.ErrorResponse(errType, message, httpx.WithCode(code)))
}
