package media

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	firstcontent "github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type mediaObservation interface {
	Incr(string, []string)
	Count(string, int64, []string)
	Histogram(string, float64, []string)
}

type Dependencies struct {
	Resolver             *mediafetch.Resolver
	Logger               *slog.Logger
	Observation          mediaObservation
	RecordRemote         func(*http.Request, map[string]any, string, string, bool)
	SelfRouteUnavailable func(http.ResponseWriter, *http.Request, string, string, registry.RequestTraits, bool) bool
	Deadline             func(*http.Request, string, string, int) (time.Duration, error)
	ServiceUnavailable   func(http.ResponseWriter, string)
	RecordRejection      func(*http.Request, map[string]any, ResolveMeta, int)
}

// Bridge owns the two-phase media gate and post-reservation resolution.
// Admission, accounting and telemetry remain owned by its injected collaborators.
type Bridge struct{ d Dependencies }

func NewBridge(d Dependencies) *Bridge { return &Bridge{d: d} }

// Gate is phase 1 (pre-billing) of remote media handling
// on the chat surface. handled=true => a terminal response was written and the
// caller must return.
func (s *Bridge) Gate(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, requiresVision, hasTools, sealed bool) (handled bool) {
	if !requiresVision {
		return false
	}
	reject := func(msg string) bool {
		s.RejectRemote(w, r, parsed, model, publicModel, hasTools, msg)
		return true
	}
	scan := ScanRemoteRefs(parsed)
	switch {
	case scan.FirstRemote == "":
		// Inline data: URIs and text-only requests never reach the fetcher.
		return false
	case s.d.Resolver == nil || !s.d.Resolver.Enabled():
		// Resolver off means authoritative rollback to the data:-only contract:
		// one clean pre-dispatch 400 instead of a provider-side one. Same message
		// rejectRemoteMediaURLs writes on the generic surface, which never fetches.
		return reject("image/video input must be an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"); " +
			"remote http(s):// and file:// media URLs are not supported on this endpoint. Got: " + inreq.TruncateMediaRef(scan.FirstRemote))
	case sealed:
		// Sender-sealed requests are never fetched, whatever shape the reference
		// takes: the sender opted into sealing the payload to the coordinator, and
		// a fetch would leak request-correlated egress to the URL's origin. This
		// keys off ANY remote reference, not just a fetchable one — telling a
		// sealed caller to "send an OpenAI http(s) link instead" would be advice
		// for something we will not do either.
		return reject("sealed requests must send media as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"); " +
			"remote image_url/video_url links are not fetched for sealed payloads — inline the media or disable request sealing")
	case scan.FirstUnfetchable != "":
		// A remote reference in a shape the resolver does NOT fetch (Anthropic
		// source blocks, Responses input_image parts, file:// and other schemes)
		// keeps today's clean 400: dispatching it would either 400 across the
		// fleet or be silently dropped by the provider (an image-blind answer).
		return reject("this media reference is not fetchable on this endpoint; send it as an OpenAI-style image_url/video_url http(s) link " +
			"or as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"). Got: " + inreq.TruncateMediaRef(scan.FirstUnfetchable))
	}
	return false
}

// ResolveMeta carries the request descriptors Resolve needs to
// record rejection telemetry with the same fidelity as the surrounding gates,
// plus the self-route context used to gate egress on serve-ability.
type ResolveMeta struct {
	Model                 string
	PublicModel           string
	Stream                bool
	EstimatedPromptTokens int
	// firstContentDeadline is the request-local duration pinned before media,
	// admission, alias fallback, and dispatch. Production callers always set it;
	// zero retains the focused-test fallback to the server policy.
	FirstContentDeadline    time.Duration
	FirstContentDeadlineSet bool
	RequestedMaxTokens      int
	HasTools                bool
	RequiresVision          bool
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
	SelfRoute      bool
	OwnerAccountID string
	Traits         registry.RequestTraits
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
func (s *Bridge) Resolve(w http.ResponseWriter, r *http.Request, rawBody []byte, parsed map[string]any, timing *registry.RequestTiming, meta ResolveMeta) (body []byte, inlined bool, ok bool) {
	if s.d.Resolver == nil || !s.d.Resolver.Enabled() {
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
	if meta.SelfRoute {
		if s.d.SelfRouteUnavailable(w, r, meta.OwnerAccountID, meta.Model,
			meta.Traits, meta.RequiresVision) {
			return nil, false, false
		}
	}

	start := time.Now()
	resolveCtx := r.Context()
	if receivedAt := firstcontent.TimingReceivedAt(timing); !receivedAt.IsZero() {
		deadline := meta.FirstContentDeadline
		if deadline <= 0 && !meta.FirstContentDeadlineSet {
			var err error
			deadline, err = s.d.Deadline(r, meta.PublicModel, meta.Model, meta.EstimatedPromptTokens)
			if err != nil {
				s.d.ServiceUnavailable(w, meta.Model)
				return nil, false, false
			}
		}
		budget, bound := FetchBudget(receivedAt, deadline)
		if bound && budget <= 0 {
			s.d.Logger.Warn("remote media rejected", "code", "media_fetch_timeout", "status", http.StatusRequestTimeout)
			s.Rejected(w, r, parsed, meta, http.StatusRequestTimeout, "media_fetch_timeout",
				"timed out fetching remote media")
			return nil, false, false
		}
		if bound {
			var cancel context.CancelFunc
			resolveCtx, cancel = context.WithTimeout(r.Context(), budget)
			defer cancel()
		}
	}
	res, err := s.d.Resolver.Resolve(resolveCtx, parsed)
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
		s.d.Logger.Warn("remote media rejected", "code", me.Code, "status", me.Status)
		s.Rejected(w, r, parsed, meta, me.Status, me.Code, me.Public)
		return nil, false, false
	}
	if !res.Changed {
		return rawBody, false, true
	}

	// A URL was inlined — re-marshal so the forwarded body reflects the data:
	// URI. marshalForwardBody (HTML-escaping disabled) matches the body the
	// handler actually seals, so the routing/size view is consistent with the
	// encrypted payload rather than an HTML-escaped (inflated) variant.
	newBody, mErr := inreq.MarshalForwardBody(parsed)
	if mErr != nil {
		s.d.Logger.Error("re-marshal after media inline failed", "error", mErr)
		s.d.Observation.Incr("inference.media_fetch.rejected", []string{"code:remarshal_failed", "model:" + meta.Model})
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error",
			"failed to process request media"))
		return nil, false, false
	}
	// The inlined body must still fit the sealed-frame budget. The dispatch-time
	// re-check would catch this too, but failing here names the actual cause
	// (media, not "your JSON") while the fetch is still the freshest context.
	if len(newBody) > inreq.MaxInferenceBodyBytes {
		s.Rejected(w, r, parsed, meta, http.StatusRequestEntityTooLarge, "media_too_large",
			"the request exceeds the size limit once remote media is inlined; use smaller media or fewer attachments")
		return nil, false, false
	}

	timing.MediaFetchedAt = time.Now()
	modelTag := []string{"model:" + meta.Model}
	s.d.Observation.Incr("inference.media_fetch.ok", modelTag)
	s.d.Observation.Count("inference.media_fetch.items", int64(res.Count), modelTag)
	s.d.Observation.Count("inference.media_fetch.bytes", res.Bytes, modelTag)
	s.d.Observation.Histogram("inference.media_fetch.duration_ms", float64(time.Since(start).Milliseconds()), modelTag)
	return newBody, true, true
}

// mediaFetchRejected records + writes a terminal media-fetch failure with the
// standard rejection telemetry shape.
func (s *Bridge) Rejected(w http.ResponseWriter, r *http.Request, parsed map[string]any, meta ResolveMeta, status int, code, message string) {
	s.d.RecordRejection(r, parsed, meta, status)
	s.d.Observation.Incr("inference.media_fetch.rejected", []string{"code:" + code, "model:" + meta.Model})
	httpx.WriteJSON(w, status, httpx.ErrorResponse(code, message, httpx.WithParam("messages")))
}
