package ingress

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/mediafetch"
)

// gateRemoteMediaPreDispatch is phase 1 (pre-billing) of remote media handling
// on the chat surface. handled=true => a terminal response was written and the
// caller must return.
func (s *Controller) gateRemoteMediaPreDispatch(w http.ResponseWriter, r *http.Request, parsed map[string]any, model, publicModel string, requiresVision, hasTools bool) (handled bool) {
	if !requiresVision {
		return false
	}
	reject := func(msg string) bool {
		s.writeRemoteMediaRejection(w, r, parsed, model, publicModel, hasTools, msg)
		return true
	}
	scan := scanRemoteMediaRefs(parsed)
	switch {
	case scan.firstRemote == "":
		// Inline data: URIs and text-only requests never reach the fetcher.
		return false
	case s.deps.MediaResolver() == nil || !s.deps.MediaResolver().Enabled():
		// Resolver off means authoritative rollback to the data:-only contract:
		// one clean pre-dispatch 400 instead of a provider-side one. Same message
		// rejectRemoteMediaURLs writes on the generic surface, which never fetches.
		return reject("image/video input must be an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"); " +
			"remote http(s):// and file:// media URLs are not supported on this endpoint. Got: " + truncateMediaRef(scan.firstRemote))
	case s.deps.SealedRequest(r):
		// Sender-sealed requests are never fetched, whatever shape the reference
		// takes: the sender opted into sealing the payload to the coordinator, and
		// a fetch would leak request-correlated egress to the URL's origin. This
		// keys off ANY remote reference, not just a fetchable one — telling a
		// sealed caller to "send an OpenAI http(s) link instead" would be advice
		// for something we will not do either.
		return reject("sealed requests must send media as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"); " +
			"remote image_url/video_url links are not fetched for sealed payloads — inline the media or disable request sealing")
	case scan.firstUnfetchable != "":
		// A remote reference in a shape the resolver does NOT fetch (Anthropic
		// source blocks, Responses input_image parts, file:// and other schemes)
		// keeps today's clean 400: dispatching it would either 400 across the
		// fleet or be silently dropped by the provider (an image-blind answer).
		return reject("this media reference is not fetchable on this endpoint; send it as an OpenAI-style image_url/video_url http(s) link " +
			"or as an inline base64 data: URI (e.g. \"data:image/jpeg;base64,…\"). Got: " + truncateMediaRef(scan.firstUnfetchable))
	}
	return false
}

// remoteMediaScan answers, in one walk, the two different questions the gate
// asks about media references: is there ANY non-inline reference (sealed
// requests refuse them all), and is there one the resolver cannot fetch
// (everyone else refuses those). Deriving them from separate walks is how a
// sealed Anthropic source-URL request ended up being told to send an OpenAI
// link — advice for something a sealed request will never do either.
type remoteMediaScan struct {
	// firstRemote is the first non-inline media reference of ANY shape.
	firstRemote string
	// firstUnfetchable is the first non-inline reference the resolver will not
	// fetch, judged by the part's own shape and location rather than URL equality
	// with another part. Only OpenAI image_url/video_url http(s) parts under
	// messages[] are fetchable.
	firstUnfetchable string
}

// scanRemoteMediaRefs walks messages[] and input[] once. Like validateMediaParts
// it fails OPEN: a shape it cannot read is not treated as a remote reference.
func scanRemoteMediaRefs(parsed map[string]any) remoteMediaScan {
	var scan remoteMediaScan
	visit := func(content any, fetchableShapesAllowed bool) {
		parts, isArr := content.([]any)
		if !isArr {
			return
		}
		for _, p := range parts {
			pm, isMap := p.(map[string]any)
			if !isMap {
				continue
			}
			ref, isMedia := mediaPartURLString(pm)
			if !isMedia || ref == "" || isInlineDataURI(ref) {
				continue
			}
			if scan.firstRemote == "" {
				scan.firstRemote = ref
			}
			if scan.firstUnfetchable == "" &&
				!(fetchableShapesAllowed && mediafetch.IsFetchableRemotePart(pm)) {
				scan.firstUnfetchable = ref
			}
		}
	}
	if msgs, isArr := parsed["messages"].([]any); isArr {
		for _, m := range msgs {
			if mm, isMap := m.(map[string]any); isMap {
				visit(mm["content"], true)
			}
		}
	}
	if input, isArr := parsed["input"].([]any); isArr {
		for _, it := range input {
			if im, isMap := it.(map[string]any); isMap {
				visit(im["content"], false)
			}
		}
	}
	return scan
}
