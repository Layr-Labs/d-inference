// Package fetch makes the fixture's outbound requests: one to a host named by a
// package constant, one to a URL the caller supplies.
package fetch

import (
	"context"
	"io"
	"net/http"
	"sync"
)

// iconBase is a constant rather than an inline literal, the way real services
// keep base URLs — a walk that only looked at *ast.BasicLit would never see this
// boundary.
const iconBase = "https://icons.fixture.test/v1/"

// Client is concurrent state, not a value: the mutex and counter say it is
// mutated from more than one goroutine. That is the language-level fact the
// state-holder check keys on, so the overlay has to name it (or say @skip on
// purpose) instead of letting the package default absorb it.
type Client struct {
	hc *http.Client

	mu       sync.Mutex
	inflight int
}

// FetchIcons issues its request from an immediately-invoked goroutine closure,
// the shape a walk that only followed named callees would stop at.
func (c *Client) FetchIcons(ctx context.Context) {
	// Two calls to one helper, one of them concurrent, and both reach the same lines
	// of note through the same symbol — so the two are one piece of evidence with two
	// timings. Collapsing them must keep the earliest one's call path and the strongest
	// one's kind *separately*: a walk that let the promotion repaint the path would
	// draw a goroutine over a wire with no `go` on it and, worse, suppress the field
	// that exists to say the arrow and the path are two different touches.
	c.note()
	go c.note()

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, iconBase+"all", nil)
		if err != nil {
			return
		}
		resp, err := c.hc.Do(req)
		if err != nil {
			return
		}
		defer resp.Body.Close()
		_, _ = io.Copy(io.Discard, resp.Body)
	}()
	wg.Wait()
}

// note is the helper both of FetchIcons' calls land in. It is a named function on
// purpose: an inline closure would be two symbols and so two pieces of evidence,
// which is the case that needs no dedupe at all.
func (c *Client) note() {
	c.mu.Lock()
	c.inflight++
	c.mu.Unlock()
}

// FetchOpaque requests whatever URL it is handed, so there is no literal and no
// field to attribute: the function itself is the boundary, declared in the
// overlay's deps.functions.
func (c *Client) FetchOpaque(ctx context.Context, url string) ([]byte, error) {
	c.mu.Lock()
	c.inflight++
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		c.inflight--
		c.mu.Unlock()
	}()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	return io.ReadAll(resp.Body)
}
