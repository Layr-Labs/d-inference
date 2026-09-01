// Package store is the fixture's persistence layer: an interface with two
// implementations, so the walker has to resolve dispatch to the preferred one to
// see any SQL at all.
package store

import (
	"context"
	"database/sql"
)

// Schema is the DDL the fixture declares. SchemaTables reads its table names, so
// a query naming anything else is drift, and SchemaDefinitions derives the
// published column list from it.
const Schema = `
CREATE TABLE models (
	id text PRIMARY KEY,
	name text NOT NULL,
	price numeric(10, 2) NOT NULL DEFAULT 0
);
ALTER TABLE models ADD COLUMN IF NOT EXISTS family text NOT NULL DEFAULT '';
CREATE TABLE usage (
	id text PRIMARY KEY,
	tokens bigint NOT NULL,
	created_at timestamptz NOT NULL DEFAULT now(),
	UNIQUE (id, created_at),
	CHECK(tokens >= 0)
);
CREATE INDEX usage_created_at_idx ON usage (created_at);
`

type Store interface {
	ListModels(ctx context.Context) ([]string, error)
	RecordUsage(ctx context.Context, id string, tokens int64) error
	UsageAge(ctx context.Context, id string) (float64, error)
}

// Postgres is the implementation the overlay prefers.
type Postgres struct {
	db *sql.DB
}

func (p *Postgres) ListModels(ctx context.Context) ([]string, error) {
	rows, err := p.db.QueryContext(ctx, `SELECT id, name FROM models ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id, name string
		if err := rows.Scan(&id, &name); err != nil {
			return nil, err
		}
		out = append(out, id+" "+name)
	}
	return out, rows.Err()
}

// RecordUsage writes one table while reading another, which is the shape that
// distinguishes a masked write target from a genuine read.
func (p *Postgres) RecordUsage(ctx context.Context, id string, tokens int64) error {
	_, err := p.db.ExecContext(ctx,
		`INSERT INTO usage (id, tokens) SELECT id, $2 FROM models WHERE id = $1`, id, tokens)
	return err
}

// UsageAge uses extract(epoch FROM ...), whose FROM does not introduce a table.
func (p *Postgres) UsageAge(ctx context.Context, id string) (float64, error) {
	var age float64
	err := p.db.QueryRowContext(ctx,
		`SELECT extract(epoch FROM now() - created_at) FROM usage WHERE id = $1`, id).Scan(&age)
	return age, err
}

// Memory is the dev fallback. It implements Store too, so a walker that ignored
// preferImpl would attribute the endpoints here and find no SQL.
type Memory struct {
	models []string
	usage  map[string]int64
}

func (m *Memory) ListModels(context.Context) ([]string, error) { return m.models, nil }

func (m *Memory) RecordUsage(_ context.Context, id string, tokens int64) error {
	m.usage[id] += tokens
	return nil
}

func (m *Memory) UsageAge(context.Context, string) (float64, error) { return 0, nil }
