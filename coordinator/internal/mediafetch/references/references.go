package references

import (
	"math"
	"net/http"
	"net/url"
	"strings"

	mediapolicy "github.com/eigeninference/d-inference/coordinator/internal/mediafetch/policy"
)

// Ref points at one resolvable URL inside the parsed request: the map that
// holds it, the key to overwrite with the data: URI, and the declared kind the
// fetched bytes must match (image_url → image, video_url → video).
type Ref struct {
	Set  map[string]any
	Key  string
	URL  string
	Kind mediapolicy.Kind
}

// Fetch groups every mutable request location that references the same
// trimmed remote URL. The URL is downloaded once, then one data: URI is written
// to every target. A URL reused across image_url and video_url is rejected before
// network I/O because one byte stream cannot satisfy both declared media kinds.
type Fetch struct {
	Request Ref
	Targets []Ref
}

// ProjectedInlinedBytes reports how many bytes the inlined data: URIs occupy in
// the rewritten body: each fetch's URI counts once per request location that
// references it. MaxTotalBytes cannot express this — it bounds the raw bytes
// FETCHED, and a duplicated URL is fetched once but written back N times.
// Accumulation saturates rather than wrapping: a wrapped negative total would
// silently disable the very cap this feeds.
func ProjectedInlinedBytes(fetches []Fetch, dataURIs []string) int64 {
	var total int64
	for i, fetch := range fetches {
		size := int64(len(dataURIs[i]))
		for range fetch.Targets {
			if size > math.MaxInt64-total {
				return math.MaxInt64
			}
			total += size
		}
	}
	return total
}

func Group(refs []Ref) ([]Fetch, error) {
	fetches := make([]Fetch, 0, len(refs))
	byKey := make(map[string]int, len(refs))
	for _, ref := range refs {
		key, err := mediaFetchKey(ref.URL)
		if err != nil {
			return nil, err
		}
		if i, exists := byKey[key]; exists {
			if fetches[i].Request.Kind != ref.Kind {
				return nil, &mediapolicy.Error{Status: http.StatusBadRequest, Code: "media_kind_mismatch",
					Public:   "the same remote media URL cannot be used as both image_url and video_url",
					Internal: "one URL declared with conflicting media kinds"}
			}
			fetches[i].Targets = append(fetches[i].Targets, ref)
			continue
		}
		byKey[key] = len(fetches)
		fetches = append(fetches, Fetch{Request: ref, Targets: []Ref{ref}})
	}
	return fetches, nil
}

// mediaFetchKey returns the deduplication key for a media URL: two request
// locations share one fetch only when their keys match. It is ONLY a key — the
// URL requested is always the string the consumer sent, byte for byte.
//
// Normalized: the fragment (never put on the wire) and scheme/host case (both
// case-insensitive per RFC 3986, IPv6 hex included). Nothing else — in
// particular an explicit :80/:443 stays, because a presigned signature can cover
// the exact host:port and rewriting it turns a valid link into an upstream auth
// error. Cost: `https://h/a` and `https://h:443/a` are fetched twice; both still
// count against every byte cap, so nothing is bypassed.
func mediaFetchKey(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", &mediapolicy.Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL could not be parsed", Internal: "URL parse failed"}
	}
	u.Scheme = strings.ToLower(u.Scheme)
	u.Host = strings.ToLower(u.Host) // host, port digits and bracketed IPv6 hex
	u.Fragment = ""
	return u.String(), nil
}

// Collect walks messages[].content[] for OpenAI-shaped image_url /
// video_url parts whose URL is http(s), returning a mutable handle to each. Both
// the object form ({"image_url":{"url":…}}) and the bare-string form
// ({"image_url":"…"}) are handled. Inline data: URIs and non-http schemes are
// skipped.
//
// Scope: only the OpenAI image_url/video_url shapes are matched — these are the
// shapes the Swift provider consumes as media. Anthropic-native blocks on
// /v1/messages ({"type":"image","source":{"type":"url",…}}) are NOT collected;
// Anthropic source-URL inlining is out of scope (the provider does not decode
// that shape either — tracked as a follow-up). The Responses API `input` surface
// is likewise not walked; a media-bearing Responses request is rejected by
// visionToolsFailFast in the handler before dispatch.
func Collect(parsed map[string]any) []Ref {
	var refs []Ref
	messages, ok := parsed["messages"].([]any)
	if !ok {
		return nil
	}
	for _, m := range messages {
		mm, ok := m.(map[string]any)
		if !ok {
			continue
		}
		parts, ok := mm["content"].([]any)
		if !ok {
			continue
		}
		for _, part := range parts {
			pm, ok := part.(map[string]any)
			if !ok {
				continue
			}
			typ, _ := pm["type"].(string)
			key, kind, ok := KeyForType(typ)
			if !ok {
				continue
			}
			if ref, ok := FromPart(pm, key, kind); ok {
				refs = append(refs, ref)
			}
		}
	}
	return refs
}

// KeyForType maps a content-part type to the part field that carries its
// URL and the kind the fetched bytes must match. Only the types the Swift
// provider actually consumes as media (image_url/video_url → .imageURL/.videoURL)
// are resolved.
func KeyForType(typ string) (key string, kind mediapolicy.Kind, ok bool) {
	switch typ {
	case "image_url":
		return "image_url", mediapolicy.Image, true
	case "video_url":
		return "video_url", mediapolicy.Video, true
	default:
		return "", "", false
	}
}

// FromPart extracts a mutable handle to the http(s) URL inside a part's
// media field, handling both the object ({"url":…}) and bare-string forms.
func FromPart(pm map[string]any, key string, kind mediapolicy.Kind) (Ref, bool) {
	switch v := pm[key].(type) {
	case string:
		if mediapolicy.IsRemoteURL(v) {
			return Ref{Set: pm, Key: key, URL: v, Kind: kind}, true
		}
	case map[string]any:
		if u, ok := v["url"].(string); ok && mediapolicy.IsRemoteURL(u) {
			return Ref{Set: v, Key: "url", URL: u, Kind: kind}, true
		}
	}
	return Ref{}, false
}
