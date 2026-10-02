package store

import "github.com/jackc/pgx/v5/pgxpool"

// StripeSettlementForMaintenance uses an already provisioned database without
// executing startup migrations. The caller owns and closes the pool. This narrow
// interface is for explicitly authorized payout repair tools, not server setup.
func StripeSettlementForMaintenance(pool *pgxpool.Pool) StripeSettlementStore {
	return &PostgresStore{pool: pool}
}
