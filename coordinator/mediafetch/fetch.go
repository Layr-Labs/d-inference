package mediafetch

import (
	"context"
	"encoding/base64"
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

// allowedImagePrefixes / allowedVideoPrefixes are the sniffed content-type
// prefixes accepted for inlining. The data: URI is built from the SNIFFED type
// (http.DetectContentType), never the spoofable Content-Type header.
var (
	allowedImagePrefixes = []string{"image/"}
	allowedVideoPrefixes = []string{"video/"}
)

// fetchedMedia is the result of a successful fetch: validated bytes plus the
// sniffed MIME type used to build the data: URI.
type fetchedMedia struct {
	mime string
	data []byte
}

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
		MaxIdleConns:          cfg.Concurrency,
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
		if len(via) >= maxRedirects {
			return fmt.Errorf("%w: too many redirects (>%d)", errBlockedHost, maxRedirects)
		}
		if err := validateURL(req.URL, cfg.BlocklistDomains); err != nil {
			return err
		}
		return nil
	}
}

// validateURL enforces the scheme allowlist, rejects embedded userinfo, and
// applies the domain blocklist. IP-level SSRF is enforced at dial time.
func validateURL(u *url.URL, blocklist map[string]bool) error {
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
	return hostAllowed(u.Host, blocklist)
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
// the content, and returns the bytes plus sniffed MIME type. The per-fetch
// timeout is applied via ctx so it is independent of the request TTFT deadline.
func (r *Resolver) fetchOne(ctx context.Context, rawURL string, maxBytes int64) (*fetchedMedia, error) {
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return nil, &Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL could not be parsed", Internal: fmt.Sprintf("parse %q: %v", rawURL, err)}
	}
	if err := validateURL(u, r.cfg.BlocklistDomains); err != nil {
		return nil, classifyURLError(err, rawURL)
	}

	fetchCtx, cancel := context.WithTimeout(ctx, r.cfg.FetchTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(fetchCtx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, &Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL could not be requested", Internal: err.Error()}
	}
	req.Header.Set("Accept", "image/*,video/*")
	req.Header.Set("Accept-Encoding", "identity") // belt-and-suspenders with DisableCompression
	req.Header.Set("User-Agent", "darkbloom-coordinator-mediafetch")

	resp, err := r.client.Do(req)
	if err != nil {
		return nil, classifyFetchError(err, rawURL)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, &Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
			Public:   "a media URL could not be retrieved",
			Internal: fmt.Sprintf("GET %q returned %d", rawURL, resp.StatusCode)}
	}

	// Pre-check the declared length to reject obvious oversize before reading.
	if resp.ContentLength > maxBytes {
		return nil, &Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
			Public:   "a media file exceeds the maximum allowed size",
			Internal: fmt.Sprintf("%q Content-Length %d > cap %d", rawURL, resp.ContentLength, maxBytes)}
	}

	// Read at most maxBytes+1 so we can detect overflow without buffering more.
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil {
		return nil, classifyFetchError(err, rawURL)
	}
	if int64(len(data)) > maxBytes {
		return nil, &Error{Status: http.StatusRequestEntityTooLarge, Code: "media_too_large",
			Public:   "a media file exceeds the maximum allowed size",
			Internal: fmt.Sprintf("%q body exceeded cap %d", rawURL, maxBytes)}
	}
	if len(data) == 0 {
		return nil, &Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
			Public: "a media URL returned an empty body", Internal: fmt.Sprintf("%q empty body", rawURL)}
	}

	mime := sniffMediaType(data)
	if mime == "" {
		return nil, &Error{Status: http.StatusBadRequest, Code: "media_invalid_type",
			Public:   "a media URL did not return an image or video",
			Internal: fmt.Sprintf("%q sniffed type %q not image/video", rawURL, http.DetectContentType(data))}
	}
	return &fetchedMedia{mime: mime, data: data}, nil
}

// sniffMediaType returns the sniffed image/* or video/* type, or "" if the bytes
// are neither. The sniffed type (not the response header) is authoritative, so a
// server claiming image/png while serving HTML/SVG/an archive is rejected.
func sniffMediaType(data []byte) string {
	ct := http.DetectContentType(data) // e.g. "image/png", "video/mp4", "text/plain; charset=utf-8"
	base := strings.TrimSpace(strings.SplitN(ct, ";", 2)[0])
	for _, p := range allowedImagePrefixes {
		if strings.HasPrefix(base, p) {
			return base
		}
	}
	for _, p := range allowedVideoPrefixes {
		if strings.HasPrefix(base, p) {
			return base
		}
	}
	return ""
}

// toDataURI encodes fetched media as a standard base64 data: URI.
func toDataURI(m *fetchedMedia) string {
	return "data:" + m.mime + ";base64," + base64.StdEncoding.EncodeToString(m.data)
}

// classifyURLError maps a pre-flight validateURL failure to a typed Error.
func classifyURLError(err error, rawURL string) *Error {
	switch {
	case errors.Is(err, errBlockedScheme):
		return &Error{Status: http.StatusBadRequest, Code: "media_invalid_scheme",
			Public: "media URLs must use http or https", Internal: err.Error()}
	case errors.Is(err, errBlockedHost):
		return &Error{Status: http.StatusForbidden, Code: "media_blocked",
			Public: "a media URL host is not allowed", Internal: err.Error()}
	default:
		return &Error{Status: http.StatusBadRequest, Code: "invalid_media_url",
			Public: "a media URL is invalid", Internal: err.Error()}
	}
}

// classifyFetchError maps a client.Do / read failure to a typed Error: SSRF
// blocks → 403, timeouts → 408, everything else → 502. Consumer-facing messages
// never echo the URL; the URL/cause is kept in Internal for server-side logs.
func classifyFetchError(err error, rawURL string) *Error {
	switch {
	case errors.Is(err, errBlockedIP):
		return &Error{Status: http.StatusForbidden, Code: "media_blocked",
			Public: "a media URL resolves to a disallowed address", Internal: err.Error()}
	case errors.Is(err, errBlockedScheme):
		return &Error{Status: http.StatusBadRequest, Code: "media_invalid_scheme",
			Public: "media URLs must use http or https", Internal: err.Error()}
	case errors.Is(err, errBlockedHost):
		return &Error{Status: http.StatusForbidden, Code: "media_blocked",
			Public: "a media URL host is not allowed", Internal: err.Error()}
	case errors.Is(err, context.DeadlineExceeded) || isTimeout(err):
		return &Error{Status: http.StatusRequestTimeout, Code: "media_fetch_timeout",
			Public: "a media URL took too long to fetch", Internal: err.Error()}
	default:
		return &Error{Status: http.StatusBadGateway, Code: "media_fetch_failed",
			Public: "a media URL could not be retrieved", Internal: err.Error()}
	}
}

// isTimeout unwraps net.Error timeouts (e.g. *url.Error wrapping a dial timeout).
func isTimeout(err error) bool {
	var ne net.Error
	return errors.As(err, &ne) && ne.Timeout()
}
