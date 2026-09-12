package testbed

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"time"
)

// A timed-out request cannot supply a later request's state or readiness.
func (o *ownedProvider) request(ctx context.Context, command, expected string, timeout time.Duration) (ownedHostEvent, error) {
	o.requestMu.Lock()
	defer o.requestMu.Unlock()
	if !o.running() {
		return ownedHostEvent{}, fmt.Errorf("owned provider is terminal")
	}
	o.mu.Lock()
	select {
	case <-o.state:
	default:
	}
	o.nextRequestID++
	id := o.nextRequestID
	o.activeRequestID = id
	o.mu.Unlock()
	defer func() { o.mu.Lock(); o.activeRequestID = 0; o.mu.Unlock() }()
	raw, _ := json.Marshal(struct {
		Command string `json:"command"`
		ID      uint64 `json:"id"`
	}{command, id})
	o.writeMu.Lock()
	_, err := o.stdin.Write(append(raw, '\n'))
	o.writeMu.Unlock()
	if err != nil {
		return ownedHostEvent{}, err
	}
	select {
	case event := <-o.state:
		if event.RequestID != id || event.Event != expected {
			return ownedHostEvent{}, fmt.Errorf("unexpected correlated host response")
		}
		return event, nil
	case <-ctx.Done():
		return ownedHostEvent{}, ctx.Err()
	case <-o.done:
		return ownedHostEvent{}, fmt.Errorf("owned provider ended during control request")
	case <-time.After(timeout):
		return ownedHostEvent{}, fmt.Errorf("owned control request timed out")
	}
}
func (o *ownedProvider) readState(ctx context.Context) ([]byte, error) {
	event, err := o.request(ctx, "state", "state", 10*time.Second)
	if err != nil {
		return nil, err
	}
	if event.Error == "not_ready" {
		return nil, fmt.Errorf("owned provider state: %w", fs.ErrNotExist)
	}
	if event.Error != "" {
		return nil, fmt.Errorf("owned state refused: %s", event.Error)
	}
	raw, err := base64.StdEncoding.DecodeString(event.Body)
	if err != nil || len(raw) > 1<<20 {
		return nil, fmt.Errorf("invalid bounded host state")
	}
	return raw, nil
}

func (o *ownedProvider) stop() error {
	o.stopOnce.Do(func() { _ = o.send("stop"); _ = o.stdin.Close() })
	select {
	case <-o.done:
		return o.failure()
	case <-time.After(45 * time.Second):
		return fmt.Errorf("owned host termination unconfirmed; retained process and evidence")
	}
}

// ReadState provides the same bounded snapshot across local and SSH targets.
func (p *Provider) ReadState(ctx context.Context) ([]byte, error) {
	if p.owned != nil {
		return p.owned.readState(ctx)
	}
	file, err := os.Open(p.DaemonStatePath())
	if err != nil {
		return nil, err
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, (1<<20)+1))
	if len(raw) > 1<<20 {
		return nil, fmt.Errorf("provider state exceeds limit")
	}
	return raw, err
}

// ObserveHost is read-only host telemetry; callers decide whether this is entry
// readiness or post-work cleanup rather than applying one predicate to both.
func (p *Provider) ObserveHost(ctx context.Context) (HostObservation, error) {
	if p.owned == nil {
		return HostObservation{}, fmt.Errorf("explicit owned host target required")
	}
	event, err := p.owned.request(ctx, "observe", "observation", 20*time.Second)
	return event.Observation, err
}
