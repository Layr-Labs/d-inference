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
	if _, err := store.ApplyPostgresMigrations(ctx, databaseURL, store.MigrationOptions{}); err != nil {
		return nil, fmt.Errorf("migrate postgres: %w", err)
	}
	pg, err := store.NewPostgres(ctx, store.Config{DatabaseURL: databaseURL})
	if err != nil {
		return nil, fmt.Errorf("connect to postgres: %w", err)
	}
	if err := pg.ActivateCoordinatorOwnership(ctx, false); err != nil {
		pg.Close()
		return nil, fmt.Errorf("validate coordinator ownership: %w", err)
	}
	return pg, nil
}
