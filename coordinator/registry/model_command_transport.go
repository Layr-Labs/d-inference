package registry

import "context"

// ModelCommandTransport is the outbound text-frame capability used by model
// lifecycle commands. It does not expose provider state or connection locks.
type ModelCommandTransport interface {
	WriteText(context.Context, []byte) error
}

type providerModelCommandTransport struct{ provider *Provider }

func (w providerModelCommandTransport) WriteText(ctx context.Context, data []byte) error {
	return w.provider.WriteText(ctx, data)
}

func (p *Provider) writeModelCommand(ctx context.Context, data []byte) error {
	if p.modelCommands != nil {
		return p.modelCommands.WriteText(ctx, data)
	}
	return p.WriteText(ctx, data)
}
