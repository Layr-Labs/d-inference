package testbed

import (
	"context"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func NewMemoryStore() store.Store {
	return store.NewMemory(store.Config{AdminKey: "testbed-admin-key"})
}

func NewPostgresStore(ctx context.Context, databaseURL string) (store.Store, error) {
	pg, err := store.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		return nil, fmt.Errorf("connect to postgres: %w", err)
	}
	return pg, nil
}
