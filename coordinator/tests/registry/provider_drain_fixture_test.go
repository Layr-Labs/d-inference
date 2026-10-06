package registry_test

import (
	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerdrain"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"nhooyr.io/websocket"
)

type providerDrainAuthorities map[string]*providerdrain.Authority

func (f providerDrainAuthorities) bind(id string) *providerdrain.Authority {
	authority := &providerdrain.Authority{}
	f[id] = authority
	return authority
}

type retainedWriterFactory struct{ writer *providerwrite.Writer }

func (f retainedWriterFactory) Open(_ string, _ *websocket.Conn) *providerwrite.Writer {
	return f.writer
}
