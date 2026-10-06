package postgres

import "github.com/eigeninference/d-inference/coordinator/store"

var _ store.MachineRewardStore = (*PostgresStore)(nil)
