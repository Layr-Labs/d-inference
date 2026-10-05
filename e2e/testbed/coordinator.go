package testbed

import (
	"context"
	"fmt"

	"github.com/eigeninference/d-inference/coordinator/store"
	memorystore "github.com/eigeninference/d-inference/coordinator/store/memory"
	postgresstore "github.com/eigeninference/d-inference/coordinator/store/postgres"
)

func NewMemoryStore() store.Store {
	return memorystore.NewMemory(store.Config{AdminKey: "testbed-admin-key"})
}

func NewPostgresStore(ctx context.Context, databaseURL string) (store.Store, error) {
	pg, err := postgresstore.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		return nil, fmt.Errorf("connect to postgres: %w", err)
	}
	return pg, nil
}
