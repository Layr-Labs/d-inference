package mediafetch

// resolver.go is the package entry point: Resolver walks a parsed OpenAI-style
// request for remote image_url/video_url references, fetches them under the
// SSRF/size/format policy (fetch.go, sniff.go, ssrf.go), and rewrites each URL
// in place as an inline base64 data: URI. All-or-nothing: on any failure nothing
// is mutated and a typed *Error is returned for the API layer to surface.

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"sync"
)

// Error is a typed resolution failure carrying the HTTP status + OpenAI-style
// error code to return to the consumer, a Public (safe) message, and an Internal
// detail (may contain the URL/host) for server-side logs only.
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
	if len(refs) > r.cfg.MaxParts {
		return Result{}, &Error{Status: http.StatusBadRequest, Code: "too_many_media_parts",
			Public:   fmt.Sprintf("too many remote media items (%d); the maximum is %d", len(refs), r.cfg.MaxParts),
			Internal: fmt.Sprintf("%d refs > MaxParts %d", len(refs), r.cfg.MaxParts)}
	}

	// Bound the whole resolution step (independent of the request TTFT deadline).
	resolveCtx, cancel := context.WithTimeout(ctx, r.cfg.TotalDeadline)
	defer cancel()

	fetched, totalBytes, err := r.fetchAll(resolveCtx, refs)
	if err != nil {
		return Result{}, err
	}

	// All fetches succeeded — apply mutations atomically.
	for i, ref := range refs {
		ref.set[ref.key] = toDataURI(fetched[i])
	}
	return Result{Changed: true, Count: len(refs), Bytes: totalBytes}, nil
}

// fetchAll fetches every ref with bounded concurrency (per-request worker cap +
// the process-wide semaphore), enforcing the per-request aggregate byte cap. On
// the first error all remaining work is cancelled and the error is returned
// (atomic: the caller inlines nothing on failure).
func (r *Resolver) fetchAll(ctx context.Context, refs []mediaRef) ([]*fetchedMedia, int64, error) {
	out := make([]*fetchedMedia, len(refs))

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
		fail(&Error{Status: http.StatusRequestTimeout, Code: "media_fetch_timeout",
			Public: "media fetching did not complete in time", Internal: ctx.Err().Error()})
	}

	sem := make(chan struct{}, r.cfg.Concurrency)
	var wg sync.WaitGroup
	for i, ref := range refs {
		wg.Add(1)
		go func(i int, ref mediaRef) {
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

			m, e := r.fetchOne(ctx, ref, r.cfg.MaxFileBytes)
			if e != nil {
				r.logger.Warn("media fetch rejected", "error", e)
				fail(e)
				return
			}

			mu.Lock()
			totalBytes += int64(len(m.data))
			total := totalBytes // snapshot under lock; other goroutines keep writing totalBytes
			mu.Unlock()
			if total > r.cfg.MaxTotalBytes {
				fail(&Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
					Public:   "combined media exceeds the maximum allowed size for one request",
					Internal: fmt.Sprintf("aggregate %d > MaxTotalBytes %d", total, r.cfg.MaxTotalBytes)})
				return
			}
			out[i] = m
		}(i, ref)
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

// RemoteMediaURLs returns the set of remote http(s) URLs this package would
// fetch from parsed. The API layer uses it to detect remote references in
// OTHER (non-fetchable) part shapes — e.g. Anthropic source blocks — which must
// keep today's pre-dispatch rejection instead of sailing through image-blind.
func RemoteMediaURLs(parsed map[string]any) map[string]bool {
	refs := collectMediaRefs(parsed)
	if len(refs) == 0 {
		return nil
	}
	out := make(map[string]bool, len(refs))
	for _, ref := range refs {
		out[ref.url] = true
	}
	return out
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
