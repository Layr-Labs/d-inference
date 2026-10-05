package promptcontract

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/internal/promptcontract/artifacts"
)

const DefaultArtifactRoot = artifacts.DefaultArtifactRoot

var (
	ErrArtifactUnavailable = artifacts.ErrArtifactUnavailable
	ErrArtifactIntegrity   = artifacts.ErrArtifactIntegrity
	ErrUnsafeArtifactPath  = artifacts.ErrUnsafeArtifactPath
)

type ArtifactCacheConfig = artifacts.ArtifactCacheConfig
type ArtifactCache struct{ cache *artifacts.ArtifactCache }

func NewArtifactCache(config ArtifactCacheConfig) (*ArtifactCache, error) {
	cache, err := artifacts.NewArtifactCache(config)
	if err != nil {
		return nil, err
	}
	return &ArtifactCache{cache: cache}, nil
}

func (c *ArtifactCache) Ensure(ctx context.Context, manifest Manifest) (string, error) {
	return c.cache.Ensure(ctx, manifest)
}
