// Package session coordinates socket admission, shutdown and terminal barriers.
package session

import (
	"context"
	"nhooyr.io/websocket"
	"sync"
)

// Gate joins admitted handlers, including sockets not yet registered. Quiesce
// fences admission before a caller closes sockets or waits for their handlers.
type Gate struct {
	mu       sync.Mutex
	handlers sync.WaitGroup
	closing  bool
	conns    map[*websocket.Conn]struct{}
}

func (g *Gate) Admit() (done func(), ok bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.closing {
		return nil, false
	}
	g.handlers.Add(1)
	return g.handlers.Done, true
}

func (g *Gate) Track(conn *websocket.Conn, add bool) {
	g.mu.Lock()
	if g.conns == nil {
		g.conns = make(map[*websocket.Conn]struct{})
	}
	if !add {
		delete(g.conns, conn)
		g.mu.Unlock()
		return
	}
	g.conns[conn] = struct{}{}
	closing := g.closing
	g.mu.Unlock()
	if closing {
		_ = conn.CloseNow()
	}
}

func (g *Gate) Quiesce() []*websocket.Conn {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.closing = true
	conns := make([]*websocket.Conn, 0, len(g.conns))
	for conn := range g.conns {
		conns = append(conns, conn)
	}
	return conns
}

func (g *Gate) Closing() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.closing
}

func (g *Gate) ConnectionCount() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.conns)
}

func (g *Gate) Wait(ctx context.Context) bool {
	if !g.Closing() {
		return false
	}
	done := make(chan struct{})
	go func() { g.handlers.Wait(); close(done) }()
	select {
	case <-done:
		return true
	case <-ctx.Done():
		return false
	}
}
