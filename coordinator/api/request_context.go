package api

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/api/requestcontext"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func requestIDFromContext(ctx context.Context) string     { return requestcontext.RequestID(ctx) }
func consumerKeyFromContext(ctx context.Context) string   { return requestcontext.AccountID(ctx) }
func apiKeyFromContext(ctx context.Context) *store.APIKey { return requestcontext.APIKey(ctx) }
