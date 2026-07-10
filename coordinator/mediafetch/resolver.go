package mediafetch

// resolver.go is the package entry point: Resolver walks a parsed OpenAI-style
// request for remote image_url/video_url references, fetches them under the
// SSRF/size/format policy (fetch.go, sniff.go, ssrf.go), and rewrites each URL
// in place as an inline base64 data: URI. All-or-nothing: on any failure nothing
// is mutated and a typed *Error is returned for the API layer to surface.

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
)

// Error is a typed resolution failure carrying the HTTP status + OpenAI-style
// error code to return to the consumer, a Public message, and a non-sensitive
// Internal diagnostic. Internal MUST NOT contain the request URL, host, query,
// fragment, credentials, or wrapped errors that may reproduce them: presigned
// media URLs commonly carry secrets and Error() may be logged by callers.
type Error struct {
	Status   int
	Code     string
	Public   string
	Internal string
}

func (e *Error) Error() string {
	if e.Internal != "" {
		return fmt.Sprintf("mediafetch: %s (%s): %s", e.Code, e.Public, e.Internal)
	}
	return fmt.Sprintf("mediafetch: %s (%s)", e.Code, e.Public)
}

// Result reports what a Resolve call did, for metrics.
type Result struct {
	Changed bool  // at least one URL was inlined (rawBody must be re-marshaled)
	Count   int   // number of media items fetched
	Bytes   int64 // total raw bytes fetched
}

// Resolver fetches remote media URLs into inline data: URIs under the SSRF and
// size policy in cfg. It is safe for concurrent use; construct once and reuse —
// the process-wide fetch semaphore lives on the instance.
type Resolver struct {
	cfg       Config
	client    *http.Client
	logger    *slog.Logger
	globalSem chan struct{} // caps in-flight fetches across ALL requests
}

// NewResolver builds a Resolver with a dedicated hardened http.Client. logger
// may be nil (a no-op logger is used).
func NewResolver(cfg Config, logger *slog.Logger) *Resolver {
	cfg = cfg.sanitized()
	if logger == nil {
		logger = slog.New(slog.DiscardHandler)
	}
	return &Resolver{
		cfg:       cfg,
		client:    newHTTPClient(cfg),
		logger:    logger,
		globalSem: make(chan struct{}, cfg.GlobalConcurrency),
	}
}

// Enabled reports whether remote-media fetching is turned on.
func (r *Resolver) Enabled() bool { return r.cfg.Enabled }

// mediaRef points at one resolvable URL inside the parsed request: the map that
// holds it, the key to overwrite with the data: URI, and the declared kind the
// fetched bytes must match (image_url → image, video_url → video).
type mediaRef struct {
	set  map[string]any
	key  string
	url  string
	kind mediaKind
}

// mediaFetch groups every mutable request location that references the same
// trimmed remote URL. The URL is downloaded once, then one data: URI is written
// to every target. A URL reused across image_url and video_url is rejected before
// network I/O because one byte stream cannot satisfy both declared media kinds.
type mediaFetch struct {
	request mediaRef
	targets []mediaRef
}

// Resolve walks an OpenAI-compatible request body (parsed JSON) for image_url /
// video_url content parts whose value is an http(s) URL, fetches each one under
// the SSRF + size + format policy, and replaces it in place with an inline data:
// URI. parsed is mutated; the caller must re-marshal it into rawBody when
// Changed.
//
// Resolve never fetches for a disabled feature: it returns a 400 Error if a
// remote URL is present while disabled (defense in depth — the API layer gates
// this case pre-reservation). Inline data: URIs and text-only requests are
// no-ops.
func (r *Resolver) Resolve(ctx context.Context, parsed map[string]any) (Result, error) {
	refs := collectMediaRefs(parsed)
	if len(refs) == 0 {
		return Result{}, nil
	}
	if !r.cfg.Enabled {
		return Result{}, &Error{Status: http.StatusBadRequest, Code: "remote_media_disabled",
			Public:   "remote media URLs are not enabled on this endpoint; send media as an inline base64 data: URI",
			Internal: "feature disabled via config"}
	}
	// Cap request locations BEFORE URL deduplication. Each target is rewritten
	// with the full base64 data URI, so allowing unbounded duplicate targets would
	// turn one bounded fetch into an oversized allocation/marshal DoS.
	if len(refs) > r.cfg.MaxParts {
		return Result{}, &Error{Status: http.StatusBadRequest, Code: "too_many_media_parts",
			Public:   fmt.Sprintf("too many remote media parts (%d); the maximum is %d", len(refs), r.cfg.MaxParts),
			Internal: fmt.Sprintf("%d remote targets > MaxParts %d", len(refs), r.cfg.MaxParts)}
	}
	fetches, err := groupMediaRefs(refs)
	if err != nil {
		return Result{}, err
	}

	// Bound the whole resolution step (independent of the request TTFT deadline).
	resolveCtx, cancel := context.WithTimeout(ctx, r.cfg.TotalDeadline)
	defer cancel()

	fetched, totalBytes, err := r.fetchAll(resolveCtx, fetches)
	if err != nil {
		return Result{}, err
	}

	// All fetches succeeded — apply mutations atomically.
	for i, fetch := range fetches {
		dataURI := toDataURI(fetched[i])
		for _, target := range fetch.targets {
			target.set[target.key] = dataURI
		}
	}
	return Result{Changed: true, Count: len(fetches), Bytes: totalBytes}, nil
}

func groupMediaRefs(refs []mediaRef) ([]mediaFetch, error) {
	fetches := make([]mediaFetch, 0, len(refs))
	byURL := make(map[string]int, len(refs))
	for _, ref := range refs {
		canonical, err := canonicalMediaURL(ref.url)
		if err != nil {
			return nil, err
		}
		ref.url = canonical
		if i, exists := byURL[ref.url]; exists {
			if fetches[i].request.kind != ref.kind {
				return nil, &Error{Status: http.StatusBadRequest, Code: "media_kind_mismatch",
					Public:   "the same remote media URL cannot be used as both image_url and video_url",
					Internal: "one URL declared with conflicting media kinds"}
			}
			fetches[i].targets = append(fetches[i].targets, ref)
			continue
		}
		byURL[ref.url] = len(fetches)
		fetches = append(fetches, mediaFetch{request: ref, targets: []mediaRef{ref}})
	}
	return fetches, nil
}

// canonicalMediaURL normalizes components that do not change the on-the-wire
// request target, so each target is fetched and kind-checked once: fragments are
// never sent by HTTP, scheme/host are case-insensitive, and explicit default
// ports are equivalent to omission. Path escaping and query order are preserved
// because origins can assign them application-specific semantics.
func canonicalMediaURL(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", &Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL could not be parsed", Internal: "URL parse failed"}
	}
	u.Scheme = strings.ToLower(u.Scheme)
	hostname := u.Hostname()
	if !strings.Contains(hostname, ":") {
		hostname = strings.ToLower(hostname)
	}
	port := u.Port()
	if (u.Scheme == "http" && port == "80") || (u.Scheme == "https" && port == "443") {
		port = ""
	}
	switch {
	case hostname == "":
		u.Host = ""
	case port != "":
		u.Host = net.JoinHostPort(hostname, port)
	case strings.Contains(hostname, ":"):
		u.Host = "[" + hostname + "]"
	default:
		u.Host = hostname
	}
	u.Fragment = ""
	return u.String(), nil
}

// fetchAll fetches every ref with bounded concurrency (per-request worker cap +
// the process-wide semaphore), enforcing the per-request aggregate byte cap. On
// the first error all remaining work is cancelled and the error is returned
// (atomic: the caller inlines nothing on failure).
func (r *Resolver) fetchAll(ctx context.Context, fetches []mediaFetch) ([]*fetchedMedia, int64, error) {
	out := make([]*fetchedMedia, len(fetches))

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var (
		mu         sync.Mutex
		firstErr   error
		totalBytes int64
	)
	fail := func(e error) {
		mu.Lock()
		if firstErr == nil {
			firstErr = e
			cancel() // stop the other in-flight fetches
		}
		mu.Unlock()
	}
	// ctxCancelled records a slot/semaphore wait that ended by cancellation. If a
	// sibling already set firstErr, fail() is a no-op and the real error is
	// preserved; otherwise (parent deadline / client disconnect) the timeout error
	// stands, and out[i] is never left nil for Resolve to dereference in toDataURI.
	ctxCancelled := func() {
		if errors.Is(ctx.Err(), context.Canceled) {
			fail(context.Canceled)
			return
		}
		fail(&Error{Status: http.StatusRequestTimeout, Code: "media_fetch_timeout",
			Public: "media fetching did not complete in time", Internal: ctx.Err().Error()})
	}

	sem := make(chan struct{}, r.cfg.Concurrency)
	totalBudget := newByteBudget(r.cfg.MaxTotalBytes)
	var wg sync.WaitGroup
	for i, fetch := range fetches {
		wg.Add(1)
		go func(i int, fetch mediaFetch) {
			defer wg.Done()
			// Per-request worker slot.
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				ctxCancelled()
				return
			}
			// Process-wide fetch slot: bounds coordinator-wide outbound sockets
			// under a burst of media-heavy requests.
			select {
			case r.globalSem <- struct{}{}:
				defer func() { <-r.globalSem }()
			case <-ctx.Done():
				ctxCancelled()
				return
			}

			m, e := r.fetchOne(ctx, fetch.request, r.cfg.MaxFileBytes, totalBudget)
			if e != nil {
				var me *Error
				if errors.As(e, &me) {
					r.logger.Warn("media fetch rejected", "code", me.Code, "status", me.Status)
				} else {
					r.logger.Warn("media fetch rejected", "code", "unknown")
				}
				fail(e)
				return
			}

			mu.Lock()
			totalBytes += int64(len(m.data))
			total := totalBytes // snapshot under lock; other goroutines keep writing totalBytes
			mu.Unlock()
			if total > r.cfg.MaxTotalBytes { // invariant backstop; budget.go enforces during reads
				fail(&Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
					Public:   "combined media exceeds the maximum allowed size for one request",
					Internal: fmt.Sprintf("aggregate %d > MaxTotalBytes %d", total, r.cfg.MaxTotalBytes)})
				return
			}
			out[i] = m
		}(i, fetch)
	}
	wg.Wait()

	if firstErr != nil {
		return nil, 0, firstErr
	}
	return out, totalBytes, nil
}

// HasRemoteMedia reports whether parsed carries any http(s) media URL this
// package would fetch. Used by the API layer's sealed-request gate, which must
// reject (never fetch) such a request without touching the network.
func HasRemoteMedia(parsed map[string]any) bool {
	return len(collectMediaRefs(parsed)) > 0
}

// IsFetchableRemotePart reports whether pm is an OpenAI image_url/video_url part
// carrying an http(s) URL in a shape Resolve can mutate. It deliberately judges
// the part's shape/location, not just its URL string: an unsupported Anthropic
// source block remains unsupported even when another OpenAI part uses the same
// URL.
func IsFetchableRemotePart(pm map[string]any) bool {
	typ, _ := pm["type"].(string)
	key, kind, ok := mediaKeyForType(typ)
	if !ok {
		return false
	}
	_, ok = mediaRefFromPart(pm, key, kind)
	return ok
}

// collectMediaRefs walks messages[].content[] for OpenAI-shaped image_url /
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
func collectMediaRefs(parsed map[string]any) []mediaRef {
	var refs []mediaRef
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
			key, kind, ok := mediaKeyForType(typ)
			if !ok {
				continue
			}
			if ref, ok := mediaRefFromPart(pm, key, kind); ok {
				refs = append(refs, ref)
			}
		}
	}
	return refs
}

// mediaKeyForType maps a content-part type to the part field that carries its
// URL and the kind the fetched bytes must match. Only the types the Swift
// provider actually consumes as media (image_url/video_url → .imageURL/.videoURL)
// are resolved.
func mediaKeyForType(typ string) (key string, kind mediaKind, ok bool) {
	switch typ {
	case "image_url":
		return "image_url", kindImage, true
	case "video_url":
		return "video_url", kindVideo, true
	default:
		return "", "", false
	}
}

// mediaRefFromPart extracts a mutable handle to the http(s) URL inside a part's
// media field, handling both the object ({"url":…}) and bare-string forms.
func mediaRefFromPart(pm map[string]any, key string, kind mediaKind) (mediaRef, bool) {
	switch v := pm[key].(type) {
	case string:
		if isRemoteMediaURL(v) {
			return mediaRef{set: pm, key: key, url: v, kind: kind}, true
		}
	case map[string]any:
		if u, ok := v["url"].(string); ok && isRemoteMediaURL(u) {
			return mediaRef{set: v, key: "url", url: u, kind: kind}, true
		}
	}
	return mediaRef{}, false
}
