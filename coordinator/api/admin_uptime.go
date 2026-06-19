package api

import (
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Admin OpenRouter-formula uptime view.
//
// GET /v1/admin/uptime computes the number OpenRouter actually scores us on —
// uptime = success / (success + provider_5xx + mid_stream + timeout), per model —
// from the stored route + rejection telemetry. rate_limited (429), cancelled
// (client disconnect), and client_error (4xx) are tallied but EXCLUDED from the
// denominator, matching OpenRouter's formula. It is the exact, post-commit-aware
// counterpart to the live inference.request_outcome counter (which approximates a
// committed-then-mid-stream failure as success); here a request's final outcome
// is read from the terminal route record.
//
// Query params: ?since= (Go duration or RFC3339, default 24h) and ?model=.

// uptimeCounts tallies request outcomes by OR-uptime class.
type uptimeCounts struct {
	Success     int64 `json:"success"`
	Provider5xx int64 `json:"provider_5xx"`
	MidStream   int64 `json:"mid_stream"`
	Timeout     int64 `json:"timeout"`
	RateLimited int64 `json:"rate_limited"` // excluded from denominator
	Cancelled   int64 `json:"cancelled"`    // excluded from denominator
	ClientError int64 `json:"client_error"` // excluded from denominator
}

func (c *uptimeCounts) add(class string) {
	switch class {
	case orClassSuccess:
		c.Success++
	case orClassProvider5xx:
		c.Provider5xx++
	case orClassMidStream:
		c.MidStream++
	case orClassTimeout:
		c.Timeout++
	case orClassRateLimited:
		c.RateLimited++
	case orClassCancelled:
		c.Cancelled++
	default:
		c.ClientError++
	}
}

// denominator is the OpenRouter-formula denominator: scored requests only.
func (c uptimeCounts) denominator() int64 {
	return c.Success + c.Provider5xx + c.MidStream + c.Timeout
}

// uptimePct is success/denominator*100, or nil when no scored requests exist in
// the window (so the caller renders "no data" rather than a misleading 0 or 100).
func (c uptimeCounts) uptimePct() *float64 {
	d := c.denominator()
	if d == 0 {
		return nil
	}
	p := 100 * float64(c.Success) / float64(d)
	return &p
}

// uptimeModelStat is the per-model (and overall) OR-uptime summary.
type uptimeModelStat struct {
	Model       string       `json:"model"`
	UptimePct   *float64     `json:"uptime_pct"`
	Denominator int64        `json:"denominator"`
	Counts      uptimeCounts `json:"counts"`
}

type uptimeResponse struct {
	Object  string            `json:"object"`
	Since   string            `json:"since"`
	Overall uptimeModelStat   `json:"overall"`
	Models  []uptimeModelStat `json:"models"`
}

// handleAdminUptime serves GET /v1/admin/uptime.
func (s *Server) handleAdminUptime(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	since := parseSince(r)
	modelFilter := strings.TrimSpace(r.URL.Query().Get("model"))

	overall := &uptimeCounts{}
	byModel := map[string]*uptimeCounts{}
	add := func(model, class string) {
		if model == "" {
			model = "unknown"
		}
		if modelFilter != "" && model != modelFilter {
			return
		}
		c := byModel[model]
		if c == nil {
			c = &uptimeCounts{}
			byModel[model] = c
		}
		c.add(class)
		overall.add(class)
	}

	// Dispatched requests: one terminal outcome per request id.
	for _, rec := range dedupeRouteOutcomes(s.store.InferenceRouteRecordsSince(since)) {
		model := rec.Model
		if modelFilter != "" && rec.Model != modelFilter && rec.PublicModel == modelFilter {
			model = modelFilter
		}
		add(model, orUptimeClass(rec.FinalStatus, rec.ErrorClass, rec.ErrorCode))
	}
	// Pre-dispatch rejections. The dispatch-stage (exhausted) rejection already
	// has a route record above, so skip it here to avoid double counting.
	for _, rej := range s.store.RejectionRecordsSince(since) {
		if rej.Stage == "dispatch" {
			continue
		}
		model := rej.ResolvedModel
		if model == "" {
			model = rej.RequestedModel
		}
		add(model, orUptimeClassForRejection(rej.HTTPStatus))
	}

	models := make([]uptimeModelStat, 0, len(byModel))
	for m, c := range byModel {
		models = append(models, uptimeModelStat{
			Model:       m,
			UptimePct:   c.uptimePct(),
			Denominator: c.denominator(),
			Counts:      *c,
		})
	}
	sort.Slice(models, func(i, j int) bool { return models[i].Model < models[j].Model })

	writeJSON(w, http.StatusOK, uptimeResponse{
		Object:  "openrouter_uptime",
		Since:   since.UTC().Format(time.RFC3339),
		Overall: uptimeModelStat{Model: "*", UptimePct: overall.uptimePct(), Denominator: overall.denominator(), Counts: *overall},
		Models:  models,
	})
}

// dedupeRouteOutcomes reduces per-attempt route records to one terminal record
// per request id. A request can have several attempt rows (failover /
// speculation); the consumer-facing outcome is the best terminal one — a success
// on any attempt means the consumer was served (invisible failover), so success
// outranks a failed sibling attempt. Non-terminal (committed-only) rows are
// ignored.
func dedupeRouteOutcomes(in []store.InferenceRouteRecord) []store.InferenceRouteRecord {
	best := make(map[string]store.InferenceRouteRecord, len(in))
	for _, rec := range in {
		if rec.FinalStatus == "" {
			continue
		}
		cur, ok := best[rec.RequestID]
		if !ok || uptimeOutcomeRank(rec.FinalStatus) > uptimeOutcomeRank(cur.FinalStatus) {
			best[rec.RequestID] = rec
		}
	}
	out := make([]store.InferenceRouteRecord, 0, len(best))
	for _, rec := range best {
		out = append(out, rec)
	}
	return out
}

// uptimeOutcomeRank orders terminal final_status values by how well the consumer
// was served, so dedupeRouteOutcomes keeps the best attempt for a request.
func uptimeOutcomeRank(finalStatus string) int {
	switch finalStatus {
	case "success":
		return 4
	case "partial_success":
		return 3
	case "timeout":
		return 2
	case "error":
		return 1
	default: // cancelled and anything else
		return 0
	}
}
