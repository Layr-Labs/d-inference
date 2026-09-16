package store

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/store/postgres"
)

type (
	PostgresStore = postgres.Store
)

func NewPostgres(ctx context.Context, scfg Config) (*PostgresStore, error) {
	return postgres.New(ctx, scfg)
}
