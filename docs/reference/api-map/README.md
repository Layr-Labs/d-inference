# Darkbloom system map

A generated map of Darkbloom's entry points: what authorizes each one, what state
its reachable code touches, and whether that access reads or writes. The
coordinator is the first service extracted; the provider and the two consoles are
not extracted yet, and each will land as another cluster in the same graph
without a schema change.

**The map is not committed.** It is built from source on demand: by CI for every
pull request (downloadable from the `System Map` job), and by the Pages workflow
for every master push. A generated file in git would be a second copy of the truth
that has to be kept honest; building it instead means it cannot be stale, and a
coordinator change costs no diff.

| File | Content | In git |
|---|---|---|
| `system-map.html` | Self-contained explorer: full-screen clustered knowledge graph, routes, dependency nodes, associations with their wiring order and indirection, derived Postgres table definitions and the foreign keys between them. Open it in a browser; no server needed. | generated |
| `inventory.json` | The same graph as data — the contract for any other consumer. | generated |
| `report.md` | Drift report. Empty means source and overlay agree. | generated |
| [overlay.json](overlay.json) | The curated half of the map (see below). This is the only file to hand-edit. | **committed** |

To read it locally, or after changing a mapped service's routes, state, queries or
outbound calls:

```bash
make -C tools/systemmap          # write the three artifacts here (git-ignored)
make -C tools/systemmap check    # render them, write nothing, fail on drift (what CI runs)
make -C tools/systemmap test     # extractor tests
```

Published copy, once Pages is enabled: `https://layr-labs.github.io/d-inference/`
— `index.html` is the explorer, with `inventory.json` and `report.md` beside it.

## Derived vs. curated

The split is the whole point: a reader can tell which facts a compiler stands
behind and which a person wrote.

**Derived from source** by `tools/systemmap` — type-checked with `go/packages`,
never hand-edited:

- the route table, read out of `(*api.Server).routes` (method, path, registered
  mux pattern, handler, file:line)
- the middleware chain each handler was wrapped in, recognized structurally by
  the `http.HandlerFunc → http.HandlerFunc` shape
- the authorization gates a route's code calls (`isAdminAuthorized`,
  `requirePublishingAPIKey`, …), found by a depth-bounded search from the
  handler and its middleware
- the dependency nodes each route reaches, by walking the transitive call graph:
  struct fields for in-memory state, SQL statements for `pg.*` tables (through
  interface dispatch into the Postgres store), URL and endpoint literals —
  including values held in package constants — for external surfaces
- the access mode (`R`, `W`, `RW`) per association, from SQL verbs, `sync` and
  `sync/atomic` primitives, method-name verbs, and assignment shape
- the **wiring** of each route: the order the request meets its constructions, the
  call path to each one, the indirection that path goes through, how many source
  sites touch it and whether any of them is inside a loop (see *What order, and
  through what*)
- every `pg.*` table's definition — its columns, their types, the table-level
  constraints and the DDL statements — read out of the `CREATE TABLE` the service
  issues plus every `ALTER TABLE ... ADD COLUMN` migration that grew it afterwards
- every declared **foreign key** between those tables, read out of the same DDL —
  inline `REFERENCES`, table-level `FOREIGN KEY`, and the ones a later
  `ALTER TABLE ... ADD CONSTRAINT` added (see *Table relationships*)
- every citation: `file:line` plus the symbol that evidenced it

**Curated** in `overlay.json`, because source cannot state it:

- node identity and labels (which fields group into one named surface, what to
  call it)
- the clusters — which process, store or third party each kind of node lives in
- namespaces and auth-class names
- who calls an endpoint, and the prose describing it — the prose half is generated
  in CI into `prose.json` and hashed against the facts it describes, so it is the
  one curated layer that goes stale loudly (see *The amber tier is generated*)

### The three provenance views

The split is only useful if a reader can see it, so the page reads three ways,
selected in the toolbar:

| View | What it shows |
|---|---|
| **All** | every fact, nothing marked — the default |
| **Code only** | *subtractive*: only what the compiler derived, plus the curated identifiers the drift gates prove against source in both directions (node ids, namespaces, auth classes). Every string whose text no gate can contradict is withheld, and the banner counts what it removed |
| **Overlay marked** | every fact, with each curated layer marked in place |

`Code only` is the view that makes the central claim checkable rather than
asserted. "The overlay is additive" means the enrichment cannot move an edge — so
the page publishes a fingerprint of the **drawn topology** (node ids, their groups
and clusters, every edge and its access mode) in the caption, read back off the
rendered DOM rather than computed from the data, and it is the same in all three
views. What disappears between `All` and `Code only` is exactly the half a language
model can write.

Under `Overlay marked`, the marks distinguish the two curated layers, and
everything left plain is what `go/packages` derived:

| Mark | Layer | What a wrong entry does | Gate |
|---|---|---|---|
| blue | **curated structure** — node ids, cluster and category titles, namespace and auth-class names, the graph's boundary rings | **moves an edge**: changes which node exists, which ring it falls inside, what auth class a route is filed under | bidirectional — unmapped source is drift, and an overlay entry whose source is gone is drift |
| amber | **prose** — route descriptions and details, node labels, `depDocs`, `categoryDocs`, callers | nothing the graph draws | presence only: the gate asks *is there prose for this node*, never *is it still true* |
| dashed amber | **unchecked prose** — the Actors and Credentials sections | nothing the graph draws | none at all; source cannot contradict those words |

Inside the graph the same rule holds: every node and every edge is derived, and
the boundary names are underlined because the ring is the one piece of curated
indirection in the picture — a category names its cluster, a namespace joins its
service's. The control is a view over the page rather than a filter on it, so
**Reset** clears the search, the dropdowns and the focus, and leaves the view
alone.

The asymmetry in that table is the point, and it is what bounds where synthesis is
allowed: prose is safe to generate because a wrong sentence is a comprehension bug,
while a wrong structural entry silently relocates an edge with the build still
green. `TestPageProvenanceViews` pins the three views, the withholding primitives
and the unmarked-means-derived convention; `TestPageTopologyFingerprint` pins the
fingerprint that keeps "additive" honest.

### The ontological axis: who named each node

Whether source *reaches* a node is derived. How much of the node's *identity* a
person invented is a separate question, and `namedBy` on every node answers it —
computed from the overlay's own mapping tables and the derived schema, not judged.
The **identity** filter selects on it:

| Tier | Meaning | Example |
|---|---|---|
| **source** | source itself declares the name | `pg.provider_models` — the name is in the `CREATE TABLE` |
| **literal** | a curated name bound to a string literal the compiler found | `ext.stripe` from a host, a remote endpoint, a protocol message |
| **symbol** | a curated name bound to a Go symbol | a struct field, a type or a function surface — `mem.*` |
| **unreached** | declared and labeled, but no HTTP endpoint reaches it | `mdm.commands`, `mem.telemetry_limit` — surfaces only a background worker touches |

The last one is a node-level question, not an endpoint one, so it selects those
nodes directly: the endpoint table is correctly empty, and the nodes light up in the
graph and the boundary chips. Being unreached is informational rather than drift —
the map is scoped to HTTP entry points — but the overlay's claims about those
surfaces are still checked against source.

So "where is there LLM synthesis, and where is there none" is answerable
positionally: filter to **source** and every name on screen came out of the
compiler; the `literal` and `symbol` tiers are where a person chose the word, even
though the binding underneath is checked in both directions.

### The amber tier is generated, and falsifiable

Prose is the half nobody keeps up to date, and the table above says why it cannot
be made to: its gate asks *is there a sentence here*, never *is the sentence still
true*. A description written when an endpoint was unauthenticated survives the
commit that puts it behind an API key, because nothing in a presence check can
notice.

So the amber tier is written in CI, from the facts the extractor derived, and
stored in `prose.json` beside the overlay:

```
make -C tools/systemmap plan      # what prose is missing, and from which facts — no key needed
make -C tools/systemmap enrich    # write it, then re-run the gate
```

`plan` writes a manifest: one request per route with no description and per node
with no name or no `depDocs`, each carrying **only** what the map derived for it —
the method, path, handler, namespace, auth class, middleware, gates and the state
it touches with the mode; for a node, what names it, which namespaces reach it, and
its columns if source declares a table. `cmd/enrich` turns each request into an
entry and stores a hash of those facts with it. Three properties follow, and
together they are the whole reason to generate rather than write:

- **Prose that no longer matches its source is drift.** When a route gains a gate,
  changes auth class or starts touching another table, the hash moves and `-check`
  reports `Generated prose whose source has changed`. That is the finding the
  hand-written workflow could not produce.
- **A sentence cannot invent state.** The validator rejects a completion naming a
  node the request's own facts do not list, before it reaches the file, and tells
  the model which claim was unsupported. What survives is grounded in the same
  derivation the graph is drawn from.
- **Generated text cannot move an edge.** It lands in `description`, `details`,
  `label` and the `depDocs` fields — the amber row, "nothing the graph draws". A
  new route whose *cluster*, namespace or auth class is missing still fails the
  gate and still waits for a person, because those are the blue row.

Hand-written prose in `overlay.json` always wins: an entry a person wrote is never
regenerated, and its generated counterpart is pruned rather than kept as a second
answer. `callers` is never generated at all — who calls an endpoint is a claim
about the world outside this repository, and nothing here can check it.

The output is a commit on the pull request's branch (`.github/workflows/
systemmap-enrich.yml`), so every generated sentence is read by whoever reviews the
code that caused it. Fork pull requests get no secrets, so there the job publishes
the manifest and fails with instructions rather than pretending the prose exists.

### Clicking things

The graph is an explorer, not a poster. Node labels live in an unscaled layer above
the scene, so text keeps one size at every zoom and is dropped when it would
collide — the canvas names nodes by their short id and leaves the long curated label
to the panel. Clicking a node **shadows everything off its edges** and pins a wider
panel carrying that node's full `depDocs` prose (what it represents, how it is
constructed, how it is accessed, its concurrency, lifecycle and restart behaviour)
alongside the derived reach list and citations. Clicking an **endpoint** numbers its
own wires — 1, 2, 3 … in the order the request meets each construction — and pins the
ordered wiring list beside them: the access mode, the indirection glyph
(`→ ⇢ ↳ ⇉`, matching the wire's dash and arrowhead), the touch-site count, whether it
is in a loop, and the call path itself. The endpoint's row in the table below states
the same list with the `file:line` each touch was read off, because a claim about
order is only useful if you can check it. Clicking a `pg.*` node opens its derived
definition, which can be widened to full width because some of these tables have 79
columns. Esc or a click on empty canvas clears the focus.

Arrowheads are the same vocabulary in the picture: a filled head is a direct call, a
hollow one an interface, a diamond a `defer`, an open barb a goroutine — and the head's
colour is the access mode, so one glyph carries both facts. They are sized in screen
pixels rather than scene units (a marker inside the zoomed scene is scaled with it, which
drew them three pixels wide at the zoom that fits the whole map), so a head is the same
size at every zoom. Which wires carry one is a judgement about legibility, not a fact
about the map: **↦** in the graph toolbar switches between `auto` — every live wire once a
filter, a focus or a close zoom has narrowed the picture below 140 of them, and otherwise
only the wire being read — `all`, and `read`. A focused node's own edges are always
pointed, and a shaded one never is — and a focused node's wires are *brightened*, not just
pointed, because SVG opacity applies to a path's markers too and a wire's resting 22% turns
a 9px glyph into a rumour.

The unfiltered coordinator map is on the wrong side of that budget on purpose, and it is
worth stating how far: at the fitted zoom, 846 of the 857 heads would have another head
within their own width, 88 on average, and one 9-pixel square would hold 107 of them.
Moving them to the wires' midpoints — five times less crowded — still leaves 844 touching.
No arrangement points every wire in this system legibly, so the picture has to be narrowed
first: hover a dot, click one, filter, or zoom past roughly twice the fitted scale, where
you have stopped looking at the system and started reading a corner of it. The `↦` button's
tooltip says which rule is in force, how many wires are on the picture, and what would
change it, so "why do I see no arrows" is answered in the toolbar rather than inferred.

A number sits on the midpoint of the wire it belongs to when it can. On the widest handler
57 wires leave one square and their midpoints pile up, so a number that cannot fit there
slides along its own curve, then steps off it, and any number that ended up more than a
few pixels from its wire is joined back to it by a **dashed tick in its own colour**. The
tick is what makes the moved numbers readable rather than merely present: in a fan that
dense, another wire is routinely within a pixel of the space a number moved into, so
proximity cannot say which wire it belongs to and the picture states it instead. Whatever
the picture cannot fit, it drops from the end — the numbering reads `1, 2, 3 …` up to
wherever it runs out, and never with a hole in it, which is checked rather than eyeballed
(`render/webtest/wiring.test.mjs`).

## How a line gets drawn

One association, end to end. Nothing here is pattern-matched on names:

1. **Entry point.** `(*api.Server).routes` is walked as syntax: every
   `mux.Handle*` call yields a method, a path and a handler expression. Wrapper
   calls of shape `http.HandlerFunc → http.HandlerFunc` are recorded as the
   middleware chain.
2. **Reachable code.** From the handler, the call graph is walked transitively
   through the packages `deps.traverse` allows, resolving interface calls to the
   preferred implementation (`deps.preferImpl`, so `store.Store` lands in the
   Postgres impl where the SQL actually is). Cycles memoize only complete
   results.
3. **Attribution.** At each expression the walker asks, in a fixed order: is this
   call a `deps.functions` surface? is the receiver's type in `deps.types`? is
   this a field with a `deps.fields` node (exact key, then `Struct.*`, then
   `*.field`, then `deps.packageDefault`)? is it a URL host, a client endpoint
   literal, or a protocol message constant? is it a SQL string naming a table the
   schema declares? The first answer wins; `@skip`/`@sql`/`@through` are answers
   too — "declared, deliberately not a node".
4. **Mode.** `R`, `W` or `RW` comes from the SQL verb, the `sync`/`sync/atomic`
   primitive used, the method-name verb, or the assignment shape. A write carries
   down the expression it writes through — `c.entries[k] = v` writes `c.entries`
   *and* `c` — so a cache whose fill happens behind a field the overlay does not
   name is still published as a write.
5. **Aggregation.** Per-endpoint accesses become the drawn edge, plus a
   `(namespace, node)` roll-up carrying the merged mode, the reason, the routes
   and up to six `file:line` citations.
6. **Boundaries.** The node's category is the prefix before its first dot; the
   category names its cluster. The endpoint's namespace comes from the
   `namespaces` rules; its cluster is its service. Groups fall out of those two
   facts.

Step 6 is why the picture is extensible: adding state, a route, a table or a host
changes steps 1–5 mechanically, and the only thing a person supplies is a name and
which side of a boundary it is on.

### What order, and through what

An association says a route touches a construction. That leaves three questions a
reader still has to answer by opening the handler: *when* does it touch it, *how* does
it get there, and *how much* of the handler is about it. All three fall out of the
same walk, so they are derived rather than described:

- **Order.** Every access is numbered as the walk meets it, and a callee's numbers
  are shifted to sit where its caller had got to — so the sequence reads as a
  pre-order walk of the call graph, which is the order a person reading the source
  meets these constructions. A route's middleware is a separate frame from its
  handler and is shifted the same way, so the state a gate reads is numbered before
  the state it gates. A `defer` postpones the call and not its operands, so an
  argument that reads state is numbered where the statement is. The coordinator's
  widest handler reaches **57** constructions this way; the whole map derives **857**
  steps over 100 routes.
- **Indirection.** Each step carries how it is reached, from a four-word vocabulary
  the artifact publishes with its own explanations (`stepKindLegend`): `direct`
  (every hop is a statically resolved call), `interface` (some hop dispatches
  through an interface, and the walk followed the implementation `deps.preferImpl`
  names — so the running program may reach a different one), `deferred` (some hop
  runs in a `defer`, so the touch happens as that frame unwinds) and `async` (some
  hop runs in a goroutine, so the touch is concurrent with the rest of the request
  and unordered against it). A step takes the *strongest* kind on any path that
  reaches it, because the weaker claim would be the false one. Today: 410
  `interface`, 220 `direct`, 202 `deferred`, 25 `async`.
- **Which touch that was.** `kind` is the strongest touch's and everything printed
  beside it — the depth, the leading call path — is the *earliest* touch's, so the
  two can be two different touches. When they are, the earliest one's own kind is
  published as `leadKind` (188 steps) and the page says "first touch …" under a
  glyph its path does not justify: without it the artifact prints a sentence about
  unwinding beside a wire that does not unwind. Dispatch is tracked off that ladder
  as `iface`, because "which implementation runs" is a different question from
  "when does this happen" and a later `defer` must not answer it; the page states it
  only where the glyph does not already (32 steps).
- **Weight.** `touches` counts the distinct source sites that touch the node, and
  `repeats` says at least one of them is inside a loop. `wireCount` is a **floor**,
  not a census — evidence is collapsed per (node, mode, site, innermost function)
  and the earliest path kept, so two routes reaching one construction through one
  frame are one path here, and the page prints it as "at least *n* paths". Up to
  three of those paths are published per step, from the entry point to the function
  that does the touching, with the frames interned so 105 routes cost one symbol
  table, alongside up to four citations.

Two things this deliberately does **not** claim. It is a count of *sites*, not of
*executions*: nothing here runs the program, so a construction touched from one line
inside a loop is one touch that repeats, and a route's order is where a reader meets
each construction rather than a measured frequency. And a step's order is the walk's,
so two touches that a goroutine makes concurrent are ordered in the list and marked
`async` rather than reordered — the badge is the caveat.

### Table relationships

Foreign keys are read out of the same DDL the column definitions come from, in all
three forms the schema uses them in: a column-level `REFERENCES`, a table-level
`FOREIGN KEY`, and one a later `ALTER TABLE ... ADD CONSTRAINT` adds. Each carries
its columns, the table and columns it points at, its `ON DELETE`/`ON UPDATE` action
where the DDL states one (and nothing where it does not — `NO ACTION` is the
database's default, not a clause the map may invent) and its own `file:line`.

A key between two tables the graph draws becomes a **dotted arc** with the head on
the referenced table, bowed the other way from the associations so it is never
mistaken for something an endpoint does. It takes no part in the layout, in a node's
degree or in the drawn-topology fingerprint: adding a `REFERENCES` to the schema must
not move a single dot. A key the graph cannot draw — one whose child or parent is a
table nothing reachable reads, or a self-reference, which is one node rather than an
edge between two — is still listed in the *Table relationships* table and in both
tables' definitions, and a key naming a table no `CREATE TABLE` declares is drift.

Only declared keys are drawn. A `JOIN` between two tables is *not* a relationship
the schema has — most of them target `pg_catalog` relations or CTEs — so joins are
read for which tables a statement touches and never for edges between them.

## How much of it is opinion

Everything countable is derived: **105 routes, 97 nodes, 20 groups, 265
associations, 857 wiring steps, 41 table definitions (651 columns, 7 foreign keys),
1,078 citations**. The opinions are a bounded, greppable set of
overlay tables:

| Kind of opinion | Where | Size today |
|---|---|---|
| what a field/type/call *is* | `deps.fields`, `deps.types`, `deps.functions` | 150 (21 wildcards, 36 sentinels), 58, 1 |
| what a literal points at | `deps.hosts`, `deps.endpoints`, `deps.messages` | 21, 7, 25 |
| how far to look | `deps.traverse`, `deps.inherit`, `deps.packageDefault`, `deps.strict`, `deps.preferImpl`, `deps.sqlDriver`, `gateDepth` | 21, 3, 21, 1, 1, 1 (+4 assembled statements), 1 |
| how to name things | `namespaces`, `authRules`, `clusters`, `categories`, `labels` | 38, 15, 6, 6, 59 |
| prose | `routes`, `depDocs`, `categoryDocs`, `cacheSemantics` | 105, 97, 6, 4 |

A handful of opinions are structural — changing them means changing
`tools/systemmap`, not the overlay: that an entry point is an HTTP route
registered on a `net/http` mux; that middleware has the
`HandlerFunc → HandlerFunc` shape; that access mode is the R/W/RW vocabulary; that
a node's category is its id prefix; that a struct carrying a mutex, atomic,
`sync.Map` or channel is state someone must name; and that endpoints group by
namespace while dependencies group by category.

## Adding a subsystem: the prompt sidecar, as it happened

The prompt sidecar is the worked example — a separate process on the same host,
reached over a Unix socket. Making it appear took no tool changes, only overlay
entries:

```jsonc
"clusters":   { "sidecar": { "title": "Prompt sidecar", "kind": "service", ... } },
"categories": { "prompt":  { "title": "Prompt sidecar", "cluster": "sidecar", ... } },
"deps": {
  "traverse": [ "coordinator/promptcontract" ],            // follow calls into it
  "types": {
    "coordinator/promptcontract:Supervisor":  "prompt.supervisor",
    "coordinator/promptcontract:Provisioner": "prompt.artifacts",
    "coordinator/promptcontract:Client":      "@through"   // a conduit, not a surface
  },
  "fields": { "coordinator/api:Server.promptSupervisor": "prompt.supervisor", ... },
  "endpoints": { "coordinator/promptcontract": {
    "http://promptsidecar/v1/plan": "prompt.plan", ...     // its remote surfaces
  } }
},
"labels":  { "prompt.plan": "POST /v1/plan — render/tokenize/hash", ... },
"depDocs": { "prompt.plan": { "overview": "...", "concurrency": "...", ... } }
```

Forget any piece and the build tells you which, by name: an unmapped `Server`
field is drift (`api:Server` is `strict`); a node with no label is drift; a
category with no cluster fails `checkClusters`; a cluster nothing places nodes in
fails it too; a node with no `depDocs` is an undocumented boundary; an endpoint
literal that no longer appears in the client package is stale prose. That is the
extensibility guarantee: not that the map updates itself, but that it cannot
quietly fail to.

## The knowledge graph

The graph is the page: it takes the viewport by default, and **Full screen**
expands it to the whole display (the drawers and controls live inside it, so they
survive the transition). The inventory tables that explain it scroll underneath.
It draws three nested levels:

| Level | What it is | Where it comes from |
|---|---|---|
| **node** | one endpoint (square) or one dependency (circle) | derived: the route table and the reached-state analysis |
| **group** | a sub-boundary drawn directly around those nodes — one per endpoint namespace, one per dependency category | derived: `Endpoint.Group` = its namespace, `Node.Group` = its category |
| **cluster** | a process, a datastore it owns, or a third party | curated indirection: a category names its cluster, a namespace joins its service's |

So an endpoint sits inside its namespace boundary inside the coordinator's
process boundary, and a table sits inside the `pg` boundary inside PostgreSQL.
Edge colour is the derived access mode, and each edge is one `(endpoint,
dependency)` pair carrying that endpoint's own mode — not its namespace's
aggregate.

Membership is indirect on purpose. A dependency joins the cluster its category
declares; a namespace joins the cluster named after the service that serves it.
That is what lets a second extractor add its own process boundary — and
cross-boundary edges to the same `pg.*` and `ext.*` nodes — without touching the
renderer, and it is why a new namespace or category becomes a new sub-boundary
with no code change at all. The layout packs each cluster's group discs with a
hard separation pass and clamps every node to its group's disc, so containment is
geometric rather than hoped for: no boundary overlaps a sibling or encloses a node
that does not belong to it.

Clicking an endpoint opens its row in the inventory below; clicking a dependency
filters every table on the page; dragging moves a node inside its own boundary;
the cluster chips below the graph zoom to one boundary.

### Table definitions

Clicking a `pg.*` node opens that table's derived definition: every column with
its type, the rest of its declaration, and its own `file:line` link into source.
Columns an `ALTER TABLE ... ADD COLUMN` introduced are marked `migration`, because
a definition read from the `CREATE` alone describes a database that only exists on
a machine which has never been migrated — the coordinator's `users` table is six
columns wider in production than its `CREATE` says. The `CREATE`, `ALTER` and
`CREATE INDEX` statements are shown as written, each with its citation. The drawer
also lists the table's foreign keys in both directions — the ones it declares and
the ones pointing at it — each followable to the other table. **651 columns across
41 tables** are derived this way; nothing about a table's shape is curated.

## Drift is a build failure

Anything the extractor finds that the overlay does not explain — a new route
with no description, a new `Server` field with no node, a query naming an
unknown table, an outbound host with no declared boundary, a route no auth rule
matches, a node category with no cluster to draw it in — lands in `report.md`,
and `-check` exits non-zero. The reverse is checked too: overlay prose for a
route that no longer exists, a `depDocs` entry for a node that is gone, a
declared cluster nothing places nodes in, or a declared remote endpoint whose
path literal has disappeared from the client package.

Because the artifact is generated rather than stored, this is the *only* gate:
there is no such thing as a stale committed map, so the failure a PR can cause is
exactly one — source grew something the curated half does not account for.
`-check` still renders the page and the inventory, so a broken template or an
unmarshalable graph fails it too; it simply writes nothing. The same assertion runs
as a Go test (`TestCoordinatorMapHasNoDrift`), so it fails in `go test` before it
fails in the workflow.

`coordinator/api:Server` is declared `strict`, so new coordinator state gets no
package-level default: adding a field is drift until the map explains it.

Four checks exist specifically because *silence* is the failure mode a map like
this dies of:

- **Absorbed concurrent state.** A struct with a mutex, an `atomic`, a `sync.Map`
  or a channel (directly or via embedding) is state somebody must name. If an
  endpoint reaches such a struct's fields and only `deps.packageDefault` or
  `deps.inherit` explains them, the type is reported. The decision may be a node,
  `@skip`, `@sql` or `@through` — the check asks that someone looked, not that the
  answer is a node.
- **Undocumented nodes.** A node the graph draws with only a label is a boundary
  the page cannot explain, so `depDocs[<id>]` is required for every node.
- **Postgres nodes with no table definition.** A `pg.*` node whose name has no
  `CREATE TABLE` anywhere in the analyzed source is a table the map claims and the
  service never creates — a typo'd or dynamically built table name — so it is
  reported rather than drawn with an empty schema.
- **Statement text the extractor cannot read.** Every table edge comes from
  statement text, so text it cannot read contributes nothing — and leaves nothing
  for the checks above to catch: no unknown table, no unmapped field, a clean
  report and a route published as touching fewer tables than it does. Two things
  are checked, because each covers what the other cannot see. A body's calls into
  `deps.sqlDriver` are counted against the statements recoverable from it, so a
  statement that arrived from outside the body is drift. And wherever text names a
  table after an **upper-case** `FROM`, `JOIN`, `INTO` or `UPDATE`, the name has to
  be readable and the text around it has to be a statement, so `q += " UNION
  SELECT id FROM usage"` and `fmt.Sprintf("... FROM %s", t)` are drift too — those
  leave the count balanced and a table missing. Every such keyword in a literal is
  examined, not just the first, and every table it names is remembered:
  `fmt.Sprintf("... FROM models m JOIN %s u ...")` hides its second table behind a
  readable first one, and `q += " FROM models m JOIN usage u"` hides a second table
  behind a declared one. Text that *ends* at a keyword is drift as well
  (`q += " JOIN " + other`): the name it is waiting for never reaches the
  extractor. `UPDATE` is the exception, in both positions — in `FOR UPDATE`,
  `FOR NO KEY UPDATE` and `ON CONFLICT … DO UPDATE` the word introduces a lock or a
  conflict action and is never followed by a table, so those clauses are blanked
  before either reader sees them: neither `q += " FOR UPDATE"`, nor a statement whose
  literal closes on the line after `FOR UPDATE`, nor `FOR UPDATE SKIP LOCKED` (which
  once put a table called `skip` in the map) is drift. `ONLY` and `LATERAL` are
  read through, since they prefix a table name rather than replace it. Constants count
  as one statement: `"SELECT " + userColumns + " FROM users"` is folded by
  `go/types`, which is why the column-list splice the store uses throughout stays
  readable.

  A `WITH` clause shadows a table of the same name — the earnings queries define
  `WITH providers AS (…)` and then `JOIN providers p`, which is the CTE and not the
  `providers` table, and no schema check can tell them apart because `providers` is
  also real. Those names are scoped to the **string variable the query is assembled
  into** — a bare `q`, including `var q = …` and a `~string` type parameter, whose
  type set is read rather than its underlying type (which is only its constraint).
  Anything else scopes to the **expression or statement the text appears in**: two
  literals handed straight to `Exec` do not pool their CTE names, and neither do two
  queries that share only an `err`, sit in one slice literal, arrive as two
  arguments of one call, or are bound or handed back side by side (`base, tail := …`,
  `var base, tail = …`, `return base, tail` — several values in one statement are
  several queries, and there is no single variable to scope them to). Where those two
  values turn out to be halves of *one* statement, the concatenation says so and puts
  them back together: `Exec(ctx, base+tail)` settles the tail against the base's CTE
  names, because a `WITH usage AS (…)` that really does cover the read below it must not
  draw an edge to the `usage` table — invented state is worse than missing state, and
  splitting the scope was what invented it. A
  variable holding several queries in turn holds one set of names per query, and a
  fragment is settled against the set in force where the fragment was read, so
  reusing one `q` neither carries a CTE name forward to the next query nor takes it
  away from the last. The boundary is the **binding** — `q :=` or `q =` starts a
  query, `q +=` continues the one already there — and never the literal, because a
  long query spliced from several literals routinely has a middle one that parses on
  its own (`SELECT DISTINCT account_id FROM provider_earnings WHERE …` between two
  CTE definitions) and that is the same query still being assembled. This holds
  whether the pieces arrive in one assignment or several: `q := "WITH usage AS (…)"`
  then `q += "SELECT … FROM models"` then `q += "UNION SELECT id FROM usage"` is one
  query, and its own CTE still shadows the `usage` table in the tail. It is the
  binding *statement* that draws the line and not the text it carries, so `q = ""`
  starts a query as much as `q = "SELECT …"` does — deciding it from the text let
  `q = ""; q += "WITH usage AS (…) …"` land in the previous query's scope and shadow a
  real read there. The one exception is a binding that reads the local back *before the
  query has been sent*: `q = "WITH usage AS (…) …" + q` is a query assembled tail first,
  so it continues the scope rather than starting one — but the same line after an
  `Exec(ctx, q)` is a second query reusing the local, and starts one, because a query
  that has already gone to the database cannot have its tables shadowed by a `WITH`
  clause written after it. What ends the exception is *that* query going to the
  database. The call is attributed to the query it dispatched — the *statement*
  argument, not every argument, since a string handed over as a bind parameter did not
  run and marking it un-shadowed the CTE of the query that local was still holding —
  and copies are followed, so `r := q; Exec(ctx, r)` ends `q`'s query as well as `r`'s,
  and `r := q + tail` ends both of its sources. Counting the body's calls instead let an
  `Exec` belonging to some other statement cut a query that had not run, which both
  reported a legal assembly and drew the table its own CTE was shadowing. Where a copy
  lands somewhere no name can be followed — `r, n := q, 1`, `h.q = q`, `qs[0] = q`, for
  the same reason those cannot scope a query — the source is settled at the copy itself:
  the dispatch may well happen under that name and out of this walk's sight, and ending
  the exception early costs a finding with a remedy where losing it costs a table.
  A loop ends it too: the walk reads a body once where the program runs it many times,
  so a prepend inside a loop that calls the driver, onto a local bound *outside* that
  loop, is a fresh query from the second pass onward and is read as one. That covers the
  `for` clause's post statement as well as the body, since it repeats with the body — it
  is walked as part of the loop for exactly that reason. A local bound and run within one
  iteration keeps the exception.

  Four consequences worth knowing. A CTE in one query does not silence a same-named
  real table in another *as long as the two are separate Go expressions* — see the
  limits below for the shapes where they are not — and it does not draw one either:
  the tables a statement names are settled against the same scoped CTE sets before any
  edge is drawn, so a `WITH usage AS (…)` in one literal and the `JOIN usage u` in the
  next do not put an edge to the real `usage` table in the map. The unit a query is scoped
  to is small enough for that to mean something: an element of a slice literal, an
  argument to a call, and the condition of an `if` each stand for their own query, so
  the hundred statements in `migrations := []string{…}` do not pool their `WITH` names. A query assembled through anything but a bare string
  variable — `qs[0] += tail`, `s.q += tail`, `*p += tail` — is reported even though
  the SQL is legal, because `qs[0]` and `qs[1]` are one variable and `a.q` and `b.q`
  are one field: resolving through to them would let a CTE in one element or one
  receiver shadow a real table read in another, which is the silence this check
  exists to break. And two whole statements concatenated into one expression
  (`stmtA + "; " + base + " JOIN usage u"`) share a scope, so the fragment is settled
  against both. In each of those cases the remedy is the same as for a fragment whose
  `WITH` clause was assigned to a *different* variable: inline the `WITH` literal into
  the same assignment as the fragment, or declare the tables. The
  scan reads SQL rather than parsing it, so it also says
  nothing about a lower-case keyword; the tree writes SQL in upper case, and prose
  is full of "update … from …". The converse costs a false finding rather than a
  silence: an upper-case keyword in a message — `fmt.Errorf("could not UPDATE %s
  rows", t)` — reads as a spliced table name, and writing that word in lower case
  clears it.

  Case is also what tells the `FOR UPDATE` family from prose running into a statement.
  A comment whose last word is "for" sits directly in front of the line below it once
  whitespace is flattened, so `"-- rows queued for\nUPDATE " + table` would read as a
  lock and hide the spliced table; the fragment scan therefore masks the clause only
  when it is written in upper case. `Tables` cannot do that — it reads normalized
  lower-case text — so it decides on what *follows* instead, and masks the words only
  when the end of the text, a `;`/`,`/`)`, or `OF`/`NOWAIT`/`SKIP`/`SET` comes next.
  An identifier there means the word was `UPDATE` heading a statement after all;
  blanking it once dropped a real write of `usage` from the map with every count still
  balanced. A comment is on that list of things that may follow, because
  `… FOR UPDATE -- lock the row` is as legal as `… FOR UPDATE NOWAIT` and refusing to
  mask it read `--` as the spliced table. What is left over is the upper-case blind
  spot in the other direction: `-- QUEUED FOR` above an `UPDATE ` + `table` is read as
  a lock by both readers, and if the body's other literals already account for its
  driver calls the write leaves the map with nothing reported at all — not a degraded
  message, a silence. Nothing in the tree spells a comment that way.

  The remaining limits, all in shapes no store query has. Two whole statements in one
  literal — `"WITH usage AS (…) SELECT … FROM usage; SELECT … FROM usage WHERE …"` —
  are one text to `Tables`, which strips a CTE name from all of it, so the second
  statement's read of the real table is dropped. The scan reads a body in source order
  rather than following control flow, so a `goto` that jumps over the assignment a
  `WITH` clause is in settles the fragment below it against names the running program
  would not have. A query sent by handing the text to a *helper* that calls the driver
  leaves no call in this body to count, so a tail-first prepend after it still reads as
  the same query and its `WITH` clause reaches back — but that helper takes its
  statement as a parameter, which is the first rule's own failure, and the report says
  so at the helper. One local bound twice by the same multi-value statement is a fourth:
  the values are scoped to themselves and tied to the local carrying them, and with no
  generation to tell two bindings of it apart the two queries share their CTE names.
  Those are the ways a CTE is known to mute a table with nothing
  reported anywhere; what is claimed for them is that no store query has the shape, not
  that the list is closed — each was found by looking for another one, and the fixtures
  are where a new one gets pinned. The mirror-image hole is a statement whose halves are
  joined where the walk cannot see it — `strings.Join(parts, " ")`, or a helper that
  returns a base and a tail for its caller to concatenate — where the CTE is drawn as the
  real table of the same name, again with nothing reported; keep such a statement in one
  expression. And a `q` shadowed in an inner block is a different variable, so a fragment
  there is reported rather than settled against the outer query's CTE names; that costs
  a finding with a remedy, not a silence.

  A query that genuinely cannot be one expression — the earnings CTE chains, where
  a conditional `WHERE` is spliced into the middle — names its tables in
  `deps.sqlDriver.assembled` instead. That entry is held to being an explanation
  rather than a mute: the map draws its tables, the names are checked against the
  schema, every table the text names but the entry omits is still reported, an entry
  is reported once the function no longer needs it or is no longer reachable from a
  route, and an entry declaring no tables is rejected outright. What it cannot do is
  repair a mute — it stands a *finding* down and adds the tables it names, so it is no
  answer to a table that went missing with nothing reported. Those cases are the limits
  above, and they are closed in the extractor or not at all.

## Scope

The map is scoped to **entry points** — HTTP routes today. A surface only a
background worker touches — the MicroMDM command endpoints, driven by the
verification scheduler — is still declared, labeled, and checked against source,
and is drawn dashed in the graph, but has no endpoint edge; those appear in the
informational tail of `report.md`. Provider WebSocket frames and the
Swift/TypeScript services are not extracted yet; the IR
(`tools/systemmap/ir`) is service-agnostic so an extractor can be added without
changing the schema.

## Publication

`.github/workflows/pages-systemmap.yml` **builds** the map from the master commit
being published and uploads it to GitHub Pages, on pushes that touch a mapped
service, the tool, or the overlay. The page therefore describes exactly the code at
that commit; drift fails the build, so an unexplained boundary blocks the deploy
instead of appearing on the page. Enabling Pages (Settings → Pages → Source =
"GitHub Actions") is a one-time human step.

`.github/workflows/ci.yml`'s `System Map` job does the same build for pull
requests, stamping the PR head commit so every citation links to a commit a
reviewer can open, and uploads `system-map.html` as a job artifact. Reviewing a
change to the map means downloading that file and opening it — not reading a diff
of generated JSON.
