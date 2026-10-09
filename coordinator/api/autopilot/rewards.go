package autopilot

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
)

// RewardsHandler serves already-authorized admin operations. Funding and
// historical baseline repair never alter provider consent or live rollout mode.
type RewardsHandler struct {
	Store   store.AutopilotRewardsStore
	Enabled bool
}

func (h RewardsHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if h.Store == nil {
		writeRewardError(w, errors.New("reward store unavailable"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	switch r.Method {
	case http.MethodPatch:
		var cap *int64
		if err := decodeRewardBody(http.MaxBytesReader(w, r.Body, 1024), map[string]any{"cap_micro_usd": &cap}); err != nil || cap == nil || *cap < 0 {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "cap_micro_usd must be a nonnegative integer; no other fields are allowed"))
			return
		}
		pool, err := h.Store.SetAutopilotRewardPoolCap(ctx, *cap)
		if err != nil {
			writeRewardError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"pool": pool})
	case http.MethodPost:
		id, valid := canonicalMachineID(r.PathValue("machine_id"))
		if !valid {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "machine_id must be a nonzero canonical UUID"))
			return
		}
		var at time.Time
		var amount *int64
		var evidence string
		if err := decodeRewardBody(http.MaxBytesReader(w, r.Body, 8192), map[string]any{
			"first_opt_in_at": &at, "seven_day_earnings_micro_usd": &amount, "evidence": &evidence,
		}); err != nil || at.IsZero() || amount == nil || *amount < 0 || strings.TrimSpace(evidence) == "" || len(evidence) > 1024 {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "first_opt_in_at, nonnegative seven_day_earnings_micro_usd and evidence of at most 1024 bytes are required"))
			return
		}
		enrollment, err := h.Store.RestoreAutopilotBaseline(ctx, earningsfloor.Baseline{
			MachineID: id, FirstOptInAt: at.UTC(), SevenDayEarningsMicroUSD: *amount, Evidence: evidence,
		})
		if err != nil {
			writeRewardError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"enrollment": enrollment})
	default:
		after, limit, err := decodeRewardQuery(r.URL.RawQuery)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "only after (canonical UUID) and limit (1 to 200) are allowed"))
			return
		}
		pool, err := h.Store.AutopilotRewardPool(ctx)
		if err != nil {
			writeRewardError(w, err)
			return
		}
		enrollments, err := h.Store.AutopilotRewardEnrollments(ctx, after, limit)
		if err != nil {
			writeRewardError(w, err)
			return
		}
		if enrollments == nil {
			enrollments = []earningsfloor.Enrollment{}
		}
		response := map[string]any{"enabled": h.Enabled, "pool": pool, "enrollments": enrollments}
		if len(enrollments) == limit {
			response["next_after"] = enrollments[len(enrollments)-1].MachineID
		}
		writeJSON(w, http.StatusOK, response)
	}
}

func writeRewardError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "reward enrollment not found"))
	case errors.Is(err, earningsfloor.ErrBaselineFrozen):
		writeJSON(w, http.StatusConflict, errorResponse("conflict", "the first-opt-in baseline is already frozen"))
	case errors.Is(err, earningsfloor.ErrPoolCap):
		writeJSON(w, http.StatusConflict, errorResponse("conflict", "the pool cap cannot be below money already spent"))
	case errors.Is(err, earningsfloor.ErrHistory), errors.Is(err, earningsfloor.ErrIdentity), errors.Is(err, store.ErrErasureConflict):
		writeJSON(w, http.StatusConflict, errorResponse("conflict", "reward enrollment history or ownership is unresolved"))
	default:
		writeJSON(w, http.StatusServiceUnavailable, errorResponse("server_error", "Autopilot rewards unavailable"))
	}
}
