package registry_test

import "context"

type modelCommandWriteFunc func(context.Context, []byte) error

func (f modelCommandWriteFunc) WriteText(ctx context.Context, data []byte) error {
	return f(ctx, data)
}
