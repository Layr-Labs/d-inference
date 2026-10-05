package media

import (
	"net/http"
	"time"

	inreq "github.com/eigeninference/d-inference/coordinator/api/inference/request"
	firstcontent "github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/mediafetch"
)

// remoteMediaScan answers, in one walk, the two different questions the gate
// asks about media references: is there ANY non-inline reference (sealed
// requests refuse them all), and is there one the resolver cannot fetch
// (everyone else refuses those). Deriving them from separate walks is how a
// sealed Anthropic source-URL request ended up being told to send an OpenAI
// link — advice for something a sealed request will never do either.
type Scan struct {
	// firstRemote is the first non-inline media reference of ANY shape.
	FirstRemote string
	// firstUnfetchable is the first non-inline reference the resolver will not
	// fetch, judged by the part's own shape and location rather than URL equality
	// with another part. Only OpenAI image_url/video_url http(s) parts under
	// messages[] are fetchable.
	FirstUnfetchable string
}

// scanRemoteMediaRefs walks messages[] and input[] once. Like validateMediaParts
// it fails OPEN: a shape it cannot read is not treated as a remote reference.
func ScanRemoteRefs(parsed map[string]any) Scan {
	var scan Scan
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
			ref, isMedia := inreq.MediaPartURLString(pm)
			if !isMedia || ref == "" || inreq.IsInlineDataURI(ref) {
				continue
			}
			if scan.FirstRemote == "" {
				scan.FirstRemote = ref
			}
			if scan.FirstUnfetchable == "" &&
				!(fetchableShapesAllowed && mediafetch.IsFetchableRemotePart(pm)) {
				scan.FirstUnfetchable = ref
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
func FetchBudget(receivedAt time.Time, firstContentDeadline time.Duration) (budget time.Duration, bound bool) {
	if receivedAt.IsZero() || firstContentDeadline <= 0 {
		return 0, false
	}
	remaining := firstcontent.FirstTokenRemainingSince(receivedAt, firstContentDeadline)
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

// mediaRejectionReason maps a media-fetch failure's HTTP status onto the
// rejection-ledger reason_code, so the dashboards can tell a malformed consumer
// request apart from a blocked host, a slow origin and a broken upstream.
// Filing all of them as "bad_param" made every upstream fault look like a
// client bug. reason_code is a free-form TEXT column (store/postgres.go), so
// these values need no schema change.
func RejectionReason(status int) string {
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
