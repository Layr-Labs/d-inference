package mediafetch

// resolver.go is the package entry point: Resolver walks a parsed OpenAI-style
// request for remote image_url/video_url references, fetches them under the
// SSRF/size/format policy in internal/mediafetch/policy, and rewrites each URL
// in place as an inline base64 data: URI. All-or-nothing: on any failure nothing
// is mutated and a typed *Error is returned for the API layer to surface.

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sync"

	mediapolicy "github.com/eigeninference/d-inference/coordinator/internal/mediafetch/policy"
	readbudget "github.com/eigeninference/d-inference/coordinator/internal/mediafetch/readbudget"
	mediarefs "github.com/eigeninference/d-inference/coordinator/internal/mediafetch/references"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

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
	cfg       mediapolicy.Config
	client    *http.Client
	logger    *slog.Logger
	globalSem chan struct{} // caps in-flight fetches across ALL requests
}

// NewResolver builds a Resolver with a dedicated hardened http.Client. logger
// may be nil (a no-op logger is used). cfg is clamped to safe bounds, so a
// programmatically supplied Config (api.ServerConfig.MediaFetch) can never
// disable a cap — the env path fails boot on the same values via Config.Check,
// but a direct embedder gets defense in depth plus a WARN naming the problem.
func NewResolver(cfg mediapolicy.Config, logger *slog.Logger) *Resolver {
	return NewResolverWithClient(cfg, logger, nil)
}

// NewResolverWithClient accepts a caller-owned outbound client. Nil selects the
// hardened default. A supplied client must enforce the same dial/redirect policy.
func NewResolverWithClient(cfg mediapolicy.Config, logger *slog.Logger, client *http.Client) *Resolver {
	if logger == nil {
		logger = slog.New(slog.DiscardHandler)
	}
	if err := cfg.Check(); err != nil {
		logger.Warn("media fetch config clamped to defaults", "detail", err.Error())
	}
	cfg = cfg.Sanitized()
	if cfg.AllowPrivateIPs || cfg.AllowNonStandardPorts {
		// These are dev/test escape hatches: together they turn the coordinator
		// into a LAN/port scanner reachable from any consumer prompt. Config.Check
		// deliberately does not reject them (single-host deployments need them),
		// so a boot WARN is the only signal an operator gets that a production
		// process is running without the full SSRF policy.
		logger.Warn("media fetch SSRF override enabled",
			"allow_private_ips", cfg.AllowPrivateIPs,
			"allow_nonstandard_ports", cfg.AllowNonStandardPorts,
		)
	}
	if client == nil {
		client = mediapolicy.NewHTTPClient(cfg)
	}
	return &Resolver{
		cfg:       cfg,
		client:    client,
		logger:    logger,
		globalSem: make(chan struct{}, cfg.GlobalConcurrency),
	}
}

// Enabled reports whether remote-media fetching is turned on.
//
// This is the value read at construction, NOT a live re-read. An earlier
// revision called env.EnvBool here on every request and advertised the kill
// switch as redeploy-free, which was wrong: os.Getenv returns the process
// environment captured at exec, so editing /etc/d-inference/env or reloading
// the unit changes nothing for a running coordinator. Flipping the switch
// requires recreating the process — see the rollback section of
// docs/operations/coordinator-deploy.md.
func (r *Resolver) Enabled() bool { return r.cfg.Enabled }

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
	refs := mediarefs.Collect(parsed)
	if len(refs) == 0 {
		return Result{}, nil
	}
	if !r.Enabled() { // live kill switch, same gate the API layer consults
		return Result{}, &mediapolicy.Error{Status: http.StatusBadRequest, Code: "remote_media_disabled",
			Public:   "remote media URLs are not enabled on this endpoint; send media as an inline base64 data: URI",
			Internal: "feature disabled via config"}
	}
	// Cap request locations BEFORE URL deduplication. Each target is rewritten
	// with the full base64 data URI, so allowing unbounded duplicate targets would
	// turn one bounded fetch into an oversized allocation/marshal DoS.
	if len(refs) > r.cfg.MaxParts {
		return Result{}, &mediapolicy.Error{Status: http.StatusBadRequest, Code: "too_many_media_parts",
			Public:   fmt.Sprintf("too many remote media parts (%d); the maximum is %d", len(refs), r.cfg.MaxParts),
			Internal: fmt.Sprintf("%d remote targets > MaxParts %d", len(refs), r.cfg.MaxParts)}
	}
	fetches, err := mediarefs.Group(refs)
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

	// Duplicate targets multiply one fetch into many inlined copies: the byte
	// caps bound what is FETCHED, not what is written back. Eight parts sharing
	// one in-budget URL inline eight copies of the same base64 blob, so project
	// the post-inline size BEFORE mutating anything — otherwise the coordinator
	// builds (and the marshaler retains) a body the API layer can only discard
	// afterwards. Each data: URI is built once here and reused for the writes.
	dataURIs := make([]string, len(fetches))
	for i := range fetches {
		dataURIs[i] = mediapolicy.DataURI(fetched[i])
	}
	if projected := mediarefs.ProjectedInlinedBytes(fetches, dataURIs); projected > r.cfg.MaxInlinedBytes {
		return Result{}, &mediapolicy.Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
			Public:   "the request exceeds the size limit once remote media is inlined; use smaller media or fewer attachments",
			Internal: fmt.Sprintf("projected inlined %d > MaxInlinedBytes %d", projected, r.cfg.MaxInlinedBytes)}
	}

	// All fetches succeeded and fit — apply mutations atomically.
	for i, fetch := range fetches {
		for _, target := range fetch.Targets {
			target.Set[target.Key] = dataURIs[i]
		}
	}
	return Result{Changed: true, Count: len(fetches), Bytes: totalBytes}, nil
}

// fetchAll fetches every ref with bounded concurrency (per-request worker cap +
// the process-wide semaphore), enforcing the per-request aggregate byte cap. On
// the first error all remaining work is cancelled and the error is returned
// (atomic: the caller inlines nothing on failure).
func (r *Resolver) fetchAll(ctx context.Context, fetches []mediarefs.Fetch) ([]*mediapolicy.Media, int64, error) {
	out := make([]*mediapolicy.Media, len(fetches))

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
		fail(&mediapolicy.Error{Status: http.StatusRequestTimeout, Code: "media_fetch_timeout",
			Public: "media fetching did not complete in time", Internal: ctx.Err().Error()})
	}

	sem := make(chan struct{}, r.cfg.Concurrency)
	totalBudget := readbudget.New(r.cfg.MaxTotalBytes)
	var wg sync.WaitGroup
	for i, fetch := range fetches {
		wg.Add(1)
		go func(i int, fetch mediarefs.Fetch) {
			defer wg.Done()
			// A panic on THIS goroutine kills the whole process: net/http only
			// recovers panics raised on the handler goroutine, never on one
			// spawned from it, and everything below runs the outbound HTTP/TLS
			// client and the image-header parsers over attacker-chosen bytes.
			// One malformed response must not take down every in-flight request
			// from every consumer.
			//
			// Defers run LIFO: saferun.Recover (registered last, so it runs
			// first) consumes the panic, logs it with a stack trace and fires
			// the panic metric; the guard below then turns the aborted worker
			// into a typed failure. The guard keys off "no result stored", which
			// also backstops any future return path that forgets to fail(): a
			// worker that leaves without storing a result MUST leave firstErr
			// set, or Resolve would dereference a nil out[i]. fail() keeps the
			// first error, so paths that already failed are unaffected.
			defer func() {
				if out[i] == nil {
					fail(&mediapolicy.Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
						Public: "failed to fetch remote media", Internal: "panic during media fetch"})
				}
			}()
			defer saferun.Recover(r.logger, "mediafetch.fetchOne")
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

			m, e := r.fetchOne(ctx, fetch.Request, r.cfg.MaxFileBytes, totalBudget)
			if e != nil {
				var me *mediapolicy.Error
				if errors.As(e, &me) {
					r.logger.Warn("media fetch rejected", "code", me.Code, "status", me.Status)
				} else {
					r.logger.Warn("media fetch rejected", "code", "unknown")
				}
				fail(e)
				return
			}

			mu.Lock()
			totalBytes += int64(len(m.Data))
			total := totalBytes // snapshot under lock; other goroutines keep writing totalBytes
			mu.Unlock()
			if total > r.cfg.MaxTotalBytes { // invariant backstop; budget.go enforces during reads
				fail(&mediapolicy.Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
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
	return len(mediarefs.Collect(parsed)) > 0
}

// IsFetchableRemotePart reports whether pm is an OpenAI image_url/video_url part
// carrying an http(s) URL in a shape Resolve can mutate. It deliberately judges
// the part's shape/location, not just its URL string: an unsupported Anthropic
// source block remains unsupported even when another OpenAI part uses the same
// URL.
func IsFetchableRemotePart(pm map[string]any) bool {
	typ, _ := pm["type"].(string)
	key, kind, ok := mediarefs.KeyForType(typ)
	if !ok {
		return false
	}
	_, ok = mediarefs.FromPart(pm, key, kind)
	return ok
}
