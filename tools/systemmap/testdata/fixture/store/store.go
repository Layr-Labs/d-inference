// Package store is the fixture's persistence layer: an interface with two
// implementations, so the walker has to resolve dispatch to the preferred one to
// see any SQL at all.
package store

import (
	"context"
	"database/sql"
	"fmt"
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

// modelColumns is the shared column list model queries select. Splicing it into a
// statement keeps the expression constant, so go/types folds the whole query —
// but only for a walker that asks for the folded value instead of classifying the
// two halves the statement was written as.
const modelColumns = `id, name, family, price`

// GetModel splices a constant column list into its statement, the shape most of
// the coordinator's reads use. No single literal here is a statement: the tail is
// " FROM models WHERE id = $1", which no grammar should accept on its own.
//
// Reached only by the direct-walk tests, so the route fixtures stay pinned to the
// shapes they were written for.
func (p *Postgres) GetModel(ctx context.Context, id string) (string, error) {
	var name string
	err := p.db.QueryRowContext(ctx,
		`SELECT `+modelColumns+` FROM models WHERE id = $1`, id).Scan(&name)
	return name, err
}

// ListModelsFiltered assembles its statement at run time, so the table it reads
// appears in no literal and no constant. Every other check stays silent — there is
// no unknown table and no unmapped field to find — which is what the
// opaque-query check exists to catch.
func (p *Postgres) ListModelsFiltered(ctx context.Context, family string) ([]string, error) {
	q := `SELECT id FROM `
	if family == "" {
		q += "models"
	} else {
		q += "models WHERE family = $1"
	}
	rows, err := p.db.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		out = append(out, id)
	}
	return out, rows.Err()
}

// ListModelsWithUsage is the shape a call count alone cannot catch: the base is a
// readable statement, so the body has one statement for its one database call and
// the tally balances — yet the appended fragment names a second table that no
// readable statement mentions. Only checking the fragment itself finds it.
//
// Reached only by the direct-walk tests.
func (p *Postgres) ListModelsWithUsage(ctx context.Context, all bool) error {
	q := `SELECT id FROM models WHERE id = $1`
	if all {
		q += ` UNION SELECT model FROM usage`
	}
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// CountRows splices the table name itself in at run time. The literal is a
// perfectly good statement — it parses, the tally balances — but the one thing
// the map wanted from it, the table, is the part that is missing.
//
// Reached only by the direct-walk tests.
func (p *Postgres) CountRows(ctx context.Context, table string) error {
	_, err := p.db.ExecContext(ctx, fmt.Sprintf(`SELECT count(*) FROM %s WHERE id = $1`, table))
	return err
}

// ListModelsJoined splices the second of two tables. The first one is readable, so
// a scan that stopped at the first table it recognized would call this clean and
// publish the route as touching only `models` — the exact silence the check exists
// to break, missed by the check itself.
//
// Reached only by the direct-walk tests.
func (p *Postgres) ListModelsJoined(ctx context.Context, other string) error {
	_, err := p.db.ExecContext(ctx,
		fmt.Sprintf(`SELECT m.id FROM models m JOIN %s u ON u.id = m.id`, other))
	return err
}

// LockModel appends a clause that ends at a keyword, which is what `q += " LIMIT
// $2"` and `q += " FOR UPDATE"` both look like to a scan reading the token after
// FROM/UPDATE. Nothing here is unreadable: the table is named literally, the
// fragment names none, and the report must stay empty.
//
// Reached only by the direct-walk tests.
func (p *Postgres) LockModel(ctx context.Context, id string) error {
	q := `SELECT id FROM models WHERE id = $1`
	q += ` FOR UPDATE`
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// InsertModel names its columns immediately after the table, with no space. That
// is ordinary readable SQL — `Tables` records the write — so a scan that read
// `models(id` as a table name spliced in at run time would report a statement it
// had already understood.
//
// Reached only by the direct-walk tests.
func (p *Postgres) InsertModel(ctx context.Context, id, name string) error {
	_, err := p.db.ExecContext(ctx,
		`INSERT INTO models(id, name) VALUES ($1, $2)`, id, name)
	return err
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
