package session

import (
	"context"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/providercontrol/challenge"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// Session owns connection-local state. Shared policy, scheduling and registry
// state remain in their existing owners, accessed at the original boundaries.
type Session struct {
	deps                Dependencies
	ctx                 context.Context
	loopCtx             context.Context
	conn                *websocket.Conn
	providerID          string
	request             *http.Request
	provider            *registry.Provider
	challenges          *challenge.Session
	schedulerSEKey      string
	schedulerGeneration uint64
	peerCloseStatus     websocket.StatusCode
}

func New(deps Dependencies) *Session { return &Session{deps: deps} }
