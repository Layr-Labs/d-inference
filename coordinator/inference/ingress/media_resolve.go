package ingress

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/inference/dispatch"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// mediaFetchInferenceReserve is leftover first-content time kept for the
// provider after the coordinator inlines remote media. The mediafetch defaults
// (15s/file, 25s total) are larger than the production first-content clock
// (ordinary 9s base; shorter for exact model policies), so an unbounded fetch
// can expire the clock before the provider starts — the video-url eval failed as
// "timeout waiting for first response (backup)" after a successful fetch.
const mediaFetchInferenceReserve = 5 * time.Second

// mediaFetchMinBudget is the smallest fetch window worth starting.
const mediaFetchMinBudget = 500 * time.Millisecond

// mediaFetchBudget returns how long Resolve may run against the request-absolute
// first-content clock. bound=false means the clock was never stamped and the
// caller must keep the historical unbounded (mediafetch-default) path.
// bound=true and budget==0 means the leftover clock cannot both fetch and
// produce first content — fail closed without starting a 15s download.
func mediaFetchBudget(receivedAt time.Time, firstContentDeadline time.Duration) (budget time.Duration, bound bool) {
	if receivedAt.IsZero() || firstContentDeadline <= 0 {
		return 0, false
	}
	remaining := dispatch.FirstTokenRemainingSince(receivedAt, firstContentDeadline)
	reserve := mediaFetchInferenceReserve
	if half := firstContentDeadline / 2; half < reserve {
		reserve = half
	}
	if reserve < mediaFetchMinBudget {
		reserve = mediaFetchMinBudget
	}
	if remaining <= reserve+mediaFetchMinBudget {
		return 0, true
	}
	return remaining - reserve, true
}

// mediaResolveMeta carries the request descriptors resolveRemoteMedia needs to
// record rejection telemetry with the same fidelity as the surrounding gates,
// plus the self-route context used to gate egress on serve-ability.
type mediaResolveMeta struct {
	model                 string
	publicModel           string
	stream                bool
	estimatedPromptTokens int
	// firstContentDeadline is the request-local duration pinned before media,
	// admission, alias fallback, and dispatch. Production callers always set it;
	// zero retains the focused-test fallback to the server policy.
	firstContentDeadline time.Duration
	requestedMaxTokens   int
	hasTools             bool
	requiresVision       bool
	// selfRoute (exclusive X-Darkbloom-Route: self) skips the balance
	// reservation, so the monetary cost gate that otherwise precedes a fetch is
	// absent. ownerAccountID is the caller's owned-provider set. resolveRemoteMedia
	// confirms the owner can actually serve the request BEFORE any fetch, so a
	// user with no linked/online/capable machine can't drive coordinator egress
	// and only then receive the self-route-unavailable error.
	//
	// traits carries the FULL routing traits, not just HasTools: a constrained
	// tool_choice raises RequiresToolConstraint, which providerEligibleForTraits
	// enforces, so reconstructing a partial trait set here would call an owned
	// provider serviceable and fetch before the real admission rejected it. The
	// traits are derived from the pre-inline body; runInferenceAdmission re-checks
	// with the post-inline set, which can only be stricter.
	selfRoute      bool
	ownerAccountID string
	traits         registry.RequestTraits
}

// mediaRejectionReason maps a media-fetch failure's HTTP status onto the
// rejection-ledger reason_code, so the dashboards can tell a malformed consumer
// request apart from a blocked host, a slow origin and a broken upstream.
// Filing all of them as "bad_param" made every upstream fault look like a
// client bug. reason_code is a free-form TEXT column (store/postgres.go), so
// these values need no schema change.
func mediaRejectionReason(status int) string {
	switch status {
	case http.StatusForbidden:
		return "media_blocked"
	case http.StatusRequestTimeout:
		return "upstream_timeout"
	case http.StatusBadGateway, http.StatusGatewayTimeout:
		return "upstream_error"
	case http.StatusRequestEntityTooLarge:
		return "payload_too_large"
	default:
		return "bad_param"
	}
}

// resolveRemoteMedia is phase 2 (post-reservation): it fetches remote media
// URLs in the (already tool-schema normalized, JSON-parsed) request and inlines
// them. On success it returns the body to forward downstream — re-marshaled
// only when a URL was actually inlined — inlined=true when it was, and ok=true.
// On any failure it writes the terminal OpenAI-style error response and returns
// ok=false; the caller must refund the balance reservation and return
// immediately.
//
// parsed is mutated in place when media is inlined, so callers that also hold
// the parsed map (routing/alias fallback re-marshals) observe the inlined data:
// URIs consistently with the returned rawBody. inlined=true obliges the caller
// to refresh every view derived from the pre-inline body — the provider-bound
// body, the routing traits computed from it, and the balance reservation, which
// was taken while the media was still a ~100-byte URL.
func (s *Controller) resolveRemoteMedia(w http.ResponseWriter, r *http.Request, rawBody []byte, parsed map[string]any, timing *registry.RequestTiming, meta mediaResolveMeta) (body []byte, inlined bool, ok bool) {
	if s.deps.MediaResolver() == nil || !s.deps.MediaResolver().Enabled() {
		return rawBody, false, true
	}
	if !mediafetch.HasRemoteMedia(parsed) {
		return rawBody, false, true
	}

	// Self-route skips the balance reservation, so nothing has yet gated egress
	// on serve-ability. Before fetching, confirm the owner has an online machine
	// that can serve this request; otherwise a user with no linked/offline/
	// incapable machine could drive up to the media-fetch caps of coordinator
	// egress and only then get the self-route error. Only runs when a fetch would
	// actually happen (remote media present); selfRouteUnavailable writes its own
	// terminal response. The later runInferenceAdmission re-checks (idempotent).
	if meta.selfRoute {
		if s.selfRouteUnavailable(w, r, meta.ownerAccountID, meta.model,
			meta.traits, meta.requiresVision) {
			return nil, false, false
		}
	}

	start := time.Now()
	resolveCtx := r.Context()
	if receivedAt := dispatch.TimingReceivedAt(timing); !receivedAt.IsZero() {
		deadline := meta.firstContentDeadline
		if deadline <= 0 {
			deadline = s.FirstContentDeadline(meta.model, meta.estimatedPromptTokens)
		}
		budget, bound := mediaFetchBudget(receivedAt, deadline)
		if bound && budget <= 0 {
			s.deps.Logger().Warn("remote media rejected", "code", "media_fetch_timeout", "status", http.StatusRequestTimeout)
			s.mediaFetchRejected(w, r, parsed, meta, http.StatusRequestTimeout, "media_fetch_timeout",
				"timed out fetching remote media")
			return nil, false, false
		}
		if bound {
			var cancel context.CancelFunc
			resolveCtx, cancel = context.WithTimeout(r.Context(), budget)
			defer cancel()
		}
	}
	res, err := s.deps.MediaResolver().Resolve(resolveCtx, parsed)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			// The client is gone. The caller still refunds the monetary reservation,
			// but there is no response to write and no rejection/timeout telemetry to
			// emit: this was not an origin failure.
			return nil, false, false
		}
		var me *mediafetch.Error
		if !errors.As(err, &me) {
			me = &mediafetch.Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
				Public: "failed to fetch remote media", Internal: "unexpected resolver error"}
		}
		// Never log Internal here: media URLs often contain presigned credentials,
		// and wrapped network errors can reproduce the full URL. mediafetch.Error
		// keeps Internal non-sensitive as defense in depth, but the API log needs
		// only stable structured fields.
		s.deps.Logger().Warn("remote media rejected", "code", me.Code, "status", me.Status)
		s.mediaFetchRejected(w, r, parsed, meta, me.Status, me.Code, me.Public)
		return nil, false, false
	}
	if !res.Changed {
		return rawBody, false, true
	}

	// A URL was inlined — re-marshal so the forwarded body reflects the data:
	// URI. marshalForwardBody (HTML-escaping disabled) matches the body the
	// handler actually seals, so the routing/size view is consistent with the
	// encrypted payload rather than an HTML-escaped (inflated) variant.
	newBody, mErr := marshalForwardBody(parsed)
	if mErr != nil {
		s.deps.Logger().Error("re-marshal after media inline failed", "error", mErr)
		s.deps.Metrics.Incr("inference.media_fetch.rejected", []string{"code:remarshal_failed", "model:" + meta.model})
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error",
			"failed to process request media"))
		return nil, false, false
	}
	// The inlined body must still fit the sealed-frame budget. The dispatch-time
	// re-check would catch this too, but failing here names the actual cause
	// (media, not "your JSON") while the fetch is still the freshest context.
	if len(newBody) > maxInferenceBodyBytes {
		s.mediaFetchRejected(w, r, parsed, meta, http.StatusRequestEntityTooLarge, "media_too_large",
			"the request exceeds the size limit once remote media is inlined; use smaller media or fewer attachments")
		return nil, false, false
	}

	timing.MediaFetchedAt = time.Now()
	modelTag := []string{"model:" + meta.model}
	s.deps.Metrics.Incr("inference.media_fetch.ok", modelTag)
	s.deps.Metrics.Count("inference.media_fetch.items", int64(res.Count), modelTag)
	s.deps.Metrics.Count("inference.media_fetch.bytes", res.Bytes, modelTag)
	s.deps.Metrics.Histogram("inference.media_fetch.duration_ms", float64(time.Since(start).Milliseconds()), modelTag)
	return newBody, true, true
}

// mediaFetchRejected records + writes a terminal media-fetch failure with the
// standard rejection telemetry shape.
func (s *Controller) mediaFetchRejected(w http.ResponseWriter, r *http.Request, parsed map[string]any, meta mediaResolveMeta, status int, code, message string) {
	reason := mediaRejectionReason(status)
	s.deps.Observer.Rejection(dispatch.Rejection{
		Request:               r,
		Stage:                 "validation",
		ReasonCode:            reason,
		HttpStatus:            status,
		KeyID:                 requestcontext.KeyID(r.Context()),
		ConsumerKeyHash:       store.HashKey(requestcontext.AccountID(r.Context())),
		RequestedModel:        meta.publicModel,
		ResolvedModel:         meta.model,
		Stream:                meta.stream,
		EstimatedPromptTokens: meta.estimatedPromptTokens,
		RequestedMaxTokens:    meta.requestedMaxTokens,
		RequiresVision:        true,
		HasTools:              meta.hasTools,
		Params:                rejectionSamplingParams(parsed),
	})
	s.deps.Metrics.Incr("inference.media_fetch.rejected", []string{"code:" + code, "model:" + meta.model})
	httpresponse.WriteJSON(w, status, httpresponse.ErrorBody(code, message, httpresponse.WithParam("messages")))
}
