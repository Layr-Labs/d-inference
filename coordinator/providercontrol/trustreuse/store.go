package trustreuse

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

type Store interface {
	ListProviderTrustReuse(ctx context.Context) ([]store.ProviderTrustReuse, error)
	UpsertProviderTrustReuse(ctx context.Context, rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) (store.ProviderTrustReuseWriteResult, error)
	RecoverProviderTrustReuse(ctx context.Context, rec store.ProviderTrustReuse, expectedRevocationGeneration uint64) (store.ProviderTrustReuseWriteResult, error)
	AdvanceProviderTrustReuseCoverage(ctx context.Context, seKeys []string, until time.Time) error
	RevokeProviderTrustReuse(ctx context.Context, seKey, revocationEventID string) (store.ProviderTrustReuse, error)
}
