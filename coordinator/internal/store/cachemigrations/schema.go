package cachemigrations

// The chain hash column of earlier builds is dropped, and its values with it.
const DropChainHashDDL = `ALTER TABLE cache_routing_holders DROP COLUMN IF EXISTS anchor_chain_hash`

// Tables created by earlier builds of this branch pick up the columns added
// since; each ADD is a no-op once present.
const BackfillColumnsDDL = `ALTER TABLE cache_routing_holders
 ADD COLUMN IF NOT EXISTS measured_stage_ms DOUBLE PRECISION NOT NULL DEFAULT 0,
 ADD COLUMN IF NOT EXISTS measured_expires_at TIMESTAMPTZ,
 ADD COLUMN IF NOT EXISTS ready_boundary_mode TEXT NOT NULL DEFAULT ''`
