package mediafetch

// fetch.go owns the hardened outbound HTTP path: a dedicated one-shot client
// whose every dial runs the SSRF Control hook (ssrf.go), redirect re-validation,
// size-capped reads, and the typed error classification the API layer maps to
// consumer-facing responses.

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// maxRedirects bounds redirect-chain depth. Every hop is re-validated (scheme,
// userinfo, blocklist) and every dial is IP-checked by the Control hook, so this
// only needs to stop loops / unbounded chains.
const maxRedirects = 3

// newHTTPClient builds the dedicated, hardened http.Client used for media
// fetches. It is isolated from the coordinator's other outbound clients (small
// connection pool) so a media-fetch storm can't starve provider/registry traffic.
func newHTTPClient(cfg Config) *http.Client {
	dialer := &net.Dialer{
		Timeout:   cfg.FetchTimeout,
		KeepAlive: -1, // no keep-alive: each fetch is one-shot
		Control:   dialControl(cfg.AllowPrivateIPs),
	}
	transport := &http.Transport{
		DialContext:           dialer.DialContext,
		DisableKeepAlives:     true,
		DisableCompression:    true, // never auto-inflate: defeats gzip/zip bombs
		ForceAttemptHTTP2:     false,
		MaxIdleConns:          cfg.GlobalConcurrency,
		MaxConnsPerHost:       cfg.Concurrency,
		TLSHandshakeTimeout:   cfg.FetchTimeout,
		ResponseHeaderTimeout: cfg.FetchTimeout,
		ExpectContinueTimeout: time.Second,
	}
	return &http.Client{
		Transport:     transport,
		Timeout:       cfg.FetchTimeout,
		CheckRedirect: redirectGuard(cfg),
	}
}

// redirectGuard validates each redirect hop: scheme allowlist, no embedded
// credentials, and the optional domain blocklist. The IP of every hop is still
// validated independently by the dialer Control hook. Depth is capped.
func redirectGuard(cfg Config) func(req *http.Request, via []*http.Request) error {
	return func(req *http.Request, via []*http.Request) error {
		// Strip the Referer Go's client auto-populates from the previous hop.
		// The previous URL can be a presigned S3/R2/GCS link whose query string
		// carries the signature; without this a cross-host redirect would leak
		// that signed URL to the redirect target, defeating the URL-secrecy the
		// rest of this package preserves.
		req.Header.Del("Referer")
		if len(via) >= maxRedirects {
			return fmt.Errorf("%w: too many redirects (>%d)", errBlockedHost, maxRedirects)
		}
		return validateURL(req.URL, cfg)
	}
}

// validateURL enforces the scheme + port allowlists, rejects embedded userinfo,
// and applies the domain blocklist. IP-level SSRF is enforced at dial time.
func validateURL(u *url.URL, cfg Config) error {
	scheme := strings.ToLower(u.Scheme)
	if scheme != "http" && scheme != "https" {
		return fmt.Errorf("%w: %q (only http/https)", errBlockedScheme, u.Scheme)
	}
	if u.User != nil {
		return fmt.Errorf("%w: embedded credentials are not allowed", errBlockedHost)
	}
	if u.Host == "" {
		return fmt.Errorf("%w: empty host", errBlockedHost)
	}
	if !cfg.AllowNonStandardPorts {
		port := u.Port()
		if (scheme == "http" && port != "" && port != "80") ||
			(scheme == "https" && port != "" && port != "443") {
			return fmt.Errorf("%w: non-standard %s port %q is not allowed", errBlockedHost, scheme, port)
		}
	}
	return hostAllowed(u.Host, cfg.BlocklistDomains)
}

// isRemoteMediaURL reports whether s is an http(s) URL (as opposed to an inline
// data: URI, which is passed through untouched, or some other scheme).
func isRemoteMediaURL(s string) bool {
	t := strings.TrimSpace(s)
	if len(t) < 7 {
		return false
	}
	lower := strings.ToLower(t)
	return strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://")
}

// fetchOne downloads one media URL under the SSRF policy and size cap, validates
// the content structurally (allowlist, declared-kind match, pixel cap), and
// returns the bytes plus sniffed MIME type. The per-fetch timeout is applied via
// ctx so it is independent of the request TTFT deadline.
func (r *Resolver) fetchOne(ctx context.Context, ref mediaRef, maxBytes int64, totalBudget *byteBudget) (*fetchedMedia, error) {
	u, err := url.Parse(strings.TrimSpace(ref.url))
	if err != nil {
		return nil, &Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL could not be parsed", Internal: "URL parse failed"}
	}
	if err := validateURL(u, r.cfg); err != nil {
		return nil, classifyURLError(err)
	}

	fetchCtx, cancel := context.WithTimeout(ctx, r.cfg.FetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(fetchCtx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, &Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL could not be requested", Internal: "request construction failed"}
	}
	req.Header.Set("Accept", "image/*,video/*")
	req.Header.Set("Accept-Encoding", "identity") // belt-and-suspenders with DisableCompression
	req.Header.Set("User-Agent", "darkbloom-coordinator-mediafetch")

	resp, err := r.client.Do(req)
	if err != nil {
		return nil, classifyFetchError(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, &Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
			Public:   "a media URL could not be retrieved",
			Internal: fmt.Sprintf("upstream returned HTTP %d", resp.StatusCode)}
	}

	// Pre-check the declared length to reject obvious oversize before reading.
	if resp.ContentLength > maxBytes {
		return nil, &Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
			Public:   "a media file exceeds the maximum allowed size",
			Internal: fmt.Sprintf("Content-Length %d > cap %d", resp.ContentLength, maxBytes)}
	}

	// Read at most maxBytes+1 so we can detect overflow without buffering more —
	// the LimitReader (not the header) is the enforced cap.
	// Layer the per-file reader under the SHARED per-request budget. The shared
	// budget allows only MaxTotalBytes+1 bytes across all concurrent fetches, so
	// four 8 MiB responses can never transiently retain 32 MiB before the 10 MiB
	// aggregate check notices. The +1 byte distinguishes exactly-at-cap EOF from
	// overflow without buffering more than one byte past the aggregate limit.
	data, err := io.ReadAll(totalBudget.reader(io.LimitReader(resp.Body, maxBytes+1)))
	if err != nil {
		if errors.Is(err, errAggregateBudgetExceeded) {
			return nil, &Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
				Public:   "combined media exceeds the maximum allowed size for one request",
				Internal: fmt.Sprintf("aggregate body exceeded cap %d", totalBudget.limit)}
		}
		return nil, classifyFetchError(err)
	}
	if int64(len(data)) > maxBytes {
		return nil, &Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
			Public:   "a media file exceeds the maximum allowed size",
			Internal: fmt.Sprintf("response body exceeded cap %d", maxBytes)}
	}
	if len(data) == 0 {
		return nil, &Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
			Public: "a media URL returned an empty body", Internal: "upstream returned an empty body"}
	}

	mime, err := r.validateFetchedMedia(ref.kind, data)
	if err != nil {
		return nil, err
	}
	return &fetchedMedia{mime: mime, data: data}, nil
}

// classifyURLError maps a pre-flight validateURL failure to a typed Error.
func classifyURLError(err error) *Error {
	switch {
	case errors.Is(err, errBlockedScheme):
		return &Error{Status: http.StatusBadRequest, Code: "media_invalid_scheme",
			Public: "media URLs must use http or https", Internal: "URL scheme blocked"}
	case errors.Is(err, errBlockedHost):
		return &Error{Status: http.StatusForbidden, Code: "media_blocked",
			Public: "a media URL host is not allowed", Internal: "URL host or port blocked"}
	default:
		return &Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL is invalid", Internal: "URL validation failed"}
	}
}

// classifyFetchError maps a client.Do / read failure to a typed Error: SSRF
// blocks → 403, timeouts → 408, everything else → 502. Consumer-facing messages
// never echo the URL; the URL/cause is kept in Internal for server-side logs.
func classifyFetchError(err error) error {
	switch {
	case errors.Is(err, context.Canceled):
		return context.Canceled
	case errors.Is(err, errBlockedIP):
		return &Error{Status: http.StatusForbidden, Code: "media_blocked",
			Public: "a media URL resolves to a disallowed address", Internal: "resolved address blocked"}
	case errors.Is(err, errBlockedScheme):
		return &Error{Status: http.StatusBadRequest, Code: "media_invalid_scheme",
			Public: "media URLs must use http or https", Internal: "redirect scheme blocked"}
	case errors.Is(err, errBlockedHost):
		return &Error{Status: http.StatusForbidden, Code: "media_blocked",
			Public: "a media URL host is not allowed", Internal: "redirect host or port blocked"}
	case errors.Is(err, context.DeadlineExceeded) || isTimeout(err):
		return &Error{Status: http.StatusRequestTimeout, Code: "media_fetch_timeout",
			Public: "a media URL took too long to fetch", Internal: "fetch deadline exceeded"}
	default:
		return &Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
			Public: "a media URL could not be retrieved", Internal: "network request failed"}
	}
}

// isTimeout unwraps net.Error timeouts (e.g. *url.Error wrapping a dial timeout).
func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}
