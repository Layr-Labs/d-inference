package schema

const RequestOutcomesTableDDL = `CREATE TABLE IF NOT EXISTS request_outcomes (
 id BIGSERIAL UNIQUE,
 coord_request_id TEXT PRIMARY KEY CHECK (coord_request_id <> ''),
 received_at TIMESTAMPTZ NOT NULL,
 updated_at TIMESTAMPTZ NOT NULL,
 revision BIGINT NOT NULL,
 evidence_conflict BOOLEAN NOT NULL DEFAULT FALSE,
 record JSONB NOT NULL
)`
