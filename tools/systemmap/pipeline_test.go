package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/tools/systemmap/assemble"
	"github.com/eigeninference/d-inference/tools/systemmap/config"
	"github.com/eigeninference/d-inference/tools/systemmap/extract"
	"github.com/eigeninference/d-inference/tools/systemmap/ir"
	"github.com/eigeninference/d-inference/tools/systemmap/render"
	"github.com/eigeninference/d-inference/tools/systemmap/report"
)

// fixtureRevision is a fixed 40-hex revision, so the artifact a test compares is
// not a function of the checkout it ran in.
const fixtureRevision = "0123456789abcdef0123456789abcdef01234567"

// buildFixture runs the whole pipeline over testdata/fixture: a real miniature
// service, type-checked by go/packages exactly as the coordinator is. The
// optional mutators break the loaded overlay on purpose, which is how the drift
// checks are proved to fire.
func buildFixture(t *testing.T, mutate ...func(*config.Config)) (*ir.Graph, *report.Report) {
	t.Helper()
	root, err := filepath.Abs("testdata/fixture")
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(filepath.Join(root, "overlay.json"), "svcfix.test")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range mutate {
		fn(cfg)
	}
	rep := report.New()
	svc, prog, err := extract.Go(root, cfg, rep)
	if err != nil {
		t.Fatal(err)
	}
	graph := assemble.Build(svc, prog, cfg, rep, assemble.Options{
		Revision:    fixtureRevision,
		OverlayPath: "overlay.json",
	})
	return graph, rep
}

func endpoints(g *ir.Graph) map[string]*ir.Endpoint {
	out := map[string]*ir.Endpoint{}
	for _, ep := range g.Routes {
		out[ep.Method+" "+ep.Path] = ep
	}
	return out
}

// TestFixtureRoutes pins everything the extractor derives per route: the mux
// pattern, the middleware chain it was wrapped in, the gates its code calls, and
// the state that code reaches through interface dispatch, a mutually recursive
// helper, a package constant and a goroutine closure.
func TestFixtureRoutes(t *testing.T) {
	g, _ := buildFixture(t)
	want := map[string]struct {
		handler    string
		middleware []string
		gates      []string
		namespace  string
		auth       string
		deps       []string
	}{
		"GET /v1/models": {
			handler:    "handleModels",
			middleware: []string{"withAuth"},
			gates:      []string{},
			namespace:  "Public",
			auth:       "Bearer",
			deps:       []string{"ext.icons", "mem.aliases", "mem.cache", "pg.models"},
		},
		"GET /v1/aliases": {
			handler:    "handleAliases",
			middleware: []string{"withAuth"},
			gates:      []string{},
			namespace:  "Public",
			auth:       "Bearer",
			deps:       []string{"mem.aliases", "mem.cache", "mem.flight"},
		},
		"POST /v1/usage": {
			handler:    "handleUsage",
			middleware: []string{},
			gates:      []string{},
			namespace:  "Public",
			auth:       "Public",
			deps:       []string{"ext.opaque", "mem.inflight", "pg.models", "pg.usage"},
		},
		"GET /v1/admin/stats": {
			handler:    "handleAdminStats",
			middleware: []string{"withAuth"},
			gates:      []string{"isAdmin"},
			namespace:  "Admin",
			auth:       "Admin",
			deps:       []string{"mem.admins", "pg.usage"},
		},
		"ANY /legacy/": {
			handler:    "inline",
			middleware: []string{},
			gates:      []string{},
			namespace:  "Legacy",
			auth:       "Public",
			deps:       []string{"mem.cache"},
		},
	}
	got := endpoints(g)
	if len(got) != len(want) {
		t.Fatalf("extracted %d routes, want %d: %v", len(got), len(want), got)
	}
	for key, exp := range want {
		ep, ok := got[key]
		if !ok {
			t.Errorf("route %q not extracted", key)
			continue
		}
		if ep.Handler != exp.handler {
			t.Errorf("%s handler = %q, want %q", key, ep.Handler, exp.handler)
		}
		if !reflect.DeepEqual(ep.Middleware, exp.middleware) {
			t.Errorf("%s middleware = %v, want %v", key, ep.Middleware, exp.middleware)
		}
		if !reflect.DeepEqual(ep.Gates, exp.gates) {
			t.Errorf("%s gates = %v, want %v", key, ep.Gates, exp.gates)
		}
		if ep.Namespace != exp.namespace {
			t.Errorf("%s namespace = %q, want %q", key, ep.Namespace, exp.namespace)
		}
		if ep.Auth != exp.auth {
			t.Errorf("%s auth = %q, want %q", key, ep.Auth, exp.auth)
		}
		if !reflect.DeepEqual(ep.Dependencies, exp.deps) {
			t.Errorf("%s dependencies = %v, want %v", key, ep.Dependencies, exp.deps)
		}
	}
}

// TestFixtureNoDrift asserts a complete overlay produces an empty report. Every
// other fixture test would still pass with drift, so this is the one that keeps
// the -check contract meaningful.
func TestFixtureNoDrift(t *testing.T) {
	_, rep := buildFixture(t)
	if !rep.Clean() {
		t.Fatalf("fixture overlay is complete but drift was reported: %s\n\n%s", rep.Counts(), rep.Markdown())
	}
}

// TestFixtureAbsorbedConcurrentState is the regression for the state-holder
// check. fetch.Client carries a mutex and a counter, and `deps.packageDefault`
// would happily swallow it: without the check, adding stateful machinery to a
// defaulted package produces no build failure and no node, and the map quietly
// understates the system. Dropping the overlay's claim about the struct must
// name it.
func TestFixtureAbsorbedConcurrentState(t *testing.T) {
	_, rep := buildFixture(t, func(cfg *config.Config) {
		delete(cfg.Deps.Fields, "fetch:Client.mu")
		delete(cfg.Deps.Fields, "fetch:Client.inflight")
	})
	holder, ok := rep.AbsorbedTypes["fetch:Client"]
	if !ok {
		t.Fatalf("undeclared concurrent state was absorbed silently: %s", rep.Counts())
	}
	if holder.Field != "mu" || holder.Via != "deps.packageDefault" {
		t.Errorf("holder = %+v, want the mu field absorbed by deps.packageDefault", holder)
	}
	if !strings.Contains(rep.Markdown(), "`fetch:Client` — concurrent state") {
		t.Error("report does not name the absorbed type")
	}

	// A deliberate decision clears it, whichever form the decision takes: the
	// check asks that someone looked, not that the answer is a node.
	_, rep = buildFixture(t, func(cfg *config.Config) {
		delete(cfg.Deps.Fields, "fetch:Client.mu")
		delete(cfg.Deps.Fields, "fetch:Client.inflight")
		cfg.Deps.Types["fetch:Client"] = "@skip"
	})
	if _, ok := rep.AbsorbedTypes["fetch:Client"]; ok {
		t.Error("an explicit @skip did not clear the state-holder finding")
	}
}

// walkFixtureMethod walks one store method directly, outside the route table.
//
// The statement shapes these tests pin are properties of a function body, not of a
// route, and putting them behind a new endpoint would repin every route fixture
// for no extra coverage.
func walkFixtureMethod(t *testing.T, method string, mutate ...func(*config.Config)) ([]string, *report.Report) {
	t.Helper()
	root, err := filepath.Abs("testdata/fixture")
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.Load(filepath.Join(root, "overlay.json"), "svcfix.test")
	if err != nil {
		t.Fatal(err)
	}
	for _, fn := range mutate {
		fn(cfg)
	}
	prog, err := extract.Load(root, cfg.Module(), cfg.AnalyzePatterns())
	if err != nil {
		t.Fatal(err)
	}
	sym := prog.Method("svcfix.test/store", "Postgres", method)
	if sym == nil {
		t.Fatalf("fixture method store.Postgres.%s not found", method)
	}
	rep := report.New()
	res := extract.NewWalker(prog, cfg, rep).Func(sym)
	var accesses []string
	for _, acc := range res.Accesses {
		accesses = append(accesses, acc.Node+" "+acc.Mode)
	}
	sort.Strings(accesses)
	return accesses, rep
}

// declare is the overlay entry that accounts for an assembled statement.
func declare(fn string, tables map[string]string) func(*config.Config) {
	return func(cfg *config.Config) {
		cfg.Deps.SQLDriver.Assembled = map[string]map[string]string{"store:Postgres." + fn: tables}
	}
}

// TestFixtureConstantFoldedQuery is the regression for classifying a statement
// spliced together from constants. `"SELECT " + modelColumns + " FROM models ..."`
// is one string to the compiler, but a walker that classified the operands it was
// written as would see only fragments — neither " FROM models WHERE id = $1" nor
// the column list is a statement — and record no table at all. On the coordinator
// that shape is 14 store reads, including the API-key lookup on every inference
// request, so the map published api_keys as write-only.
func TestFixtureConstantFoldedQuery(t *testing.T) {
	accesses, rep := walkFixtureMethod(t, "GetModel")
	if !reflect.DeepEqual(accesses, []string{"pg.models R"}) {
		t.Errorf("accesses = %v, want [pg.models R]", accesses)
	}
	if !rep.Clean() {
		t.Errorf("a readable statement was reported as drift: %s\n\n%s", rep.Counts(), rep.Markdown())
	}
}

// opaqueDetails returns what the report says about one fixture method, so a test
// can assert the explanation the reader gets rather than an internal shape.
func opaqueDetails(t *testing.T, method string, mutate ...func(*config.Config)) []string {
	t.Helper()
	_, rep := walkFixtureMethod(t, method, mutate...)
	var out []string
	for site, q := range rep.OpaqueQueries {
		if q.Func != "Postgres."+method {
			t.Errorf("finding attributed to %s, want Postgres.%s", q.Func, method)
		}
		if !strings.HasPrefix(site, "store/store.go:") {
			t.Errorf("site = %q, want a position in store/store.go", site)
		}
		out = append(out, q.Detail)
	}
	sort.Strings(out)
	if len(out) > 0 && rep.Clean() {
		t.Error("report is clean despite text the extractor cannot read")
	}
	if len(out) > 0 && !strings.Contains(rep.Markdown(), "Statement text the extractor cannot read") {
		t.Error("report does not explain the unreadable statement")
	}
	return out
}

// TestFixtureOpaqueQuery is the regression for the check itself: a statement built
// at run time. This is the one failure mode the rest of the report cannot express —
// there is no unknown table and no unmapped field, because the extractor saw
// nothing. Counting what the driver was handed against what was readable, and
// checking the text around every table name, turns that silence into drift.
//
// The four fixture methods are the four ways the text can go dark, and each is
// caught by only one half of the check: no readable statement at all (the count),
// a fragment naming a table the base statement does not (the text), a table name
// spliced in at run time (the text again, inside a statement that parses), and the
// same splice behind a table the scan could read (the text again, only if it keeps
// looking past the first name it recognizes).
func TestFixtureOpaqueQuery(t *testing.T) {
	for _, tc := range []struct {
		method string
		want   []string
	}{
		{"ListModelsFiltered", []string{
			"1 database call(s) but only 0 readable statement(s) in the body",
			"the text ends at `FROM`, so the table that follows it is spliced in at run time (`SELECT id FROM`)",
		}},
		{"ListModelsWithUsage", []string{
			"`UNION SELECT model FROM usage` names a table but is only a fragment of a statement",
		}},
		{"CountRows", []string{
			"the table after `FROM` is spliced in at run time (`FROM %s`)",
		}},
		{"ListModelsJoined", []string{
			"the table after `JOIN` is spliced in at run time (`JOIN %s`)",
		}},
		// The same splice concatenated instead of formatted. Demanding a token after
		// the keyword is what keeps `q += " FOR UPDATE"` clean, and it is exactly what
		// makes this shape match nothing: the table is in the next expression.
		{"JoinSpliced", []string{
			"the text ends at `JOIN`, so the table that follows it is spliced in at run time (`JOIN`)",
		}},
		// A keyword that may legally precede a table name, so a scan that treated it
		// as the end of the search would call a run-time table name readable.
		{"CountOnly", []string{
			"the table after `FROM` is spliced in at run time (`FROM %s`)",
		}},
		// Two statements, the first declaring a CTE named after the table the second
		// reads. CTE names have to be scoped to the statement being assembled, or one
		// query silences the other and a real read is dropped.
		{"RankAndList", []string{
			"`JOIN usage u ON u.id = m.id` names a table but is only a fragment of a statement",
		}},
		// A phrase that reads like a WITH clause in the same text as the table name.
		// Every string in the body is scanned for CTE names, so prose must not be able
		// to shadow a table — here it would shadow the one beside it.
		{"ListModelsLogged", []string{
			"1 database call(s) but only 0 readable statement(s) in the body",
			"`/* with usage as (fb) */ UNION SELECT model FROM usage` names a table but is only a fragment of a statement",
		}},
		// Two statements handed straight to the driver, neither of which has a variable
		// to be scoped by. Falling back to the body would let the first one's CTE shadow
		// the second one's real read of the same name.
		{"RankInline", []string{
			"2 database call(s) but only 1 readable statement(s) in the body",
			"`JOIN usage u ON u.id = base.id` names a table but is only a fragment of a statement",
		}},
		// One local reused for two statements. A CTE name belongs to the query that
		// declared it, not to the variable forever after.
		{"RankRecycled", []string{
			"`JOIN usage u ON u.id = m.id` names a table but is only a fragment of a statement",
		}},
		// A literal that names a table and then trails off at a keyword. One finding is
		// all the report needs, but see TestFixtureAssembledDeclaration: the name it did
		// give up is still held against a declaration.
		{"ListModelsTrailing", []string{
			"1 database call(s) but only 0 readable statement(s) in the body",
			"the text ends at `JOIN`, so the table that follows it is spliced in at run time (`FROM models m JOIN`)",
		}},
		// Two tables in one fragment, one finding: a reader who goes and looks at the
		// line sees both, and a per-name report would say the same thing twice.
		{"ListModelsPaired", []string{
			"1 database call(s) but only 0 readable statement(s) in the body",
			"`FROM models m JOIN usage u ON u.id = m.id` names a table but is only a fragment of a statement",
		}},
		// A table named beside a spliced one. Both findings are about the same literal,
		// which the report shows once; the name it read is recorded either way, and
		// TestFixtureAssembledDeclaration is where that shows.
		{"ListModelsJoinedFrag", []string{
			"1 database call(s) but only 0 readable statement(s) in the body",
			"the table after `JOIN` is spliced in at run time (`JOIN %s`)",
		}},
		// A query assembled through a slice element, and one assembled through a field.
		// Neither is followed to the variable underneath, because two elements and two
		// receivers share it — a shadowed read there would be silent, and this finding
		// is not.
		{"RankBatch", []string{
			"`JOIN usage u ON u.id = usage.id` names a table but is only a fragment of a statement",
		}},
		{"RankFields", []string{
			"`JOIN usage u ON u.id = usage.id` names a table but is only a fragment of a statement",
		}},
		// What following the index would cost: the CTE is in the element the fragment
		// was not appended to, so resolving both to `qs` drops a real read of `usage`.
		{"RankSliceElements", []string{
			"`JOIN usage u ON u.id = m.id` names a table but is only a fragment of a statement",
		}},
		// Two bare calls, so neither statement is an assignment of any kind and the
		// scope has nothing to fall back to but the statement.
		{"RankBare", []string{
			"2 database call(s) but only 1 readable statement(s) in the body",
			"`JOIN usage u ON u.id = base.id` names a table but is only a fragment of a statement",
		}},
		// Two queries whose only shared name is `err`. A target that cannot hold the
		// text does not stand for the query, or one CTE would shadow the whole body.
		{"RankErrShared", []string{
			"2 database call(s) but only 1 readable statement(s) in the body",
			"`JOIN usage u ON u.id = base.id` names a table but is only a fragment of a statement",
		}},
		// The reuse in RankRecycled with the halves reversed. A fragment is settled
		// against the CTE names in force where it was read, not against whichever
		// statement the variable held last.
		{"RankReversed", []string{
			"`JOIN usage u ON u.id = m.id` names a table but is only a fragment of a statement",
		}},
	} {
		t.Run(tc.method, func(t *testing.T) {
			if got := opaqueDetails(t, tc.method); !reflect.DeepEqual(got, tc.want) {
				t.Errorf("findings for %s:\n got %q\nwant %q", tc.method, got, tc.want)
			}
		})
	}
}

// TestFixtureReadableSQLIsNotDrift is the other side of the check, and the reason
// it has to be tested as carefully as the drift it finds: a table-name scan reads
// SQL without parsing it, so shapes that are entirely readable can still trip it.
// A false positive here is worse than a miss — it cannot be silenced except by
// declaring tables that are already correct in the map, which turns the escape
// hatch into a habit.
func TestFixtureReadableSQLIsNotDrift(t *testing.T) {
	for _, tc := range []struct {
		method string
		want   []string
	}{
		// `q += " FOR UPDATE"`, the immediate cousin of the `q += " LIMIT $2"` the
		// docs recommend: a clause that ends at a table-introducing keyword.
		{"LockModel", []string{"pg.models R"}},
		// A column list opening where a table name's next character would be.
		{"InsertModel", []string{"pg.models W"}},
		// A CTE shadowing a table that really exists. The schema cannot settle this
		// one — `usage` has a CREATE TABLE — so only the WITH clause assembled into
		// the same variable says the appended JOIN is not a read of it.
		{"RankModels", []string{"pg.models R"}},
		// A complete statement whose literal closes on the line after `FOR UPDATE`.
		// Every whitespace character after a table-introducing keyword is a possible
		// splice, except after the two words that never introduce a table.
		{"LockModelMultiline", []string{"pg.models R"}},
		// The other one: `ON CONFLICT ... DO UPDATE ` split before its SET clause.
		{"UpsertModel", []string{"pg.models W"}},
		// A locking clause that carries on past the keyword, where the readable word
		// after `UPDATE` is `SKIP` and not a table — as a fragment, and in the single
		// literal the remedy text tells a reader to prefer. The second one is where a
		// table called `skip` would come from.
		{"LockModelSkip", []string{"pg.models R"}},
		{"LockModelSkipInline", []string{"pg.models R"}},
		// The other spelling of the same lock. `FOR UPDATE` is a family of clauses, and
		// a statement already in one literal has no remedy left if one of them is read
		// as a splice.
		{"LockModelNoKey", []string{"pg.models R"}},
		// A query split across a `var` declaration, which has to be scoped the way an
		// assignment is or the WITH clause and the fragment land apart.
		{"RankDeclaredVar", []string{"pg.models R"}},
		// One local, two statements, the fragment belonging to the first. Its CTE names
		// are still in force where it was read, however the local is reused afterwards.
		{"RankResetAfter", []string{"pg.models R", "pg.models R"}},
		// One statement whose middle literal parses on its own, the shape every long
		// query in the tree has. The CTE above it is still in force below it — the
		// coordinator's network-totals query is one line break away from this.
		{"RankSplitCTE", []string{"pg.models R"}},
		// The same query bound once and appended to twice, where the middle append is
		// itself a statement. Only the binding may end a query's CTE scope; text that
		// looks like a statement is text a long query is full of. Two reads because two
		// of its three literals parse on their own, which is exactly the point.
		{"RankSplitAppend", []string{"pg.models R", "pg.models R"}},
		// Fragments whose FROM belongs to a keyword call and to a set-returning
		// function. Neither names a table, and the fragment scan has to know that as
		// well as `Tables` does.
		{"UsageWindow", []string{"pg.usage R"}},
		{"UsageUnnest", []string{"pg.usage R"}},
	} {
		t.Run(tc.method, func(t *testing.T) {
			accesses, rep := walkFixtureMethod(t, tc.method)
			if !reflect.DeepEqual(accesses, tc.want) {
				t.Errorf("accesses = %v, want %v", accesses, tc.want)
			}
			if !rep.Clean() {
				t.Errorf("readable SQL reported as drift: %s\n\n%s", rep.Counts(), rep.Markdown())
			}
		})
	}
}

// TestFixtureAssembledDeclaration covers the overlay's answer to a statement that
// genuinely cannot be one expression: a human writes down the tables, the map
// draws them, and the finding stands down. What keeps that from being a mute is
// the rest of this test — the declaration is checked against the schema, and it is
// reported the moment the source stops needing it.
func TestFixtureAssembledDeclaration(t *testing.T) {
	t.Run("declared", func(t *testing.T) {
		accesses, rep := walkFixtureMethod(t, "ListModelsWithUsage",
			declare("ListModelsWithUsage", map[string]string{"usage": "R"}))
		if want := []string{"pg.models R", "pg.usage R"}; !reflect.DeepEqual(accesses, want) {
			t.Errorf("accesses = %v, want %v", accesses, want)
		}
		if !rep.Clean() {
			t.Errorf("a declared assembled statement was still reported: %s\n\n%s", rep.Counts(), rep.Markdown())
		}
	})

	t.Run("unknown table", func(t *testing.T) {
		_, rep := walkFixtureMethod(t, "ListModelsWithUsage",
			declare("ListModelsWithUsage", map[string]string{"sessions": "R"}))
		if _, ok := rep.UnknownTables["sessions"]; !ok {
			t.Errorf("a declared table with no CREATE TABLE went unreported: %s", rep.Counts())
		}
	})

	t.Run("stale", func(t *testing.T) {
		want := []string{"the overlay declares the tables this function assembles, but every statement in it is now readable — delete the entry"}
		got := opaqueDetails(t, "GetModel", declare("GetModel", map[string]string{"models": "R"}))
		if !reflect.DeepEqual(got, want) {
			t.Errorf("findings for a readable body:\n got %q\nwant %q", got, want)
		}
	})

	// A declaration explains the tables it names, not the function that carries it.
	// Absorbing every silence in the body would make the entry a standing exemption:
	// a table added to the assembled statement later would be missing from the map
	// with nothing to report it, which is what the entry was written to prevent.
	t.Run("undeclared table in a fragment", func(t *testing.T) {
		want := []string{"the overlay declares the tables this function assembles, but text here names `usage`, which the declaration does not — add it"}
		got := opaqueDetails(t, "ListModelsWithUsage",
			declare("ListModelsWithUsage", map[string]string{"models": "R"}))
		if !reflect.DeepEqual(got, want) {
			t.Errorf("findings for a fragment the declaration does not cover:\n got %q\nwant %q", got, want)
		}
	})

	// The staleness signal is "nothing here was unreadable", so it is only as good as
	// the text check: while the scan stopped at the first table it could read, a
	// function whose second table was spliced in looked readable, and the report told
	// the reader to delete an entry the map still depended on.
	t.Run("still assembled", func(t *testing.T) {
		accesses, rep := walkFixtureMethod(t, "ListModelsJoined",
			declare("ListModelsJoined", map[string]string{"usage": "R"}))
		if want := []string{"pg.models R", "pg.usage R"}; !reflect.DeepEqual(accesses, want) {
			t.Errorf("accesses = %v, want %v", accesses, want)
		}
		if !rep.Clean() {
			t.Errorf("a live declaration was reported: %s\n\n%s", rep.Counts(), rep.Markdown())
		}
	})

	// The completeness check has to look past the first table in a literal for the
	// same reason the scan does. `FROM models m JOIN usage u` is one fragment, so an
	// entry declaring `models` would absorb the whole line — and the coordinator's
	// declared earnings queries are exactly this shape, a JOIN sitting beside a table
	// the entry already names.
	t.Run("second table in the same fragment", func(t *testing.T) {
		want := []string{"the overlay declares the tables this function assembles, but text here names `usage`, which the declaration does not — add it"}
		got := opaqueDetails(t, "ListModelsPaired",
			declare("ListModelsPaired", map[string]string{"models": "R"}))
		if !reflect.DeepEqual(got, want) {
			t.Errorf("findings for a second table beside a declared one:\n got %q\nwant %q", got, want)
		}
	})

	// The same completeness check, for a literal that gave up a name and then went
	// dark in the same breath. Reporting the keyword it trails off at and stopping
	// there dropped `models` from the account, so an entry naming only `usage` drew a
	// table the text never mentioned and hid the one it did.
	t.Run("table named before the text trails off", func(t *testing.T) {
		want := []string{"the overlay declares the tables this function assembles, but text here names `models`, which the declaration does not — add it"}
		got := opaqueDetails(t, "ListModelsTrailing",
			declare("ListModelsTrailing", map[string]string{"usage": "R"}))
		if !reflect.DeepEqual(got, want) {
			t.Errorf("findings for a name read before a trailing keyword:\n got %q\nwant %q", got, want)
		}
	})

	// And for a literal that gave up a name and then spliced the next one in. The
	// splice is decided on the spot, so the name has to be recorded before that
	// finding is raised — reporting and returning first left `models` out of the
	// account, and an entry naming only `usage` absorbed it.
	t.Run("table named beside a spliced one", func(t *testing.T) {
		want := []string{"the overlay declares the tables this function assembles, but text here names `models`, which the declaration does not — add it"}
		got := opaqueDetails(t, "ListModelsJoinedFrag",
			declare("ListModelsJoinedFrag", map[string]string{"usage": "R"}))
		if !reflect.DeepEqual(got, want) {
			t.Errorf("findings for a name read beside a splice:\n got %q\nwant %q", got, want)
		}
	})

	// A declaration on a function that runs no query explains nothing, and it is the
	// one finding with no call site to cite — it has to fall back to the function's
	// own declaration rather than indexing an empty list of call sites.
	t.Run("no database call", func(t *testing.T) {
		_, rep := walkFixtureMethod(t, "ModelLabel",
			declare("ModelLabel", map[string]string{"models": "R"}))
		want := "store/store.go:" + fixtureLine(t, "func (p *Postgres) ModelLabel")
		q := rep.OpaqueQueries[want]
		if q == nil {
			t.Fatalf("a declaration on a query-free function was not cited at %s: %s\n\n%s",
				want, rep.Counts(), rep.Markdown())
		}
		if !strings.Contains(q.Detail, "makes no database call") {
			t.Errorf("detail = %q, want it to say the function runs no query", q.Detail)
		}
	})

	// A name that matches no function draws nothing, so an entry that outlives a
	// rename is the same silence the declaration was meant to break.
	t.Run("names no function", func(t *testing.T) {
		_, rep := buildFixture(t, declare("NoSuchMethod", map[string]string{"models": "R"}))
		q := rep.OpaqueQueries["store:Postgres.NoSuchMethod"]
		if q == nil {
			t.Fatalf("a declaration matching no function went unreported: %s", rep.Counts())
		}
		if !strings.Contains(q.Detail, "no function reachable from a route has it") {
			t.Errorf("detail = %q, want it to say the name matches nothing", q.Detail)
		}
	})
}

// TestOverlayRejectsMuteDeclaration covers the validation that keeps the escape
// hatch honest. An entry naming no table would suppress every finding in the
// function and put nothing in the map in their place — a silencer wearing the
// shape of an explanation — and a driver package with no methods would switch off
// the readable-statement check for the whole service.
func TestOverlayRejectsMuteDeclaration(t *testing.T) {
	for _, tc := range []struct {
		name  string
		patch func(map[string]any)
		want  string
	}{
		{"no tables", func(driver map[string]any) {
			driver["assembled"] = map[string]any{"store:Postgres.ListModelsFiltered": map[string]any{}}
		}, "declares no tables"},
		{"empty table name", func(driver map[string]any) {
			driver["assembled"] = map[string]any{"store:Postgres.ListModelsFiltered": map[string]any{"": "R"}}
		}, "empty table name"},
		{"bad mode", func(driver map[string]any) {
			driver["assembled"] = map[string]any{"store:Postgres.ListModelsFiltered": map[string]any{"models": "RWX"}}
		}, "want R, W or RW"},
		{"no methods", func(driver map[string]any) {
			driver["methods"] = []any{}
		}, "disables the readable-statement check"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := loadPatchedOverlay(t, tc.patch)
			if err == nil {
				t.Fatalf("overlay loaded despite %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Errorf("error = %v, want it to mention %q", err, tc.want)
			}
		})
	}
}

// fixtureLine finds the line a fixture declaration is on, so a test can assert
// which position a finding cites without hard-coding a number that every edit to
// the fixture would invalidate.
func fixtureLine(t *testing.T, substring string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "fixture", "store", "store.go"))
	if err != nil {
		t.Fatal(err)
	}
	for i, line := range strings.Split(string(raw), "\n") {
		if strings.Contains(line, substring) {
			return strconv.Itoa(i + 1)
		}
	}
	t.Fatalf("fixture store.go contains no line with %q", substring)
	return ""
}

// TestOpaqueRemedyFitsTheFinding covers what the report tells the reader to do.
// Unreadable text has a remedy — keep the statement in one expression, or declare
// it — while a declaration finding already says what to do about itself, and
// attaching the same remedy there would tell the reader to declare tables in an
// entry the same line is asking them to delete.
func TestOpaqueRemedyFitsTheFinding(t *testing.T) {
	const remedy = "declare its tables in `deps.sqlDriver.assembled`"

	_, rep := walkFixtureMethod(t, "CountRows")
	if !strings.Contains(rep.Markdown(), remedy) {
		t.Errorf("unreadable text was reported without saying what to do about it:\n\n%s", rep.Markdown())
	}

	_, stale := walkFixtureMethod(t, "GetModel", declare("GetModel", map[string]string{"models": "R"}))
	if md := stale.Markdown(); strings.Contains(md, remedy) {
		t.Errorf("a stale declaration was told to declare tables it should delete:\n\n%s", md)
	}
}

// loadPatchedOverlay loads the fixture overlay with one patch applied to its
// `deps.sqlDriver` block, so what `config.Load` rejects is tested against the
// overlay shape the fixture actually uses rather than a hand-written stub.
func loadPatchedOverlay(t *testing.T, patch func(driver map[string]any)) error {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "fixture", "overlay.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	deps, ok := doc["deps"].(map[string]any)
	if !ok {
		t.Fatal("fixture overlay has no deps block")
	}
	driver, ok := deps["sqlDriver"].(map[string]any)
	if !ok {
		t.Fatal("fixture overlay has no deps.sqlDriver block")
	}
	patch(driver)
	out, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "overlay.json")
	if err := os.WriteFile(path, out, 0o600); err != nil {
		t.Fatal(err)
	}
	_, err = config.Load(path, "svcfix.test")
	return err
}

// TestFixtureUndocumentedNode covers the prose requirement: a node the graph
// draws with only a label is a boundary the page cannot explain.
func TestFixtureUndocumentedNode(t *testing.T) {
	_, rep := buildFixture(t, func(cfg *config.Config) {
		delete(cfg.DepDocs, "mem.cache")
	})
	if len(rep.UndocumentedN) != 1 || !strings.Contains(rep.UndocumentedN[0], "mem.cache") {
		t.Errorf("undocumented nodes = %v, want mem.cache reported", rep.UndocumentedN)
	}
	if rep.Clean() {
		t.Error("report is clean despite an undocumented node")
	}
}

// TestFixtureCycleEvidence is the regression for memoizing an incomplete result.
// Both routes enter the expandAliases/resolveAlias cycle, at different points; if
// the frame that saw the back edge memoized its truncated result, whichever route
// ran second would be missing half the cycle's state.
func TestFixtureCycleEvidence(t *testing.T) {
	g, _ := buildFixture(t)
	for _, key := range []string{"GET /v1/models", "GET /v1/aliases"} {
		ep := endpoints(g)[key]
		if ep == nil {
			t.Fatalf("route %q not extracted", key)
		}
		for _, node := range []string{"mem.aliases", "mem.cache"} {
			if !contains(ep.Dependencies, node) {
				t.Errorf("%s: %v does not include %s — a cycle result was memoized incomplete",
					key, ep.Dependencies, node)
			}
		}
	}
}

// TestFixturePreferredImpl asserts interface dispatch resolved to the Postgres
// store, not the in-memory one: the SQL evidence exists only on that side, and
// the citations must point at it.
func TestFixturePreferredImpl(t *testing.T) {
	g, _ := buildFixture(t)
	var seen bool
	for _, ep := range g.Routes {
		for _, a := range ep.Evidence {
			if strings.HasPrefix(a.Via, "store.Memory.") {
				t.Errorf("%s %s: evidence attributed to the non-preferred impl (%s at %s)",
					ep.Method, ep.Path, a.Via, a.Site)
			}
			if a.Node == "pg.models" && strings.HasPrefix(a.Via, "store.Postgres.") {
				seen = true
			}
		}
	}
	if !seen {
		t.Error("no pg.models evidence attributed to store.Postgres — dispatch did not reach the SQL")
	}
}

// TestFixtureEdges checks the aggregation the artifact actually publishes: one
// association per namespace/node pair, with the merged mode.
func TestFixtureEdges(t *testing.T) {
	g, _ := buildFixture(t)
	modes := map[string]string{}
	for _, e := range g.StateAccess {
		modes[e.Namespace+" -> "+e.Dependency] = e.Mode
	}
	want := map[string]string{
		"Public -> pg.models":  ir.ModeRead,
		"Public -> pg.usage":   ir.ModeWrite,
		"Public -> mem.cache":  ir.ModeBoth,
		"Public -> mem.flight": ir.ModeBoth,
		"Public -> ext.icons":  ir.ModeBoth,
		"Public -> ext.opaque": ir.ModeRead,
		"Admin -> pg.usage":    ir.ModeRead,
		"Admin -> mem.admins":  ir.ModeRead,
		"Legacy -> mem.cache":  ir.ModeRead,
	}
	for key, mode := range want {
		if modes[key] != mode {
			t.Errorf("edge %s mode = %q, want %q", key, modes[key], mode)
		}
	}
	if g.StateCoverage.Ambiguous != 0 {
		t.Errorf("coverage reports %d ambiguous associations, want 0", g.StateCoverage.Ambiguous)
	}
	if g.StateCoverage.TotalAssociations != len(g.StateAccess) {
		t.Errorf("coverage total = %d, edges = %d", g.StateCoverage.TotalAssociations, len(g.StateAccess))
	}
}

// TestFixtureWriteThroughSkippedField is the regression for a write that reaches
// its node through a chain link the overlay does not name. flight.Cache is known
// by type, its fields are absorbed by the package default, and its fill is
// `c.entries[key] = value` — so the only place the node can be attributed is the
// receiver, one link up from the expression being written. A walk that visited
// the base of a write target as a read published this cache read-only: a reader
// would see a cache nothing ever fills, and the same understatement applied to
// every `deps.types` surface whose method name carries no verb.
func TestFixtureWriteThroughSkippedField(t *testing.T) {
	g, _ := buildFixture(t)
	ep, ok := endpoints(g)["GET /v1/aliases"]
	if !ok {
		t.Fatal("GET /v1/aliases not extracted")
	}
	var modes []string
	for _, a := range ep.Evidence {
		if a.Node != "mem.flight" {
			continue
		}
		modes = append(modes, a.Mode)
		if a.Mode == ir.ModeWrite && strings.Contains(a.Site, "flight/flight.go") {
			return // the fill is evidenced as a write, at the statement that writes
		}
	}
	t.Errorf("no write to mem.flight was evidenced inside flight.Cache.Do; modes seen = %v", modes)
}

// TestFixtureSchemaDefinitions pins the derived table definitions. The claim worth
// protecting is that a table's shape is the CREATE *plus* its migrations: `family`
// exists only in an `ALTER TABLE ... ADD COLUMN`, so a definition read from the
// CREATE alone would publish a schema no live database has.
func TestFixtureSchemaDefinitions(t *testing.T) {
	g, _ := buildFixture(t)
	models := g.Tables["models"]
	if models == nil {
		t.Fatalf("no definition derived for models; tables = %v", sortedTableNames(g))
	}
	if models.Node != "pg.models" {
		t.Errorf("models.node = %q, want pg.models", models.Node)
	}
	type col struct {
		typ, extra string
		migration  bool
	}
	want := map[string]col{
		"id":     {"text", "PRIMARY KEY", false},
		"name":   {"text", "NOT NULL", false},
		"price":  {"numeric(10, 2)", "NOT NULL DEFAULT 0", false},
		"family": {"text", "NOT NULL DEFAULT ''", true},
	}
	if len(models.Columns) != len(want) {
		t.Errorf("models has %d columns, want %d: %+v", len(models.Columns), len(want), models.Columns)
	}
	for _, got := range models.Columns {
		exp, ok := want[got.Name]
		if !ok {
			t.Errorf("unexpected column %+v", got)
			continue
		}
		delete(want, got.Name)
		if got.Type != exp.typ || got.Extra != exp.extra || got.Migration != exp.migration {
			t.Errorf("column %s = {%q %q migration=%v}, want {%q %q migration=%v}",
				got.Name, got.Type, got.Extra, got.Migration, exp.typ, exp.extra, exp.migration)
		}
		// Every column cites the line that declares it, and the citation is a
		// link a reader can follow.
		if !strings.HasPrefix(got.Site, "store/store.go:") {
			t.Errorf("column %s site = %q, want a store/store.go line", got.Name, got.Site)
		}
		if !strings.Contains(got.URL, fixtureRevision) || !strings.HasSuffix(got.URL, "#L"+lineOf(got.Site)) {
			t.Errorf("column %s url = %q, does not link its own line at the pinned revision", got.Name, got.URL)
		}
	}
	for name := range want {
		t.Errorf("column %s was not derived", name)
	}
	// The migration column is cited past the CREATE that lacks it, which is the
	// evidence that the line offset inside the raw literal is counted.
	if a, b := lineOf(models.Columns[0].Site), lineOf(byName(t, models, "family").Site); a >= b {
		t.Errorf("family cited at line %s, not after the CREATE at line %s", b, a)
	}

	usage := g.Tables["usage"]
	if usage == nil {
		t.Fatalf("no definition derived for usage; tables = %v", sortedTableNames(g))
	}
	// Both spellings of a table-level constraint: with and without a space before
	// the paren. `CHECK(...)` unspaced used to parse as a column literally named
	// "check(tokens >= 0)".
	var cons []string
	for _, c := range usage.Constraints {
		cons = append(cons, c.Text)
	}
	if !reflect.DeepEqual(cons, []string{"UNIQUE (id, created_at)", "CHECK(tokens >= 0)"}) {
		t.Errorf("usage constraints = %v, want both table-level constraints", cons)
	}
	if names := columnNames(usage); !reflect.DeepEqual(names, []string{"id", "tokens", "created_at"}) {
		t.Errorf("usage columns = %v; a table-level constraint must not be read as a column", names)
	}
	var kinds []string
	for _, stmt := range usage.DDL {
		kinds = append(kinds, stmt.Kind)
	}
	if !reflect.DeepEqual(kinds, []string{"create", "index"}) {
		t.Errorf("usage ddl kinds = %v, want [create index]", kinds)
	}
}

// TestFixtureUndefinedTable covers the gate behind the definitions: a `pg.*` node
// with no CREATE TABLE means the map draws a table the service never creates, and
// clicking it would show an empty schema.
func TestFixtureUndefinedTable(t *testing.T) {
	_, rep := buildFixture(t, func(cfg *config.Config) {
		cfg.Labels["pg.ghost"] = "ghost"
	})
	if len(rep.UndefinedTable) != 1 || !strings.Contains(rep.UndefinedTable[0], "pg.ghost") {
		t.Errorf("undefined tables = %v, want pg.ghost reported", rep.UndefinedTable)
	}
	if rep.Clean() {
		t.Error("report is clean despite a pg node with no table definition")
	}
	if !strings.Contains(rep.Markdown(), "no table definition") {
		t.Error("report does not carry the undefined-table section")
	}
}

func byName(t *testing.T, table *ir.Table, name string) ir.Column {
	t.Helper()
	for _, col := range table.Columns {
		if col.Name == name {
			return col
		}
	}
	t.Fatalf("table %s has no column %s", table.Name, name)
	return ir.Column{}
}

func columnNames(table *ir.Table) []string {
	out := []string{}
	for _, col := range table.Columns {
		out = append(out, col.Name)
	}
	return out
}

func lineOf(site string) string {
	if i := strings.LastIndex(site, ":"); i >= 0 {
		return site[i+1:]
	}
	return ""
}

func sortedTableNames(g *ir.Graph) []string {
	out := []string{}
	for name := range g.Tables {
		out = append(out, name)
	}
	sort.Strings(out)
	return out
}

// TestFixtureArtifacts renders the two published files and checks they are
// self-consistent: the JSON parses back, and the HTML carries the same graph.
func TestFixtureArtifacts(t *testing.T) {
	g, _ := buildFixture(t)
	inventory, err := g.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	var round ir.Graph
	if err := json.Unmarshal(inventory, &round); err != nil {
		t.Fatalf("inventory.json does not parse: %v", err)
	}
	if round.Revision != fixtureRevision {
		t.Errorf("revision = %q, want %q", round.Revision, fixtureRevision)
	}
	if len(round.Routes) != len(g.Routes) || len(round.Nodes) != len(g.Nodes) {
		t.Errorf("round trip lost data: %d/%d routes, %d/%d nodes",
			len(round.Routes), len(g.Routes), len(round.Nodes), len(g.Nodes))
	}
	if !round.Generator.OverlayComplete {
		t.Error("overlayComplete is false for a complete fixture overlay")
	}
	page, err := render.HTML(g, inventory)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Fixture service", "GET /v1/admin/stats", "pg.usage"} {
		if !strings.Contains(string(page), want) {
			t.Errorf("rendered page does not mention %q", want)
		}
	}
	// The page must be self-contained: no external script or style origins.
	for _, bad := range []string{"src=\"http", "href=\"http://", "cdn.jsdelivr", "unpkg.com"} {
		if strings.Contains(string(page), bad) {
			t.Errorf("rendered page loads a remote asset (%q); it must be self-contained", bad)
		}
	}
}

// TestPageProvenanceViews pins the page's provenance control. The map's whole
// claim is that a reader can tell which facts a compiler stands behind, and the
// README saying so is not the same as the page showing it — so all three views are
// asserted here: `all`, the subtractive `code` view that withholds every string no
// gate can contradict, and `overlay`, which marks each curated layer in place
// against the convention that *unmarked means derived*.
//
// It also pins that the control is a view, not a filter: Reset clears the filters
// and the focus and leaves the view alone, because turning off a filter and losing
// the answer to "who wrote this" would be a surprise.
func TestPageProvenanceViews(t *testing.T) {
	html := renderFixturePage(t)
	for _, want := range []string{
		`data-view="all"`, // the three-way control
		`data-view="code"`,
		`data-view="overlay"`,
		`class="bar" id="codebar"`, // what each view explains about itself
		`class="bar" id="provbar"`,
		`id="withheld"`,             // the code view accounts for what it removed
		"unmarked = <b>derived</b>", // the convention that makes silence meaningful
		"<b>curated structure</b>",  // a person decided it and it moves an edge
		"<b>prose</b>",              // enrichment: presence-checked only
		"<b>unchecked prose</b>",    // roles/credentials: no gate at all
		"body.v-overlay .p-c",       // the three marks, shown only under `overlay`
		"body.v-overlay .p-p",
		"body.v-overlay .p-x",
		"svg.prov .hull-label",       // the curated indirection inside the graph itself
		"body.v-code .prose-section", // sections that are only prose go whole
		`class="prose-section"`,      // …and something actually carries that class
		"classList.add('v-' + next)", // the view is a body class, so CSS can subtract
		"var(--barh)",                // the banner gives its height back to the graph
	} {
		if !strings.Contains(html, want) {
			t.Errorf("page is missing the provenance control's %q", want)
		}
	}
	// The subtraction has to run through one predicate, or "code only" becomes a
	// list of places someone remembered. say() withholds a sentence, label() falls
	// back to the node id, and both answer to showProse().
	for _, want := range []string{
		"const showProse = () => state.view !== 'code'",
		"const say = s => (showProse() ? (s || '') : '')",
		"showProse() ? (DATA.labels && DATA.labels[id]) || id : id",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("code view is missing its withholding primitive %q", want)
		}
	}
	// Every layer a person is responsible for is actually marked somewhere: the
	// scaffolding existing without call sites would render a lens that marks nothing.
	for _, fn := range []string{"pc(el(", "pp(el(", "px(el("} {
		if !strings.Contains(html, fn) {
			t.Errorf("no render site calls %s — a mark with no use marks nothing", fn)
		}
	}
	reset := slice(t, html, "getElementById('reset').onclick", "};")
	for _, leak := range []string{"view", "prov"} {
		if strings.Contains(reset, leak) {
			t.Errorf("Reset touches %q; the provenance view is a view over the page, not a filter on it", leak)
		}
	}
	if !strings.Contains(reset, "focus: null") {
		t.Error("Reset leaves the focused node shadowing the rest of the system")
	}
}

// TestPageTopologyFingerprint pins the mechanism that makes "the overlay is
// additive" checkable instead of asserted. The caption publishes a hash of the
// drawn topology, and it is read back off the DOM — a value computed once from the
// data could not move by construction, so it would prove nothing about what the
// page actually rendered under a different view.
func TestPageTopologyFingerprint(t *testing.T) {
	html := renderFixturePage(t)
	for _, want := range []string{
		`id="topo"`,
		"const nodeTopo = n => n.id + '@' + n.group + '@' + n.cluster;",
		"const linkTopo = l => l.s.id + '>' + l.t.id + ':' + l.mode;",
		"'data-topo': nodeTopo(n)",
		"'data-topo': linkTopo(l)",
		"gsvg.querySelectorAll(sel)", // read back from what was drawn, not from DATA
		"topoFingerprint()",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("page is missing the topology fingerprint's %q", want)
		}
	}
	// The fingerprint has to be recomputed on every redraw, including the redraw a
	// view change triggers, or it stops being evidence.
	draw := slice(t, html, "function draw() {", "}")
	if !strings.Contains(draw, "topoFingerprint()") {
		t.Error("draw() does not refresh the fingerprint, so a view change could move the graph unnoticed")
	}
	if setView := slice(t, html, "function setView(next) {", "\n}"); !strings.Contains(setView, "draw();") {
		t.Error("setView does not redraw, so the fingerprint would not be re-read per view")
	}
}

// TestPageExplorerAffordances pins the parts of the page that answer "what does
// this thing touch, and what is it" rather than "what exists": labels that keep one
// size at every zoom and are dropped when they would collide, a click that shadows
// everything off the clicked node's edges, a table drawer that can hold a 79-column
// definition, the identity filter, and the prose fields the pinned panel exists to
// show.
func TestPageExplorerAffordances(t *testing.T) {
	html := renderFixturePage(t)

	// Labels must live outside the scaled scene. Text that scales with the zoom
	// collides identically at every zoom, which is what buried the picture.
	scene := strings.Index(html, `<g id="scene">`)
	labels := strings.Index(html, `<g id="glabels">`)
	if scene < 0 || labels < 0 {
		t.Fatal("page has no #scene or no #glabels layer")
	}
	if labels < scene {
		t.Fatal("#glabels is declared before #scene")
	}
	if between := html[scene:labels]; strings.Count(between, "<g ") != strings.Count(between, "</g>") {
		t.Errorf("#glabels sits inside #scene (%d open <g> vs %d close between them); "+
			"labels would scale with the zoom", strings.Count(between, "<g "), strings.Count(between, "</g>"))
	}

	for _, want := range []string{
		"const LABEL_BUDGET",   // a bounded number of names on screen at once
		"function placeLabels", // …placed per frame in screen space
		"const sx = x =>", "const sy = y =>",
		".glabel.pri",    // the focused neighbourhood outranks degree
		".gnode.shade {", // click-to-shadow, the interaction that was missing
		".glink.shade {", // including the edges, or the shadow reads as a hairball
		"function focusNode", "function clearFocus",
		"body.focused .gfocus", `id="gfocusclear"`,
		"'Escape'",      // Esc clears it
		".gschema.wide", // the drawer widens instead of only scrolling
		".ginfo.pinned", // a click pins a panel wide enough for the prose
		`id="ont"`,      // the ontological axis
		`value="source"`, `value="literal"`, `value="symbol"`, `value="unreached"`,
		"const ontOK = dep =>",
		"function identTier",
	} {
		if !strings.Contains(html, want) {
			t.Errorf("page is missing the explorer affordance %q", want)
		}
	}

	// The graph names nodes by their short name; the long curated label is what
	// made the picture unreadable, and it belongs in the panel.
	if !strings.Contains(html, "const shortName = id =>") {
		t.Error("graph labels are not shortened, so long curated labels are back on the canvas")
	}

	// Regression: the `unreached` identity asks for nodes no endpoint reaches, so
	// deriving their visibility from matching endpoints hid the only nodes the filter
	// exists to show. Both the graph and the boundary chips must select them directly.
	if !strings.Contains(html, "const ontPicks = id =>") {
		t.Fatal("no ontPicks predicate: the `unreached` identity has nothing to select nodes by")
	}
	for _, site := range []string{
		slice(t, html, "function styleGraph() {", "const selected ="),
		slice(t, html, "function drawBoundaries() {", "\n}"),
	} {
		if !strings.Contains(site, "ontPicks(") {
			t.Error("a visibility site ignores ontPicks, so filtering to `unreached` hides " +
				"the declared-but-unreached nodes it asked for")
		}
	}

	// The pinned panel must render every prose field the overlay carries for a
	// node. Rendering one of eight is what made clicking an in-memory node useless.
	docs := slice(t, html, "const DOC_FIELDS = [", "];")
	for _, field := range []string{"represents", "construction", "access", "concurrency", "lifecycle", "restart"} {
		if !strings.Contains(docs, "'"+field+"'") {
			t.Errorf("the pinned panel does not render depDocs.%s", field)
		}
	}
}

// TestOverlayLegendFieldsMatchSchema guards a failure mode that renders silently:
// the actors and credentials legends read their fields by name, so a field the
// overlay does not use produces an empty card rather than an error. Every key the
// page reads has to exist on the loaded overlay.
func TestOverlayLegendFieldsMatchSchema(t *testing.T) {
	g, _ := buildFixture(t)
	// Scoped to the legend's own body: `r.namespace` elsewhere on the page contains
	// `r.name`, so a whole-document search cannot answer this question.
	legend := slice(t, renderFixturePage(t), "function drawLegend() {", "\n}")
	if len(g.Roles) == 0 || len(g.Credentials) == 0 {
		t.Fatal("fixture overlay declares no roles or credentials to check the legend against")
	}
	for _, want := range []string{"r.title", "r.kind", "r.summary", "r.callers", "r.credentials", "r.custody"} {
		if !strings.Contains(legend, want) {
			t.Errorf("the actors legend does not read %s", want)
		}
	}
	for _, want := range []string{"c.title", "c.class", "c.issuer", "c.holder", "c.lifetime",
		"c.clientStorage", "c.serverStorage", "c.validation", "c.usedBy", "c.sources"} {
		if !strings.Contains(legend, want) {
			t.Errorf("the credentials legend does not read %s", want)
		}
	}
	// The inverse: a name the overlay does not carry renders an empty card instead
	// of an error, which is the failure this test exists to catch.
	for _, dead := range []string{"r.name", "r.description", "c.name", "c.description"} {
		if strings.Contains(legend, dead) {
			t.Errorf("the legend still reads %s, which the overlay schema does not carry", dead)
		}
	}
}

// TestNodeIdentityOrigin pins the ontological axis the page filters on. Whether
// source *reaches* a node is derived; how much of the node's *name* a person
// invented is a separate question, and this is the answer to it. A `pg.*` node is
// named by the CREATE TABLE source issues, a host is a curated name bound to a
// literal the compiler found, and a field, type or function node is a curated name
// bound to a symbol.
func TestNodeIdentityOrigin(t *testing.T) {
	g, _ := buildFixture(t)
	want := map[string][]string{
		"pg.models":    {"sql"}, // source names it
		"pg.usage":     {"sql"},
		"ext.icons":    {"hosts"},     // curated name on a literal
		"ext.opaque":   {"functions"}, // curated name on a symbol
		"mem.cache":    {"fields"},
		"mem.aliases":  {"fields"},
		"mem.admins":   {"fields"},
		"mem.inflight": {"fields"},
		// Reached two ways — through the field that holds it and through the type
		// that is it — so both tables named it.
		"mem.flight": {"fields", "types"},
	}
	for id, origins := range want {
		node, ok := g.Nodes[id]
		if !ok {
			t.Errorf("fixture has no node %q", id)
			continue
		}
		if !reflect.DeepEqual(node.NamedBy, origins) {
			t.Errorf("%s namedBy = %v, want %v", id, node.NamedBy, origins)
		}
	}
	// Sentinels are decisions not to draw a node, so they must name nothing.
	for _, sentinel := range []string{"@skip", "@sql", "@through"} {
		if node, ok := g.Nodes[sentinel]; ok {
			t.Errorf("sentinel %q became a node (namedBy %v)", sentinel, node.NamedBy)
		}
	}
	// Every drawn node has an origin: one with none would filter into no bucket at
	// all and quietly vanish from the ontological view.
	for id, node := range g.Nodes {
		if len(node.NamedBy) == 0 {
			t.Errorf("node %q has no identity origin, so no ontology filter can reach it", id)
		}
	}
}

// renderFixturePage renders the published page over the fixture service. The
// stylesheet and the behaviour are separate files that the generator injects, so
// the assertions have to run against the rendered output, not against page.html.
func renderFixturePage(t *testing.T) string {
	t.Helper()
	g, _ := buildFixture(t)
	inventory, err := g.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	page, err := render.HTML(g, inventory)
	if err != nil {
		t.Fatal(err)
	}
	return string(page)
}

// slice returns the text from `open` up to the next `close`, failing the test when
// either marker is gone — so a renamed function shows up as a missing marker rather
// than as an assertion that silently passes over an empty string.
func slice(t *testing.T, html, open, close string) string {
	t.Helper()
	i := strings.Index(html, open)
	if i < 0 {
		t.Fatalf("page has no %q", open)
	}
	rest := html[i+len(open):]
	j := strings.Index(rest, close)
	if j < 0 {
		t.Fatalf("no %q closes %q", close, open)
	}
	return rest[:j]
}

// TestCheckWritesNothing covers the contract the ignored artifact depends on:
// -check renders the whole map — so a broken template or an unmarshalable graph
// still fails the gate — but leaves no file behind for someone to commit.
func TestCheckWritesNothing(t *testing.T) {
	root, err := filepath.Abs("testdata/fixture")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	// -out is resolved against -root, so the throwaway directory has to be
	// expressed as the hop from the fixture to it.
	out, err := filepath.Rel(root, dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := run(root, "svcfix.test", "overlay.json", out, fixtureRevision, true, true); err != nil {
		t.Fatalf("check failed on the complete fixture: %v", err)
	}
	left, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(left) != 0 {
		names := []string{}
		for _, e := range left {
			names = append(names, e.Name())
		}
		t.Errorf("-check wrote %v; it must only report", names)
	}

	// The same run without -check is what CI and Pages publish.
	if err := run(root, "svcfix.test", "overlay.json", out, fixtureRevision, false, true); err != nil {
		t.Fatalf("generate failed on the complete fixture: %v", err)
	}
	for _, name := range []string{"inventory.json", "system-map.html", "report.md"} {
		if _, err := os.Stat(filepath.Join(dir, name)); err != nil {
			t.Errorf("generate did not write %s: %v", name, err)
		}
	}
}

func contains(list []string, want string) bool {
	for _, s := range list {
		if s == want {
			return true
		}
	}
	return false
}
