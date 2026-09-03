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

// ListModelsPaired names both of its tables in one fragment. A declaration for
// this body has to answer for each of them: a scan that recorded only the first
// name it read would let a `JOIN` added beside an already-declared table be
// absorbed by an entry that says nothing about it.
//
// Reached only by the direct-walk tests.
func (p *Postgres) ListModelsPaired(ctx context.Context, all bool) error {
	q := `SELECT m.id`
	if all {
		q += ` FROM models m JOIN usage u ON u.id = m.id`
	}
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankModels shadows a real table with a CTE of the same name. `usage` has a
// CREATE TABLE, so the schema cannot settle whether the appended `JOIN usage`
// reads it — only the WITH clause assembled into the same variable can, which is
// the shape the coordinator's earnings queries have.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankModels(ctx context.Context, all bool) error {
	q := `WITH usage AS (SELECT id FROM models) SELECT id FROM usage`
	if all {
		q += ` JOIN usage u ON u.id = usage.id`
	}
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankAndList runs two statements, one of which declares a CTE named after the
// table the other one reads. A CTE set kept per function body rather than per
// assembled statement would let the first query silence the second, dropping a
// real read of `usage` with nothing to report it.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankAndList(ctx context.Context, all bool) error {
	ranked := `WITH usage AS (SELECT id FROM models) SELECT id FROM usage`
	if _, err := p.db.ExecContext(ctx, ranked); err != nil {
		return err
	}
	q := `SELECT m.id FROM models m WHERE m.id = $1`
	if all {
		q += ` JOIN usage u ON u.id = m.id`
	}
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// ListModelsLogged carries a phrase that reads like a WITH clause in the very text
// whose table name is at stake, which is the only place it can be to pin anything:
// prose in a different statement is in a different scope and cannot shadow this
// fragment however it is spelled — ListModelsCondProse is that half. A CTE name
// written in lower case must not
// register — text able to switch the fragment check off would be the easiest way in
// the language to drop a table from the map.
//
// Reached only by the direct-walk tests.
func (p *Postgres) ListModelsLogged(ctx context.Context, base string) error {
	_, err := p.db.ExecContext(ctx,
		base+` /* with usage as (fb) */ UNION SELECT model FROM usage`)
	return err
}

// ListModelsCondProse puts text in the expressions of two composite statements: a
// switch tag that reads like a WITH clause, and an if condition holding a fragment
// that names a real table. Neither statement is a query, but both used to fall
// through to the body-wide zero scope, and pooling them there let the prose above
// shadow the name below — the same mute per-element scoping closed one level up, in
// the one place a scope was still shared by everything in the function.
//
// Reached only by the direct-walk tests.
func (p *Postgres) ListModelsCondProse(ctx context.Context, mode, note string) error {
	switch mode {
	case `cannot rank WITH usage AS (window) unset`:
		return nil
	}
	if note == ` UNION SELECT model FROM usage` {
		return nil
	}
	_, err := p.db.ExecContext(ctx, `SELECT id FROM models WHERE id = $1`)
	return err
}

// JoinSpliced ends its fragment at the keyword and concatenates the table name
// after it. `q += " FOR UPDATE"` looks the same to a scan that only asks whether
// a token follows the keyword — the difference is the trailing space, which is a
// name the extractor will never see.
//
// Reached only by the direct-walk tests.
func (p *Postgres) JoinSpliced(ctx context.Context, other string) error {
	q := `SELECT m.id FROM models m`
	q += ` JOIN ` + other + ` u ON u.id = m.id`
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// CountOnly hides its spliced table behind a keyword that may legally precede a
// table name. `Tables` reads through ONLY, so a scan that stopped at it would
// call a run-time table name readable.
//
// Reached only by the direct-walk tests.
func (p *Postgres) CountOnly(ctx context.Context, table string) error {
	_, err := p.db.ExecContext(ctx, fmt.Sprintf(`SELECT count(*) FROM ONLY %s WHERE id = $1`, table))
	return err
}

// LockModelMultiline closes its literal on the line after the last keyword, the
// way long queries are formatted. `FOR UPDATE` followed by a newline is a complete,
// readable statement — the whitespace after the keyword must not turn it into a
// splice, because there is no way to fix a finding on a statement that is already
// in one literal.
//
// Reached only by the direct-walk tests.
func (p *Postgres) LockModelMultiline(ctx context.Context, id string) error {
	_, err := p.db.ExecContext(ctx, `
		SELECT id, name FROM models
		WHERE id = $1
		FOR UPDATE
	`, id)
	return err
}

// LockModelSkip appends a locking clause that continues past the keyword, so the
// word after `UPDATE` is readable and is not a table. `FOR UPDATE` has to be
// stepped over wherever it appears, not only at the end of the text — otherwise
// the map gains a table called `skip`.
//
// Reached only by the direct-walk tests.
func (p *Postgres) LockModelSkip(ctx context.Context, all bool) error {
	q := `SELECT id FROM models WHERE id = $1`
	if all {
		q += ` FOR UPDATE SKIP LOCKED`
	}
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// LockModelNoKey spells the same lock the other legal way. `FOR UPDATE` is a family
// of clauses, not one phrase, so a carve-out written for the shortest spelling
// reports a complete statement it read correctly — with no remedy, because the
// statement is already in one literal.
//
// Reached only by the direct-walk tests.
func (p *Postgres) LockModelNoKey(ctx context.Context, id string) error {
	_, err := p.db.ExecContext(ctx, `
		SELECT id, name FROM models
		WHERE id = $1
		FOR NO KEY UPDATE
	`, id)
	return err
}

// LockModelComment ends its lock with a trailing comment, which is as legal as ending
// it with `NOWAIT`. The gate that decides whether the mask may take the words away has
// to allow a comment start, or the comment marker itself is read as the table spliced
// in after `UPDATE` — a finding against a complete, readable statement whose only
// remedy is to move a comment.
//
// Reached only by the direct-walk tests.
func (p *Postgres) LockModelComment(ctx context.Context, id string) error {
	_, err := p.db.ExecContext(ctx,
		"SELECT id FROM models WHERE id = $1 FOR UPDATE -- lock the row\n", id)
	return err
}

// SpliceAfterComment ends a comment with the word "for" and heads the next line with
// a spliced update. The mask that steps over `FOR UPDATE` must not step over this:
// blanking the keyword here hides a write to a table nobody can see, and the count of
// database calls against readable statements balances, so the map simply loses the
// table. Case is the only thing that separates the two — the lock is written `FOR`,
// the comment ends in `for` — which is why this reader's mask is case-sensitive while
// `Tables`, reading normalized text, decides on what follows the words instead.
//
// Reached only by the direct-walk tests.
func (p *Postgres) SpliceAfterComment(ctx context.Context, table string) error {
	q := "-- rows queued for\nUPDATE " + table + " SET name = $1"
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// LockModelSkipInline is LockModelSkip in a single literal, which is the form the
// remedy text tells a reader to prefer. `Tables` has to step over the clause too:
// reading `UPDATE SKIP` as an update statement put a table called `skip` in the map,
// which is drift invented by the map rather than found by it.
//
// Reached only by the direct-walk tests.
func (p *Postgres) LockModelSkipInline(ctx context.Context, id string) error {
	_, err := p.db.ExecContext(ctx,
		`SELECT id, name FROM models WHERE id = $1 FOR UPDATE SKIP LOCKED`, id)
	return err
}

// UpsertModel splits an upsert after `DO UPDATE`, where the word introduces a
// conflict action rather than a table. The tail is `SET name = $2`, so nothing
// unreadable is in this body at all.
//
// Reached only by the direct-walk tests.
func (p *Postgres) UpsertModel(ctx context.Context, id, name string) error {
	q := `INSERT INTO models (id, name) VALUES ($1, $2) ON CONFLICT (id) DO UPDATE `
	q += `SET name = $2`
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankInline hands both of its statements straight to the driver, so neither has a
// variable to be named by. The scope has to fall back to the statement rather than
// to the body: the CTE in the first call must not shadow the real read of `usage`
// spliced onto the second, which is the shape a `strings.Builder` assembly and an
// `Exec(ctx, literal)` in the same function both take.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankInline(ctx context.Context, base string) error {
	if _, err := p.db.ExecContext(ctx,
		`WITH usage AS (SELECT id FROM models) SELECT id FROM usage`); err != nil {
		return err
	}
	_, err := p.db.ExecContext(ctx, base+` JOIN usage u ON u.id = base.id`)
	return err
}

// RankRecycled reuses one local for two statements. The variable is only "which
// statement is this" until it is assigned a different statement — after that, the
// CTE names the first query declared say nothing about the fragment appended to the
// second, and a scope that kept them would drop a real read of `usage`.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankRecycled(ctx context.Context, all bool) error {
	q := `WITH usage AS (SELECT id FROM models) SELECT id FROM usage`
	if _, err := p.db.ExecContext(ctx, q); err != nil {
		return err
	}
	q = `SELECT m.id FROM models m WHERE m.id = $1`
	if all {
		q += ` JOIN usage u ON u.id = m.id`
	}
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// ListModelsTrailing names a table and then trails off at a keyword. Both facts
// matter: the report only needs one finding per literal, but the declaration check
// is held to `models` too — reporting the trailing keyword and stopping there would
// let an entry naming only `usage` absorb a read of a table it never mentioned.
//
// Reached only by the direct-walk tests.
func (p *Postgres) ListModelsTrailing(ctx context.Context, other string) error {
	q := `SELECT m.id`
	q += ` FROM models m JOIN `
	q += other
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// ListModelsJoinedFrag names a table and splices the next one in the same fragment.
// The report needs one finding, but the name it did read has to be recorded before
// that finding is raised: see TestFixtureAssembledDeclaration, where a declaration
// naming only `usage` must still be held to `models`.
//
// Reached only by the direct-walk tests.
func (p *Postgres) ListModelsJoinedFrag(ctx context.Context, other string) error {
	q := `SELECT m.id`
	q += fmt.Sprintf(` FROM models m JOIN %s u ON u.id = m.id`, other)
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankBatch splits one query across a slice element. Only a bare identifier holding
// text can be a scope, so `qs[0] +=` has none and its text belongs to the statement:
// `qs` is a `[]string`, which carries no statement text of its own, and resolving the
// index to it would be wrong anyway, since `qs[0]` and `qs[1]` are one variable and a
// CTE in one element would shadow a real table read in another. The fragment is
// reported instead — an answerable finding, where the shadowed read would be silent.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankBatch(ctx context.Context, all bool) error {
	qs := []string{`WITH usage AS (SELECT id FROM models) SELECT id FROM usage`}
	if all {
		qs[0] += ` JOIN usage u ON u.id = usage.id`
	}
	_, err := p.db.ExecContext(ctx, qs[0])
	return err
}

// RankSliceElements is why resolving the index in RankBatch would be the wrong repair
// even where the types allowed it. Two statements share one slice, and the CTE belongs
// to the element the fragment is not appended to — so following the index would settle
// a real read of `usage` against the other element's WITH clause and publish the route
// without it.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankSliceElements(ctx context.Context, all bool) error {
	qs := []string{
		`SELECT m.id FROM models m WHERE m.id = $1`,
		`WITH usage AS (SELECT id FROM models) SELECT id FROM usage`,
	}
	if all {
		qs[0] += ` JOIN usage u ON u.id = m.id`
	}
	for _, q := range qs {
		if _, err := p.db.ExecContext(ctx, q); err != nil {
			return err
		}
	}
	return nil
}

// queryBuf is a struct a query could be assembled through. `b.q` is not a bare
// identifier, so RankFields has no scope variable for the same reason RankBatch has
// none — and the field it would resolve to is shared by every value of the type.
type queryBuf struct{ q string }

// RankFields assembles through a field. Two receivers in one body would share one
// field object, so a scope resolved through the selector would let `a.q`'s CTE
// shadow a table `b.q` really reads.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankFields(ctx context.Context, all bool) error {
	var b queryBuf
	b.q = `WITH usage AS (SELECT id FROM models) SELECT id FROM usage`
	if all {
		b.q += ` JOIN usage u ON u.id = usage.id`
	}
	_, err := p.db.ExecContext(ctx, b.q)
	return err
}

// RankBare hands both statements to the driver as bare calls, so neither is an
// assignment of any kind. The scope has to fall back to the statement even then, or
// the first query's CTE would shadow the real read of `usage` spliced onto the
// second.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankBare(ctx context.Context, base string) {
	p.db.ExecContext(ctx, `WITH usage AS (SELECT id FROM models) SELECT id FROM usage`)
	p.db.ExecContext(ctx, base+` JOIN usage u ON u.id = base.id`)
}

// RankErrShared is two unrelated queries whose only shared name is `err`. A scope
// taken from any single-target assignment would pool them under it, and the CTE in
// the first would shadow the real read of `usage` in the second — so the target has
// to be able to hold the text before it can stand for the query.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankErrShared(ctx context.Context, base string) error {
	var n int64
	err := p.db.QueryRowContext(ctx,
		`WITH usage AS (SELECT id FROM models) SELECT count(*) FROM usage`).Scan(&n)
	if err != nil {
		return err
	}
	err = p.db.QueryRowContext(ctx, base+` JOIN usage u ON u.id = base.id`).Scan(&n)
	return err
}

// RankReversed reuses one local the other way round from RankRecycled: the fragment
// is appended to the first statement, and the CTE arrives with the second. The
// verdict has to come from the generation the fragment was read in — a single set
// per variable is mutated during the walk and consulted after it, so the last
// statement would decide for both and this real read of `usage` would go missing.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankReversed(ctx context.Context, all bool) error {
	q := `SELECT m.id FROM models m WHERE m.id = $1`
	if all {
		q += ` JOIN usage u ON u.id = m.id`
	}
	if _, err := p.db.ExecContext(ctx, q); err != nil {
		return err
	}
	q = `WITH usage AS (SELECT id FROM models) SELECT id FROM usage`
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankSplitCTE is one query whose middle literal parses on its own, which is how
// every long query in the tree is formatted: a CTE definition, a splice point, and a
// clause that happens to be a complete statement between two more. The generation has
// to belong to the assignment rather than to the literal — counting the middle
// statement as a new query orphans the CTE names declared above it, and the tail that
// joins them is reported as reading tables it does not read.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankSplitCTE(ctx context.Context, modelWhere, order string) error {
	q := `WITH usage AS (` + modelWhere + `
	          SELECT id FROM models
	      )
	      SELECT id FROM models m WHERE m.id = $1` + order + `
	      UNION SELECT id FROM usage`
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankSliceLiteral holds two queries in one slice literal: the first declares a CTE
// named after a real table, the second is a fragment that reads that table. Scoping
// text by the statement pooled them, and the CTE muted the read — the store's
// `migrations := []string{…}` is a hundred statements in one such pool, which is the
// size at which nobody would notice. An element stands for its own query.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankSliceLiteral(ctx context.Context, base string) error {
	for _, q := range []string{
		`WITH usage AS (SELECT id FROM models) SELECT id FROM usage`,
		base + ` JOIN usage u ON u.id = base.id`,
	} {
		if _, err := p.db.ExecContext(ctx, q); err != nil {
			return err
		}
	}
	return nil
}

// RankTwoArgs is the same collision one statement further in: two queries as the
// arguments of a single call. The call is immediate so that the driver sees them in
// this body rather than another, which is also the shape the service's bounded-
// concurrency workers use.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankTwoArgs(ctx context.Context, base string) error {
	var err error
	func(first, second string) {
		if _, e := p.db.ExecContext(ctx, first); e != nil {
			err = e
			return
		}
		_, err = p.db.ExecContext(ctx, second)
	}(`WITH usage AS (SELECT id FROM models) SELECT id FROM usage`,
		base+` JOIN usage u ON u.id = base.id`)
	return err
}

// queryish is a constraint whose type set is all strings, so a value of it holds
// statement text the way a string does.
type queryish interface{ ~string }

// rankGeneric assembles its query in a type parameter. A type parameter's underlying
// type is its constraint interface, which holds nothing, so answering "can this hold
// text" from the underlying type put the WITH clause and the fragment appended to it
// in different scopes and reported a correct query. The type set is the thing to ask.
func rankGeneric[T queryish](p *Postgres, ctx context.Context, all bool) error {
	var q T = `WITH usage AS (SELECT id FROM models) SELECT id FROM usage`
	if all {
		q += ` JOIN usage u ON u.id = usage.id`
	}
	_, err := p.db.ExecContext(ctx, string(q))
	return err
}

// RankGeneric reaches it, because a method cannot carry a type parameter of its own
// and the direct-walk tests address methods.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankGeneric(ctx context.Context, all bool) error {
	return rankGeneric[string](p, ctx, all)
}

// RankSplitAppend is one query bound once and extended twice, where the middle
// append is a complete statement on its own. It is the same trap as RankSplitCTE from
// the other side: the generation boundary cannot be statement-shaped text, because
// text like this appears mid-query. It has to be the binding — the `q :=` that starts
// a query as against the `q +=` that continues one — or the WITH clause in the first
// append is orphaned and the tail's join onto it names a table the query never reads.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankSplitAppend(ctx context.Context, all bool) error {
	q := `WITH usage AS (SELECT id FROM models)`
	q += ` SELECT m.id FROM models m WHERE m.id = $1`
	q += ` UNION SELECT id FROM usage`
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankResetAfter is the same reuse with the halves the right way round, and it must
// stay clean: the fragment joins the CTE its own statement declared, and a later
// statement recycling the local says nothing about it. Deleting a scope's names when
// the variable is rebound would retroactively unshadow this fragment and red-light a
// query that is entirely correct.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankResetAfter(ctx context.Context, all bool) error {
	q := `WITH usage AS (SELECT id FROM models) SELECT id FROM usage`
	if all {
		q += ` JOIN usage u ON u.id = usage.id`
	}
	if _, err := p.db.ExecContext(ctx, q); err != nil {
		return err
	}
	q = `SELECT id FROM models WHERE id = $1`
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankSplitCTEJoin declares its CTE in one literal and joins it in the next, where
// the joining literal parses as a statement on its own and the CTE is named after a
// table that really exists. `Tables` strips a CTE name from the text it declares in,
// which is the whole answer for a query written as one literal and no answer at all
// here — read alone, the second literal is a plain read of the `usage` table, which
// this query never touches. The tables a statement names are drawn once the body's
// CTE names are known, so the edge is not invented.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankSplitCTEJoin(ctx context.Context, all bool) error {
	q := `WITH usage AS (SELECT id FROM models)`
	q += ` SELECT u.id FROM usage u JOIN models m ON m.id = u.id`
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankResetThenAppend rebinds its local to text that is not a statement and only
// then appends the next query. Both halves are needed: the `q = ""` carries no
// statement, and the `q +=` is not a binding. While the generation boundary was
// decided by the text, neither line opened one, the second query's `WITH usage AS
// (...)` landed in the first query's generation, and the first query's real read of
// `usage` was shadowed by a CTE declared two statements below it — a table dropped
// from the map with nothing reported. The boundary is the binding, so the reset
// starts a query whatever text it carries.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankResetThenAppend(ctx context.Context, all bool) error {
	q := `SELECT id FROM models WHERE id = $1`
	q += ` JOIN usage u ON u.id = models.id`
	if _, err := p.db.ExecContext(ctx, q); err != nil {
		return err
	}
	q = ``
	q += `WITH usage AS (SELECT id FROM models) SELECT id FROM usage`
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankTailFirstReuse assembles a query tail first: the local is rebound to the
// `UNION` and then rebound again to the base *plus itself*. The second rebinding is
// syntactically a reset and semantically a continuation, and it must stay clean —
// treating it as a boundary would put the tail and the WITH clause that covers it in
// different generations and report the query's own CTE as an undeclared table. That is
// what `readsScope` is for.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankTailFirstReuse(ctx context.Context, all bool) error {
	q := `SELECT id FROM models WHERE id = $1`
	if _, err := p.db.ExecContext(ctx, q); err != nil {
		return err
	}
	q = ` UNION SELECT id FROM usage`
	q = `WITH usage AS (SELECT id FROM models) SELECT id FROM usage` + q
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankTailAfterExec prepends a WITH clause to a local that has already been handed to
// the driver. It reads the local back, exactly as RankTailFirstReuse does, and it is
// the opposite case: the first query is over, so its real read of `usage` must not be
// shadowed by a CTE the second query declares. What separates the two is whether a
// driver call has taken the scope — the tail-first exception is only for text that has
// not run yet.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankTailAfterExec(ctx context.Context, all bool) error {
	q := `SELECT id FROM models WHERE id = $1`
	if all {
		q += ` JOIN usage u ON u.id = models.id`
	}
	if _, err := p.db.ExecContext(ctx, q); err != nil {
		return err
	}
	q = `WITH usage AS (SELECT id FROM models) SELECT id FROM usage` + q
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankTailBeforeBase collects the tail into a local that has been declared but never
// bound, then prepends the base. The fragment is read in a generation nothing has
// opened yet, and has to settle against the WITH clause that arrives after it.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankTailBeforeBase(ctx context.Context, all bool) error {
	var q string
	if all {
		q += ` UNION SELECT id FROM usage`
	}
	q = `WITH usage AS (SELECT id FROM models) SELECT id FROM usage` + q
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// RankDeclaredVar assembles its query through a `var` declaration rather than an
// assignment. Text in a declaration has to be scoped the same way, or the WITH
// clause lands in one scope and the fragment appended to it in another.
//
// Reached only by the direct-walk tests.
func (p *Postgres) RankDeclaredVar(ctx context.Context, all bool) error {
	var q = `WITH usage AS (SELECT id FROM models) SELECT id FROM usage`
	if all {
		q += ` JOIN usage u ON u.id = usage.id`
	}
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// UsageWindow appends a fragment whose FROM belongs to a keyword call. The mask
// that keeps `EXTRACT(EPOCH FROM ...)` from naming a table has to run over
// fragments too — without it the map would gain a table called `created_at`, which
// is not even in the schema.
//
// Reached only by the direct-walk tests.
func (p *Postgres) UsageWindow(ctx context.Context, all bool) error {
	q := `SELECT id FROM usage WHERE id = $1`
	if all {
		q += ` ORDER BY EXTRACT(EPOCH FROM created_at) DESC`
	}
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// UsageUnnest appends a fragment whose FROM opens a function instead of naming a
// table. `Tables` skips those keywords; the fragment scan has to skip the same ones
// or `unnest` becomes a table in the report.
//
// Reached only by the direct-walk tests.
func (p *Postgres) UsageUnnest(ctx context.Context, all bool) error {
	q := `SELECT id FROM usage WHERE id = $1`
	if all {
		q += ` UNION SELECT id FROM UNNEST($2::text[]) AS id`
	}
	_, err := p.db.ExecContext(ctx, q)
	return err
}

// ModelLabel makes no database call, so a declaration naming it explains nothing
// and has no call site to cite. It exists to pin the one finding that is about the
// absence of a query rather than about a query.
func (p *Postgres) ModelLabel(id string) string {
	return "model:" + id
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
