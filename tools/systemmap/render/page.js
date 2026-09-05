// Explorer behaviour. Injected verbatim into page.html; no imports, no bundler,
// no remote script — the published page is one file that opens from disk.
//
// The inventory is embedded above as JSON, so this file and any other consumer of
// inventory.json read exactly the same facts.
const DATA = JSON.parse(document.getElementById('inventory').textContent.replace(/<\\\//g, '</'));
const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };
const svg = (tag, attrs) => {
  const n = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const k in attrs || {}) n.setAttribute(k, attrs[k]);
  return n;
};
const uniq = a => [...new Set(a)].sort();
const plural = (n, one, many) => n + ' ' + (n === 1 ? one : (many || one + 's'));

// ---------------------------------------------------------------------------
// Provenance. Three ways to read the page:
//
//   all      every fact, nothing marked (the default)
//   code     only what the compiler derived, plus the curated identifiers the
//            drift gates prove against source in both directions. Every string
//            whose *text* no gate can contradict is withheld — which is exactly
//            the half a language model can write, and exactly the half that can
//            be wrong while the build stays green.
//   overlay  every fact, with each curated layer marked where it appears
//
// The point of `code` is that it is subtractive: the graph it draws — nodes,
// edges, modes, boundaries — is byte-identical to the other two views, and the
// fingerprint in the caption says so. Prose is additive enrichment on a picture
// that stands without it.
//
// `pc` marks a curated structural decision (it moves an edge, and it is gated
// both ways); `pp` marks prose (it changes nothing the graph draws, and only its
// presence is gated, never its truth); `px` marks prose no gate touches at all.
// Derived facts are deliberately left unmarked, so "plain" reads as "the compiler
// said so". `pin` is the inline variant, for marks inside a sentence or a chip.
// ---------------------------------------------------------------------------
const mark = cls => (node, inline) => { node.classList.add(cls); if (inline) node.classList.add('pin'); return node; };
const pc = mark('p-c'), pp = mark('p-p'), px = mark('p-x');

// `arrows` is 'auto' — heads wherever the picture is narrow enough to read them, which
// is syncArrows' judgement — or 'all' and 'read', the reader overruling it in either
// direction: on every wire, or only on the wire being read.
const state = { q: '', ns: '', auth: '', dep: '', mode: '', ont: '',
  view: 'all', open: null, table: null, wide: false, focus: null, arrows: 'auto' };

// showProse is the single gate every curated string passes through, so adding a
// prose field to the page cannot accidentally survive the code view.
const showProse = () => state.view !== 'code';
const say = s => (showProse() ? (s || '') : '');
// A node's label is prose; its id is the curated identity a gate binds to a
// symbol. So the code view falls back to the id rather than to nothing.
const label = id => (showProse() ? (DATA.labels && DATA.labels[id]) || id : id);
// The graph draws a dependency by the tail of its id — `flight`, not "In-flight
// request registry with cancellation and deadline tracking". A 51-character
// sentence over a 10-pixel dot is what made the picture unreadable; the full
// label is one hover away, in the panel.
const shortName = id => { const i = id.indexOf('.'); return i > 0 ? id.slice(i + 1) : id; };
const groupTitle = g => (showProse() ? g.title : (g.id || '').replace(/^(ns|cat):/, ''));
const clusterTitle = id => (showProse() ? (CLUSTERS[id] || {}).title || id : id);
const catTitle = cat => (showProse() ? (DATA.categories[cat] || {}).title || cat : cat);

// BLOB recovers the repository blob prefix from any endpoint's derived source
// link, which makes the prose citations (plain `file:line` strings) clickable
// without the overlay having to carry URLs it would then have to keep fresh.
const BLOB = (() => {
  const ep = (DATA.routes || []).find(r => r.sourceUrl && r.source);
  if (!ep) return '';
  const file = ep.source.split(':')[0];
  const i = ep.sourceUrl.indexOf(file);
  return i > 0 ? ep.sourceUrl.slice(0, i) : '';
})();
function siteURL(site) {
  if (!BLOB || !site) return '';
  const i = site.lastIndexOf(':');
  if (i <= 0) return BLOB + site;
  // A citation can name a range ("server.go:2213-2244"); the anchor takes the
  // first line.
  return BLOB + site.slice(0, i) + '#L' + site.slice(i + 1).split('-')[0];
}
// srcLink renders a citation as a link into the repository at the generated
// revision, or as plain text when no remote was configured.
function srcLink(site, url) {
  const href = url || siteURL(site);
  if (!href) return el('span', 'k mono', site);
  const a = el('a', 'mono', site);
  a.href = href;
  a.target = '_blank';
  a.rel = 'noopener';
  return a;
}

// ---------------------------------------------------------------------------
// Indices over the inventory.
// ---------------------------------------------------------------------------
// A `pg.*` node names a table the generator derived a definition for, so selecting
// one can show the columns source actually declares. The generator fails the build
// when a `pg.*` node has no CREATE TABLE, which is what makes this lookup total.
const tableFor = dep => {
  const name = dep && dep.startsWith('pg.') ? dep.slice(3) : null;
  return (name && DATA.tables && DATA.tables[name]) || null;
};
// node -> mode, merged across all associations.
const nodeMode = {};
for (const e of DATA.stateAccess) {
  const prev = nodeMode[e.dependency];
  nodeMode[e.dependency] = !prev || prev === e.mode ? e.mode : 'RW';
}
// node -> namespaces, for the boundary columns and the table drawer.
const nodeNamespaces = {};
for (const e of DATA.stateAccess) {
  (nodeNamespaces[e.dependency] = nodeNamespaces[e.dependency] || new Set()).add(e.namespace);
}
// namespace -> dependency association, which is the aggregate over every endpoint
// in that namespace.
const edgeIndex = {};
for (const e of DATA.stateAccess) edgeIndex[e.namespace + '\0' + e.dependency] = e;
const edgeOf = (ns, dep) => edgeIndex[ns + '\0' + dep] || null;
// One endpoint's own derived mode for one dependency. The route carries it, and it
// is not its namespace's: `GET /v1/keys` reads `pg.api_keys` in a namespace that
// also writes it, so the aggregate is RW and the endpoint is R. Reading the
// aggregate here published the wrong verb in the endpoint table's chips and let
// "Writes only" select endpoints that only read — while the same page drew the edge
// itself in the right colour, because the graph took the route's own mode. The
// association is the fallback for a route the extractor gave no mode.
//
// That fallback is, as of the coordinator map, dead: all 840 route-dependency pairs
// carry their own mode, so neither the aggregate branch nor the '?' is reached, and
// the DOM suite cannot cover them. It stays because `depModes` is derived per route
// and a route the extractor cannot resolve a mode for is a shape the IR permits —
// but do not read it as tested.
const epMode = (ep, dep) => (ep.depModes || {})[dep] || (edgeOf(ep.namespace, dep) || {}).mode || '?';
const nodeDoc = id => {
  const d = DATA.depDocs && DATA.depDocs[id];
  return d && typeof d === 'object' ? d : null;
};

// ---------------------------------------------------------------------------
// Wiring. The dependency list answers "what state does this endpoint touch"; the
// flow answers the question a reader actually arrives with — in what order, through
// what, and how often. It is derived, all of it: the generator walks the
// type-checked call graph in source order and records where each touch sat, how deep
// in the call stack it was, whether the hop was a direct call, an interface
// dispatch, a `defer` or a `go`, and whether it was inside a loop.
//
// It is a static order, not a trace: nothing runs the program, so `touches` counts
// distinct source sites rather than executions and `repeats` is the only claim made
// about a site running more than once.
//
// The call paths and citations are interned by the generator, so a step names its
// symbols and sites by index into the graph's own tables.
// ---------------------------------------------------------------------------
const flowIndex = {};
for (const ep of DATA.routes) {
  for (const s of ep.flow || []) flowIndex[ep.id + '\0' + s.node] = s;
}
const stepOf = (ep, dep) => flowIndex[ep.id + '\0' + dep] || null;
const symbolName = i => (DATA.symbols || [])[i] || '?';
const siteName = i => (DATA.sites || [])[i] || '';
// A wire's frames are shown by the name a reader recognises — `Server.handleProviderWS`
// rather than `api.Server.handleProviderWS`; the package is one hover away in the title.
const shortSym = s => s.split('.').slice(-2).join('.');
const wirePath = w => (w || []).map(symbolName);
// The indirection vocabulary is the generator's (`stepKindLegend` carries the
// sentences); this is only how each kind is drawn. Order is weakest to strongest,
// which is the order the generator resolves a step's kind in.
const KINDS = ['direct', 'interface', 'deferred', 'async'];
const KIND_LABEL = { direct: 'direct call', interface: 'interface dispatch',
  deferred: 'deferred call', async: 'goroutine' };
// The glyph each kind carries in text, so a wiring list reads without colour, and the
// dash the wire itself is drawn with. Both match the arrowheads in the graph.
const KIND_ARROW = { direct: '→', interface: '⇢', deferred: '↳', async: '⇉' };
const KIND_DASH = { direct: '', interface: '6 3', deferred: '2 3', async: '1 4' };
// A step with no kind is a direct call: the generator only names the indirection it
// found, and "nothing in the way" is what direct means.
const stepKind = s => (s && s.kind) || 'direct';
const kindWhy = k => (DATA.stepKindLegend || {})[k] || KIND_LABEL[k] || k;

// Foreign keys, indexed by the table they point at. The outgoing direction is on the
// table itself; this is what makes "and who points at me" answerable in the drawer.
// It is built from every declared table rather than from the drawn links, so a key
// whose child or parent has no dependency node still shows up in the definition.
// A self-reference — a parent column pointing at the same table's key — is one
// constraint, and it is already the table's own declaration. Counting it as inbound
// too would print it twice in the one drawer where both directions are shown, which
// reads as two constraints where the schema has one.
const fkInbound = {};
for (const name of Object.keys(DATA.tables || {})) {
  for (const fk of DATA.tables[name].foreignKeys || []) {
    if (fk.table === name) continue;
    (fkInbound[fk.table] = fkInbound[fk.table] || []).push({ from: name, fk });
  }
}
const colList = c => (c && c.length) ? '(' + c.join(', ') + ')' : '';
// A referential action is worth stating and only when the DDL states it: the default
// is NO ACTION, and printing that where the source says nothing would be the page
// inventing a clause.
const fkActions = fk => [fk.onDelete ? 'ON DELETE ' + fk.onDelete : '',
  fk.onUpdate ? 'ON UPDATE ' + fk.onUpdate : ''].filter(Boolean).join(' · ');
// One drawn key as a sentence, for the tooltip on its arc.
function fkSentence(fk) {
  const acts = fkActions(fk);
  return shortName(fk.from) + colList(fk.columns) + ' references ' +
    shortName(fk.to) + colList(fk.refColumns) + (acts ? ' · ' + acts : '');
}

// The ontological axis: not "is this node reached" (that is Reached, and it is
// derived) but "who named it". `sql` means source itself declares the identity in
// a CREATE TABLE; `hosts`/`endpoints`/`messages` mean a curated name bound to a
// literal the compiler found in the package; `fields`/`types`/`functions` mean a
// curated name bound to a symbol. Strongest evidence wins, because a node named
// by several tables is only as invented as its least invented binding.
const IDENT_TIER = { sql: 'source', hosts: 'literal', endpoints: 'literal',
  messages: 'literal', fields: 'symbol', types: 'symbol', functions: 'symbol' };
const IDENT_LABEL = {
  source: 'named by source',
  literal: 'curated name on a source literal',
  symbol: 'curated name on a Go symbol',
  declared: 'name with no source binding',
};
const IDENT_WHY = {
  source: 'The identity is source’s own: a CREATE TABLE in the analyzed code declares this name. ' +
    'A person chose to draw it, not to call it this.',
  literal: 'A person chose the name, and the generator binds it to a string literal it found in the ' +
    'package — a host, a remote path, or a protocol constant. If the literal disappears, the build fails.',
  symbol: 'A person chose the name, and the generator binds it to a struct field, type or function the ' +
    'type-checker resolved. Reaching it is derived; calling it this is not.',
  declared: 'No mapping table names this node, so nothing binds its identity to source.',
};
function identTier(id) {
  const by = ((DATA.nodes && DATA.nodes[id]) || {}).namedBy || [];
  if (!by.length) return 'declared';
  if (by.includes('sql')) return 'source';
  if (by.some(k => IDENT_TIER[k] === 'literal')) return 'literal';
  return 'symbol';
}
const reached = id => !!((DATA.nodes && DATA.nodes[id]) || {}).reached;
const ontOK = dep => !state.ont ||
  (state.ont === 'unreached' ? !reached(dep) : identTier(dep) === state.ont);
// A node no endpoint reaches has no endpoint-derived visibility to test, so every
// other filter can only ever exclude it — and asking for those nodes is exactly what
// the `unreached` identity is for. It selects them directly instead.
const ontPicks = id => state.ont === 'unreached' && !reached(id);

function fillSelect(id, values, text) {
  const sel = document.getElementById(id);
  for (const v of values) {
    const o = el('option', null, text ? text(v) : v);
    o.value = v;
    sel.append(o);
  }
}
fillSelect('ns', uniq(DATA.routes.map(r => r.namespace)));
fillSelect('auth', uniq(DATA.routes.map(r => r.auth)));
// The dependency select's option text carries the label, so it is rebuilt when the
// view changes rather than leaking prose into the code view.
function fillDeps() {
  const sel = document.getElementById('dep');
  sel.textContent = '';
  const all = el('option', null, 'All dependencies');
  all.value = '';
  sel.append(all);
  for (const id of Object.keys(DATA.nodes).sort()) {
    const o = el('option', null, showProse() ? id + ' — ' + label(id) : id);
    o.value = id;
    sel.append(o);
  }
  sel.value = state.dep;
}

// The wiring is searchable, because a reader who knows a function name should be able
// to ask which endpoints reach state through it. Every frame and citation is derived,
// so it is searchable in the code view too. Computed once per route and cached: the
// search runs on every keystroke over every route, and the widest flow in the
// coordinator map names 57 constructions.
function wiringHay(ep) {
  if (ep.wiringHay == null) {
    const parts = [];
    for (const s of ep.flow || []) {
      for (const w of s.wires || []) for (const i of w) parts.push(symbolName(i));
      for (const i of s.sites || []) parts.push(siteName(i));
    }
    ep.wiringHay = uniq(parts).join(' ').toLowerCase();
  }
  return ep.wiringHay;
}

function matches(ep) {
  if (state.ns && ep.namespace !== state.ns) return false;
  if (state.auth && ep.auth !== state.auth) return false;
  if (state.dep && !ep.dependencies.includes(state.dep)) return false;
  if (state.ont && !ep.dependencies.some(ontOK)) return false;
  if (state.mode) {
    const deps = state.dep ? [state.dep] : ep.dependencies;
    if (!deps.some(d => epMode(ep, d) === state.mode)) return false;
  }
  if (state.q) {
    // The code view searches only what it shows: a hit on withheld prose would
    // otherwise select rows for a reason the page refuses to display.
    const hay = [ep.method, ep.path, ep.handler, ep.namespace, ep.auth,
      say(ep.authDetail), say(ep.description), say(ep.details),
      showProse() ? (ep.callers || []).join(' ') : '', ep.middleware.join(' '),
      ep.gates.join(' '), ep.dependencies.join(' '), wiringHay(ep),
      showProse() ? ep.dependencies.map(label).join(' ') : '']
      .join(' ').toLowerCase();
    if (!state.q.split(/\s+/).every(t => hay.includes(t))) return false;
  }
  return true;
}
const filtering = () => !!(state.q || state.ns || state.auth || state.dep || state.mode || state.ont);

// ---------------------------------------------------------------------------
// Selection. A click means one thing everywhere: focus the node in the graph and
// open the matching row or drawer underneath it.
// ---------------------------------------------------------------------------
function selectDep(id) {
  state.dep = state.dep === id ? '' : id;
  document.getElementById('dep').value = state.dep;
  // Selecting a table opens its definition; deselecting closes it again, so the
  // drawer never outlives the thing it describes.
  state.table = tableFor(state.dep) ? state.dep : null;
  draw();
}
function selectNs(name) {
  state.ns = state.ns === name ? '' : name;
  document.getElementById('ns').value = state.ns;
  draw();
}
// Clicking an endpoint in the graph opens the same row the table opens, so the
// picture and the inventory are two views of one selection.
function openEndpoint(key) {
  state.open = state.open === key ? null : key;
  location.hash = encodeURIComponent(key);
  draw();
  const row = document.querySelector('tr.ep.sel');
  if (row) row.scrollIntoView({ block: 'center' });
}
// Focus is the visual half of a click: everything off the node's own edges is
// shadowed, so the picture answers "what does this actually touch" instead of
// "what exists".
function focusNode(id) {
  state.focus = state.focus === id ? null : id;
  return state.focus;
}
function clickNode(n) {
  focusNode(n.id);
  if (n.kind === 'ep') openEndpoint(n.name);
  else selectDep(n.dep);
}
function clearFocus() {
  state.focus = null;
  draw();
}

function chip(id, opts) {
  const c = el('span', 'chip' + (opts && opts.cls ? ' ' + opts.cls : ''));
  // The chip's name is the overlay's label; its mode badge is derived. In the code
  // view the name falls back to the id, which is not prose and is not marked as it.
  const name = el('span', null, label(id));
  c.append(showProse() ? pp(name, true) : name);
  const mode = (opts && opts.mode) || nodeMode[id] || '?';
  c.append(el('span', 'badge m-' + mode, mode));
  const doc = nodeDoc(id);
  c.title = id + (doc && showProse() && doc.overview ? ' — ' + doc.overview : '');
  c.onclick = ev => { ev.stopPropagation(); selectDep(id); };
  return c;
}

// ---------------------------------------------------------------------------
// Knowledge graph. Three nested levels, all derived:
//
//   cluster — a process, a datastore it owns, or a third party (DATA.clusters)
//   group   — a sub-boundary drawn inside a cluster, directly around the nodes
//             themselves: one per endpoint namespace, one per dependency
//             category (DATA.groups)
//   node    — one endpoint (square) or one dependency (circle)
//
// Every node names its group and every group names its cluster, so this file
// knows no taxonomy: a new namespace or category becomes a new sub-boundary, a
// new extracted service becomes a new cluster, and nothing here changes. The
// layout confines each node to its group's disc and each group's disc to its
// cluster's, which is what makes the drawn boundaries strictly nested — a hull
// can never overlap a sibling or swallow a foreign node. The generator fails the
// build when a service or category has no declared cluster, which keeps that
// guarantee true as services are added.
// ---------------------------------------------------------------------------
const CLUSTERS = Object.assign({}, DATA.clusters);
const UNPLACED = '_unplaced';
const serviceTitle = {};
for (const svc of DATA.services || []) serviceTitle[svc.id] = svc.title;
const epKey = ep => ep.method + ' ' + ep.path;

const GROUPS = {};
for (const id of Object.keys(DATA.groups || {}).sort()) {
  const src = DATA.groups[id];
  GROUPS[id] = { id, cluster: CLUSTERS[src.cluster] ? src.cluster : UNPLACED,
    title: src.title || id, kind: src.kind || '', color: src.color || '',
    desc: src.desc || '', nodes: [] };
}
function groupOf(id) {
  if (!GROUPS[id]) {
    GROUPS[id] = { id: id || UNPLACED, cluster: UNPLACED, title: 'Unplaced', kind: '',
      color: '', desc: 'No group declared for this node.', nodes: [] };
  }
  return GROUPS[id];
}

const GNODES = [], GLINKS = [], gById = {};
function addGNode(n) {
  n.grp = groupOf(n.group);
  n.cluster = n.grp.cluster;
  n.grp.nodes.push(n);
  gById[n.id] = n;
  GNODES.push(n);
  return n;
}
for (const ep of DATA.routes) {
  addGNode({ id: 'ep:' + ep.id, kind: 'ep', ep, ns: ep.namespace, name: epKey(ep),
    group: ep.group, links: [] });
}
for (const dep of Object.keys(DATA.nodes).sort()) {
  const node = DATA.nodes[dep];
  addGNode({ id: 'dep:' + dep, kind: 'dep', dep, name: shortName(dep), cat: node.category,
    group: node.group, links: [] });
}
// One link per (endpoint, dependency) pair, carrying that endpoint's own derived
// access mode rather than its namespace's aggregate — and its own wiring step, which
// is what lets the line say *how* the handler gets there and *when*, not only that it
// does. `mode` is what the wire does to the state, `kind` is how it reaches it, `seq`
// is where it falls in the order the request meets its constructions.
for (const ep of DATA.routes) {
  const s = gById['ep:' + ep.id];
  for (const dep of ep.dependencies) {
    const t = gById['dep:' + dep];
    if (!t) continue;
    const step = stepOf(ep, dep);
    const link = { s, t, dep, ep, mode: epMode(ep, dep), step,
      kind: stepKind(step), seq: step ? step.seq : 0 };
    GLINKS.push(link);
    s.links.push(link);
    t.links.push(link);
  }
}
// Foreign keys between two drawn tables. They are relationships among the
// dependencies themselves rather than anything an endpoint does, so they are drawn
// but deliberately take no part in the layout, in a node's degree, in its label
// priority or in the drawn-topology fingerprint: adding a REFERENCES to the schema
// must not move a single dot. A key whose child or parent has no node is not a line —
// there is nothing to draw it between — and still appears in the table's definition.
// Nor is a self-reference: it is one node rather than an edge between two, the generator
// declines to publish it as a link, and an arc from a dot to itself would be a degenerate
// curve if one ever arrived — the table's own drawer states it instead. Two *different*
// keys between the same pair of tables
// are two edges, and drawArc bows from the endpoints alone, so they would land on top
// of each other with the second one's tooltip unreachable; `spread` fans them apart.
const FKLINKS = [];
const fkPairs = {};
for (const fk of DATA.tableLinks || []) {
  const s = gById['dep:' + fk.from], t = gById['dep:' + fk.to];
  if (!s || !t || s === t) continue;
  const pair = [fk.from, fk.to].sort().join('\u0000');
  fkPairs[pair] = (fkPairs[pair] || 0) + 1;
  FKLINKS.push({ s, t, fk, spread: fkPairs[pair] });
}
if (GNODES.some(n => n.cluster === UNPLACED)) {
  CLUSTERS[UNPLACED] = { title: 'Unplaced', kind: 'external', color: '#8b98a5',
    desc: 'No cluster declared for this node’s category.' };
}
for (const n of GNODES) {
  n.r = n.kind === 'ep'
    ? Math.min(11, 4 + 1.5 * Math.sqrt(n.links.length))
    : Math.min(15, 5 + 2.1 * Math.sqrt(n.links.length));
}
// Label priority order, computed once: the busiest dependencies name the picture,
// and endpoints only earn a label when zoomed in or picked out.
const byDegree = kind => GNODES.filter(n => n.kind === kind)
  .slice().sort((a, b) => b.links.length - a.links.length || a.name.localeCompare(b.name));
const depsByDegree = byDegree('dep'), epsByDegree = byDegree('ep');

// The drawn topology, fingerprinted: every node's identity and the two boundaries
// it sits inside, and every association with its access mode — and no prose
// whatsoever. It is read back out of the rendered SVG on every redraw, not from
// the data, so switching to the code view and watching this number hold still is a
// real check that withholding the curated prose did not move an edge.
function fnv(s) {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return ('0000000' + h.toString(16)).slice(-8);
}
const nodeTopo = n => n.id + '@' + n.group + '@' + n.cluster;
const linkTopo = l => l.s.id + '>' + l.t.id + ':' + l.mode;
function topoFingerprint() {
  const read = sel => [...gsvg.querySelectorAll(sel)].map(e => e.getAttribute('data-topo')).sort().join(';');
  return fnv(read('#gnodes > g[data-topo]') + '|' + read('#glinks > path[data-topo]'));
}

// Group discs. A group's disc is sized from the area its own nodes need, then
// the groups of one cluster are packed against each other: groups that share
// associations pull together, and a hard separation pass runs last so two discs
// can never overlap. A cluster's disc is then whatever circle contains its packed
// groups — which is what makes "node inside group inside cluster" a geometric
// fact rather than a hope.
const members = {};
for (const n of GNODES) (members[n.cluster] = members[n.cluster] || []).push(n);
const clusterIds = Object.keys(members).sort();
const groupIds = Object.keys(GROUPS).sort().filter(id => GROUPS[id].nodes.length);
const groupsIn = {};
for (const id of groupIds) {
  const g = GROUPS[id];
  (groupsIn[g.cluster] = groupsIn[g.cluster] || []).push(id);
  g.r = Math.max(34, Math.sqrt(g.nodes.reduce((s, n) => s + (n.r + 9) * (n.r + 9), 0) / 0.55));
}
const gweight = {};
const gkey = (a, b) => (a < b ? a + '\0' + b : b + '\0' + a);
for (const l of GLINKS) {
  if (l.s.group === l.t.group) continue;
  const k = gkey(l.s.group, l.t.group);
  gweight[k] = (gweight[k] || 0) + 1;
}
const groupWeight = (a, b) => gweight[gkey(a, b)] || 0;
const groupRadius = id => GROUPS[id].r;

function packDiscs(ids, radiusOf, weightBetween) {
  const pos = {};
  if (!ids.length) return pos;
  if (ids.length === 1) { pos[ids[0]] = { x: 0, y: 0 }; return pos; }
  let circumference = 0;
  for (const id of ids) circumference += 2 * radiusOf(id) + 46;
  const R = circumference / (2 * Math.PI);
  ids.forEach((id, i) => {
    const a = (i * 2 * Math.PI) / ids.length - Math.PI / 2;
    pos[id] = { x: Math.cos(a) * R, y: Math.sin(a) * R };
  });
  const gap = 22;
  const separate = () => {
    let worst = 0;
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const a = pos[ids[i]], b = pos[ids[j]];
        let dx = b.x - a.x, dy = b.y - a.y, d = Math.hypot(dx, dy);
        if (d < 1e-6) { dx = 0.01 * (j - i + 1); dy = 0.01; d = Math.hypot(dx, dy); }
        const need = radiusOf(ids[i]) + radiusOf(ids[j]) + gap;
        if (d >= need) continue;
        worst = Math.max(worst, need - d);
        const push = (need - d) / 2;
        a.x -= (dx / d) * push; a.y -= (dy / d) * push;
        b.x += (dx / d) * push; b.y += (dy / d) * push;
      }
    }
    return worst;
  };
  for (let step = 0, steps = 420; step < steps; step++) {
    const alpha = 1 - step / steps;
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        const w = weightBetween(ids[i], ids[j]);
        if (!w) continue;
        const a = pos[ids[i]], b = pos[ids[j]];
        const dx = b.x - a.x, dy = b.y - a.y;
        const k = Math.min(0.05, 0.008 * Math.sqrt(w)) * alpha;
        a.x += dx * k; a.y += dy * k;
        b.x -= dx * k; b.y -= dy * k;
      }
    }
    for (const id of ids) { pos[id].x *= 1 - 0.012 * alpha; pos[id].y *= 1 - 0.012 * alpha; }
    separate();
  }
  for (let pass = 0; pass < 80 && separate() > 0.4; pass++);
  let cx = 0, cy = 0;
  for (const id of ids) { cx += pos[id].x; cy += pos[id].y; }
  cx /= ids.length; cy /= ids.length;
  for (const id of ids) { pos[id].x -= cx; pos[id].y -= cy; }
  return pos;
}

const grel = {};
const radius = {};
for (const id of clusterIds) {
  const ids = groupsIn[id] || [];
  const pos = packDiscs(ids, groupRadius, groupWeight);
  let span = 0;
  for (const gid of ids) {
    grel[gid] = pos[gid];
    span = Math.max(span, Math.hypot(pos[gid].x, pos[gid].y) + GROUPS[gid].r);
  }
  radius[id] = span + (ids.length > 1 ? 34 : 18);
}

// Cluster discs: the extracted services form the inner ring (a single service
// sits at the origin), everything they talk to forms the outer ring.
const extracted = new Set((DATA.services || []).map(s => s.id));
const inner = clusterIds.filter(id => extracted.has(id));
const outer = clusterIds.filter(id => !extracted.has(id));
const center = {};
function ring(ids, minRadius, phase) {
  let circumference = 0;
  for (const id of ids) circumference += 2 * radius[id] + 120;
  const R = Math.max(minRadius, circumference / (2 * Math.PI));
  ids.forEach((id, i) => {
    const a = phase + (i * 2 * Math.PI) / ids.length;
    center[id] = { x: Math.cos(a) * R, y: Math.sin(a) * R };
  });
  return R;
}
let innerR = 0;
if (inner.length === 1) center[inner[0]] = { x: 0, y: 0 };
else if (inner.length) innerR = ring(inner, 0, -Math.PI / 2);
const innerSpan = innerR + Math.max(0, ...inner.map(id => radius[id]));
if (outer.length) ring(outer, innerSpan + Math.max(0, ...outer.map(id => radius[id])) + 130, -Math.PI / 2);

for (const gid of groupIds) {
  const g = GROUPS[gid];
  g.cx = center[g.cluster].x + grel[gid].x;
  g.cy = center[g.cluster].y + grel[gid].y;
}

// Deterministic seeding: a golden-angle spiral spreads a group's members evenly
// before any force is applied, so the layout is identical on every load.
for (const gid of groupIds) {
  const g = GROUPS[gid];
  g.nodes.forEach((n, i) => {
    const t = (i + 0.5) / g.nodes.length;
    const a = i * 2.39996323;
    n.x = g.cx + Math.cos(a) * g.r * 0.78 * Math.sqrt(t);
    n.y = g.cy + Math.sin(a) * g.r * 0.78 * Math.sqrt(t);
  });
}
for (let step = 0, steps = 320; step < steps; step++) {
  const alpha = 1 - step / steps;
  // Repulsion is scoped to a group: nodes only have to avoid the siblings they
  // are drawn beside, and the group disc keeps them away from everyone else.
  for (const gid of groupIds) {
    const m = GROUPS[gid].nodes;
    for (let i = 0; i < m.length; i++) {
      for (let j = i + 1; j < m.length; j++) {
        const a = m[i], b = m[j];
        let dx = a.x - b.x, dy = a.y - b.y;
        let d2 = dx * dx + dy * dy;
        if (d2 < 1e-6) { dx = (i - j) * 0.01 + 0.01; dy = 0.01; d2 = dx * dx + dy * dy; }
        const d = Math.sqrt(d2);
        const push = Math.min(5, (900 + 30 * (a.r + b.r)) / d2) * alpha;
        a.x += (dx / d) * push; a.y += (dy / d) * push;
        b.x -= (dx / d) * push; b.y -= (dy / d) * push;
      }
    }
  }
  // Associations pull a dependency toward the endpoints that reach it, which is
  // what turns each group's contents toward its neighbours instead of scattering.
  for (const l of GLINKS) {
    const dx = l.t.x - l.s.x, dy = l.t.y - l.s.y;
    const ks = (0.02 * alpha) / Math.sqrt(l.s.links.length);
    const kt = (0.02 * alpha) / Math.sqrt(l.t.links.length);
    l.s.x += dx * ks; l.s.y += dy * ks;
    l.t.x -= dx * kt; l.t.y -= dy * kt;
  }
  for (const n of GNODES) {
    n.x += (n.grp.cx - n.x) * 0.03 * alpha;
    n.y += (n.grp.cy - n.y) * 0.03 * alpha;
    clamp(n);
  }
}
// Clamping to the group disc is the containment proof: the group disc lies inside
// its cluster's by construction, so a node that stays in one stays in both.
function clamp(n) {
  const g = n.grp, lim = Math.max(0, g.r - n.r - 3);
  const dx = n.x - g.cx, dy = n.y - g.cy;
  const d = Math.hypot(dx, dy);
  if (d > lim && d > 0) { n.x = g.cx + (dx / d) * lim; n.y = g.cy + (dy / d) * lim; }
}

// Convex hull (monotone chain) over a ring of sample points per node, then
// midpoint-quadratic smoothing: one code path for a cluster of 40 nodes and for
// a cluster of one.
function convexHull(pts) {
  const p = pts.slice().sort((a, b) => a.x - b.x || a.y - b.y);
  const cross = (o, a, b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  const half = list => {
    const out = [];
    for (const q of list) {
      while (out.length >= 2 && cross(out[out.length - 2], out[out.length - 1], q) <= 0) out.pop();
      out.push(q);
    }
    return out;
  };
  const lower = half(p), upper = half(p.slice().reverse());
  return lower.slice(0, -1).concat(upper.slice(0, -1));
}
function hullPath(nodes, pad) {
  const pts = [];
  for (const n of nodes) {
    for (let i = 0; i < 12; i++) {
      const a = (i * Math.PI) / 6;
      pts.push({ x: n.x + Math.cos(a) * (n.r + pad), y: n.y + Math.sin(a) * (n.r + pad) });
    }
  }
  const h = convexHull(pts);
  if (h.length < 3) return '';
  const p = (q) => q.x.toFixed(1) + ' ' + q.y.toFixed(1);
  const mid = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
  let d = 'M' + p(mid(h[h.length - 1], h[0]));
  for (let i = 0; i < h.length; i++) {
    const cur = h[i], next = h[(i + 1) % h.length];
    d += 'Q' + p(cur) + ' ' + p(mid(cur, next));
  }
  return d + 'Z';
}

const gsvg = document.getElementById('gsvg');
const scene = document.getElementById('scene');
const modeColor = { R: 'var(--r)', W: 'var(--w)', RW: 'var(--rw)' };

// Arrowheads. Four shapes — one per indirection kind — in every access-mode colour,
// so one head states both facts a wire carries: its colour is what the endpoint does
// to the state, its shape is how it reaches it.
//
// The two vocabularies below are this page's copy of the generator's, and a head is
// generated per pair rather than written out — so an indirection kind the generator adds
// and the page has not learned is drawn with no head at all, which `wiring.test.mjs`
// fails on. A new access *mode* is the weaker case: it falls back to the grey `-x` head,
// which is legible and wrong, so the mode list is the one to update first.
const MARKER_PATH = {
  direct: 'M0 0 L8 3 L0 6 Z',               // a filled head: nothing in the way
  interface: 'M0.7 0.7 L7.3 3 L0.7 5.3 Z',  // hollow: the callee is chosen at runtime
  deferred: 'M0 3 L4 0.5 L8 3 L4 5.5 Z',    // a diamond: it happens on the way out
  async: 'M0 0 L8 3 L0 6',                  // an open barb: it is off the request's line
};
const MODE_KEYS = { R: 'R', W: 'W', RW: 'RW', '?': 'x' };
// The head's own box, with a unit of slack around it. Every path above is drawn inside
// `0 0 8 6` with a 1px outline, and an outline straddles its path — so a viewBox tight
// to the ink clips the async barb's tips and the deferred diamond's vertices by half a
// stroke. One unit of margin on each side costs nothing but has to be paid for in the
// box, or `meet` scaling shrinks the ink instead: the sizes below are the padded box, so
// the ink inside them is 9 × 6.75 screen pixels.
const ARROW_VIEW = '-1 -1 10 8';
// How big a head is on screen, and how big the foreign-key head is — a relationship
// among the tables is a quieter fact than something an endpoint does, so it is drawn
// slightly smaller.
const ARROW_PX = { w: 11.25, h: 9 };
const FK_ARROW_PX = { w: 9.4, h: 7.5 };
// A head comes in two families, because it is printed in two coordinate systems. The
// `-fx` family is for the legend below the graph, whose sample wires are ordinary
// unscaled SVG; the unsuffixed family is for the wires themselves, which live inside
// the scaled scene — so its boxes are resized per zoom by sizeMarkers and the legend's
// are not. Sharing one family is what a reader would expect and is exactly wrong: the
// zoom would resize the key.
const markerID = (kind, mode, fixed) =>
  'a-' + kind + '-' + (MODE_KEYS[mode] || 'x') + (fixed ? '-fx' : '');
// The colour the indirection key draws its sample heads in. The key is about shape, so
// it needs one colour rather than all of them, and read+write is the one that names both.
const LEGEND_MODE = 'RW';
// The scene's heads, so sizeMarkers can find them without a selector.
const SCENE_MARKERS = [];
function buildMarkers() {
  const defs = document.getElementById('gdefs');
  const head = (id, kind, color, box) => {
    // Two of the four heads are hollow. An interface head is filled with the page
    // background rather than left transparent, or the wire under it shows through
    // and reads as a solid head; a goroutine's chevron has no interior to fill.
    const fill = kind === 'interface' ? 'var(--bg)' : kind === 'async' ? 'none' : color;
    // `markerUnits: userSpaceOnUse` is the load-bearing attribute of the whole family:
    // the default, `strokeWidth`, multiplies the box by the referencing wire's stroke
    // width, which the hover and focus states change — the box below is a screen-pixel
    // size divided by the zoom, and it means nothing if a class can scale it. `orient:
    // auto` rather than `auto-start-reverse` because only `marker-end` is ever set, and
    // an engine that does not know the longer keyword points every head due east.
    const m = svg('marker', { id: id, viewBox: ARROW_VIEW, refX: 7.4, refY: 3,
      markerWidth: box.w, markerHeight: box.h,
      orient: 'auto', markerUnits: 'userSpaceOnUse' });
    m.append(svg('path', { d: MARKER_PATH[kind], fill: fill, stroke: color, 'stroke-width': 1 }));
    defs.append(m);
    return m;
  };
  for (const kind of KINDS) {
    for (const mode of Object.keys(MODE_KEYS)) {
      const color = modeColor[mode] || 'var(--dim)';
      SCENE_MARKERS.push({ node: head(markerID(kind, mode), kind, color, ARROW_PX), px: ARROW_PX });
    }
    // One fixed-size twin per kind, and only in the key's own colour: the legend draws a
    // sample wire per indirection kind to say what the shape means, and says nothing
    // about access mode there. A full mode × kind fixed family would be twelve
    // definitions nothing references.
    head(markerID(kind, LEGEND_MODE, true), kind, modeColor[LEGEND_MODE], ARROW_PX);
  }
  // The foreign-key head belongs to the relationship, not to an access mode: a key is
  // not something anybody read or wrote. It is only ever drawn in the scene, so it has
  // no fixed-size twin — and it is drawn with the plain head rather than the diamond,
  // because the diamond is a shape the indirection key teaches (`defer`) and a grey
  // diamond on a dotted arc would read as a deferred call the key cannot explain. The
  // plain head is taught too, but a foreign key's arc is dotted and colourless where
  // every access is solid or dashed and carries a mode colour, so the wire disambiguates
  // its own head.
  const fk = head('a-fk', 'direct', 'var(--dim)', FK_ARROW_PX);
  SCENE_MARKERS.push({ node: fk, px: FK_ARROW_PX });
  sizeMarkers();
}

// sizeMarkers keeps a head one size on screen at every zoom.
//
// A marker on a path inside the scaled scene is measured in that path's own user space,
// so `markerWidth: 8` is eight *scene* units — three screen pixels at the zoom that
// fits the whole coordinator map, with a half-pixel outline. The heads were being drawn
// and could not be seen. Dividing the box by the scale is the same decision the label
// layer makes by living outside the scene: an annotation is read at the reader's scale,
// not the picture's.
let markerK = 0;
function sizeMarkers() {
  // Writing a marker attribute invalidates every instance of it, which at 34 definitions
  // is real work on a path that runs on every wheel tick. A scale change under a percent
  // moves a head by a tenth of a pixel, so it is not worth a relayout: the guard is a
  // ratio rather than an equality so a smooth zoom coalesces into a few writes.
  if (markerK && Math.abs(view.k / markerK - 1) < 0.01) return;
  markerK = view.k;
  for (const m of SCENE_MARKERS) {
    m.node.setAttribute('markerWidth', (m.px.w / view.k).toFixed(2));
    m.node.setAttribute('markerHeight', (m.px.h / view.k).toFixed(2));
  }
}

// How many live wires the picture can carry a head on each and still be a picture, and
// the zoom past which the count stops mattering because most of them are off-screen.
//
// The whole coordinator map fits at k ≈ 0.43 and has 857 wires, so the unfiltered view is
// deliberately on the wrong side of both numbers, and it is worth saying how far: at that
// scale 846 of the 857 heads would have another head within their own width, 88 on
// average, and one 9-pixel square would hold 107 of them. Moving them to the wires'
// midpoints — five times less crowded — still leaves 844 of them touching. There is no
// arrangement in which a picture of this system points every wire legibly, so the reader
// has to narrow it first, and the toolbar says so rather than leaving them to wonder.
//
// The zoom threshold is just over twice the fit scale — the point where a reader has
// stopped looking at the system and started reading a corner of it — so heads arrive
// without being asked for, well before anybody traces an individual line.
const ARROW_ALL_MAX = 140;
const ARROW_ALL_ZOOM = 0.9;

// The toolbar control is also the answer to "why can I see no arrows": rather than leaving
// a reader to discover that 857 wires is over a threshold they cannot see, the button says
// what the rule decided and what would change it. Written on every styleGraph, because the
// count it reports moves with every filter.
function arrowsNote(live, all) {
  const btn = document.getElementById('garrows');
  if (!btn) return;
  btn.textContent = '↦ ' + state.arrows;
  const why = all
    ? live + ' wires shown, each pointed by how it gets there'
    : live + ' wires shown — too many to point at once (over ' + ARROW_ALL_MAX + '), so ' +
      'heads are drawn where a line is being read: hover a dot, click one, filter, or zoom in';
  btn.title = 'Arrowheads: ' + state.arrows + '. ' + why +
    '. Click to cycle auto → all → read.';
}

// syncArrows decides which wires carry an arrowhead.
//
// Every wire has a direction and a kind of indirection, and both are worth stating — but
// 857 heads over the whole coordinator map is a smear rather than an answer, so the
// picture earns them by being narrow enough to read: a filter, a focus, or a zoom close
// enough that most wires are off the frame. Below that, a head is drawn where a line is
// actually being read — lit by a hover, or on the focused node's own edges.
//
// `state.arrows` is the reader overriding that judgement from the toolbar, in either
// direction, which is why the rule is here and not spread through styleGraph: one place
// decides, and the zoom, the filters and the button all arrive at it.
function syncArrows() {
  let live = 0;
  for (const l of GLINKS) if (l.live) live++;
  const all = state.arrows === 'all' ||
    (state.arrows === 'auto' && (live <= ARROW_ALL_MAX || view.k >= ARROW_ALL_ZOOM));
  arrowsNote(live, all);
  for (const l of GLINKS) {
    // A shaded wire never carries a head, whatever the rule says: a focus is a claim
    // that everything off this node's edges is not the answer, and eight hundred heads
    // over the shadow is the noise the focus was asked to remove. Which is also why a
    // focused node's own edges are pointed whether or not the budget would allow it —
    // the picture has already been narrowed to them.
    // The attribute is only touched when the answer changes: this runs on every hover.
    const on = !!l.live && !l.shaded && (all || l.lit || L.focused);
    if (on === l.arrow) continue;
    l.arrow = on;
    if (on) l.node.setAttribute('marker-end', 'url(#' + markerID(l.kind, l.mode) + ')');
    else l.node.removeAttribute('marker-end');
  }
}

let hover = null;
const view = { k: 1, x: 0, y: 0 };
const hullPaths = {};
const groupPaths = {};
const hullLabels = {};
const hullSubs = {};
const groupLabels = {};

function buildGraph() {
  const hulls = document.getElementById('hulls');
  const links = document.getElementById('glinks');
  const nodes = document.getElementById('gnodes');
  const labels = document.getElementById('glabels');
  for (const id of clusterIds) {
    const meta = CLUSTERS[id];
    const g = svg('g', { 'data-cluster': id });
    const path = svg('path', { class: 'hull k-' + (meta.kind || 'external'),
      fill: meta.color, 'fill-opacity': 0.07, stroke: meta.color, 'stroke-opacity': 0.55 });
    g.append(path);
    hulls.append(g);
    hullPaths[id] = path;
    // Boundary names live in the unscaled label layer with everything else, so
    // they keep one size at any zoom and take part in the same collision pass.
    const t = svg('text', { class: 'hull-label', 'text-anchor': 'middle', fill: meta.color });
    const sub = svg('text', { class: 'hull-sub', 'text-anchor': 'middle' });
    labels.append(t, sub);
    hullLabels[id] = t;
    hullSubs[id] = sub;
  }
  // Sub-boundaries, drawn around the nodes themselves. A cluster with a single
  // group would draw the same outline twice, so it is skipped.
  for (const gid of groupIds) {
    const grp = GROUPS[gid];
    if ((groupsIn[grp.cluster] || []).length < 2) continue;
    const color = grp.color || CLUSTERS[grp.cluster].color;
    const g = svg('g', { 'data-group': gid });
    const path = svg('path', { class: 'hull-g', fill: color, stroke: color });
    g.append(path);
    hulls.append(g);
    groupPaths[gid] = path;
    const t = svg('text', { class: 'hull-glabel', 'text-anchor': 'middle', fill: color });
    labels.append(t);
    groupLabels[gid] = t;
  }
  // A foreign key is drawn under the associations, dotted and in no mode's colour,
  // with the head on the referenced table: the arrow points the way the reference
  // does, from the row that carries the column to the row it must exist in.
  const fks = document.getElementById('gfks');
  for (const l of FKLINKS) {
    l.node = svg('path', { class: 'fklink', 'marker-end': 'url(#a-fk)' });
    const tip = svg('title');
    tip.textContent = fkSentence(l.fk);
    l.node.append(tip);
    fks.append(l.node);
  }
  for (const l of GLINKS) {
    // The dash is the indirection kind and it is drawn always, not only under a
    // hover: that a touch happens in a goroutine is a property of the wire, and a
    // reader should not have to click to find it out.
    l.node = svg('path', { class: 'glink k-' + l.kind, stroke: modeColor[l.mode] || 'var(--dim)',
      'data-topo': linkTopo(l) });
    if (KIND_DASH[l.kind]) l.node.setAttribute('stroke-dasharray', KIND_DASH[l.kind]);
    links.append(l.node);
  }
  for (const n of GNODES) {
    const g = svg('g', { class: 'gnode ' + n.kind, 'data-topo': nodeTopo(n) });
    const color = n.kind === 'ep'
      ? (CLUSTERS[n.cluster].color || 'var(--accent)')
      : ((DATA.categories[n.cat] || {}).color || 'var(--dim)');
    if (n.kind === 'ep') {
      n.shape = svg('rect', { width: n.r * 2, height: n.r * 2, rx: 3, fill: color });
    } else {
      n.shape = svg('circle', { r: n.r, fill: color });
    }
    g.append(n.shape);
    // The tooltip carries the full curated name the dot itself no longer shows.
    n.tip = svg('title');
    g.append(n.tip);
    g.addEventListener('pointerenter', () => { hover = n; styleGraph(); });
    g.addEventListener('pointerleave', () => { if (hover === n) { hover = null; styleGraph(); } });
    nodes.append(g);
    n.g = g;
    n.text = svg('text', { class: 'glabel' + (n.kind === 'ep' ? ' ep' : ''), 'text-anchor': 'middle' });
    labels.append(n.text);
    dragNode(n);
  }
  positionGraph();
  fit();
  const key = document.getElementById('gkey');
  for (const id of clusterIds) {
    const meta = CLUSTERS[id];
    const c = el('span', 'ck');
    const sw = el('span', 'sw');
    sw.style.background = meta.color;
    c.append(sw);
    c.append(el('span', null, meta.title));
    c.append(el('small', null, meta.kind));
    c.title = meta.desc || '';
    c.onclick = () => focusCluster(id);
    key.append(c);
  }
}

// drawArc draws one line between two nodes and records where its own midpoint fell.
//
// Bowing each line away from the straight one is what keeps parallel edges between
// the same two discs distinguishable. Two things then follow from the curve rather
// than from the straight line between the dots: the arrowhead's direction, which is
// the tangent at the end and is why a head can be trusted to point along the wire it
// belongs to; and the sequence badge's position, which is the quadratic's own
// midpoint — a badge on the chord would sit off its wire and, on a crowded map, on
// somebody else's.
//
// The line also stops short of the target so the head lands on the dot's edge rather
// than under it, but only when there is room: on two nodes drawn almost on top of
// each other, pulling the end back further than the gap would reverse the line and
// point the arrow the wrong way.
function drawArc(l, bend, maxBow, gap) {
  const mx = (l.s.x + l.t.x) / 2, my = (l.s.y + l.t.y) / 2;
  const dx = l.t.x - l.s.x, dy = l.t.y - l.s.y;
  const d = Math.hypot(dx, dy) || 1;
  const bow = Math.max(-maxBow, Math.min(maxBow, d * bend));
  const cx = mx - (dy / d) * bow, cy = my + (dx / d) * bow;
  let ex = l.t.x, ey = l.t.y;
  const back = l.t.r + gap;
  const tx = ex - cx, ty = ey - cy, td = Math.hypot(tx, ty);
  if (td > back + 4) { ex -= (tx / td) * back; ey -= (ty / td) * back; }
  l.node.setAttribute('d', 'M' + l.s.x.toFixed(1) + ' ' + l.s.y.toFixed(1) +
    'Q' + cx.toFixed(1) + ' ' + cy.toFixed(1) + ' ' + ex.toFixed(1) + ' ' + ey.toFixed(1));
  l.cx = 0.25 * l.s.x + 0.5 * cx + 0.25 * ex;
  l.cy = 0.25 * l.s.y + 0.5 * cy + 0.25 * ey;
}

function positionGraph() {
  for (const id of clusterIds) hullPaths[id].setAttribute('d', hullPath(members[id], 26));
  for (const gid in groupPaths) groupPaths[gid].setAttribute('d', hullPath(GROUPS[gid].nodes, 13));
  for (const l of GLINKS) drawArc(l, 0.12, 60, 1);
  // Foreign keys bow the other way, so a key between two tables an endpoint also
  // reaches is never mistaken for one of that endpoint's own wires.
  for (const l of FKLINKS) drawArc(l, -0.16 * l.spread, 40 * l.spread, 1);
  for (const n of GNODES) {
    if (n.kind === 'ep') {
      n.shape.setAttribute('x', (n.x - n.r).toFixed(1));
      n.shape.setAttribute('y', (n.y - n.r).toFixed(1));
    } else {
      n.shape.setAttribute('cx', n.x.toFixed(1));
      n.shape.setAttribute('cy', n.y.toFixed(1));
    }
  }
  placeLabels();
}

// ---------------------------------------------------------------------------
// Labels. They are the one thing that must not scale with the scene: text inside
// a scaled group collides at every zoom identically, which is why zooming out used
// to bury the picture under its own names. So the label layer is unscaled, every
// label is positioned per frame in screen space, and a greedy pass in priority
// order drops the ones that would overlap something already placed.
//
// Priority: whatever is focused or selected, then its neighbourhood, then the
// busiest dependencies, then endpoints. Boundary names are placed first — a node
// label never sits on top of the name of the ring it is inside.
// ---------------------------------------------------------------------------
const LABEL_BUDGET = 44;
// A group ring narrower than this many screen pixels has no room for its own name.
const GROUP_LABEL_MIN = 46;
// 101 endpoint labels at once is noise; an endpoint earns one at this scale, or when
// a focus or a hover has already narrowed the picture to a handful.
const EP_LABEL_ZOOM = 1.5;
// The glyph size each kind of label is drawn at, and the height its box reserves.
const LABEL_PX = { ep: 10, dep: 11 };
const GROUP_LABEL_PX = 10, GROUP_LABEL_H = 11;
const CLUSTER_LABEL_PX = 12.5, CLUSTER_SUB_PX = 10;
// The ladder a cluster name climbs when its ideal position is taken: the ideal
// position first, then up — above the ring is where a boundary name belongs — then
// down, each rung one box clear of the last, and the ideal position again as the last
// resort, because an anchor that is missing is worse than one that is crowded.
//
// The rungs are screen pixels and are not scaled by the zoom, deliberately: they are
// sized against the label boxes they have to clear, which are also unscaled. The cost
// is that when the map is zoomed far out a high rung can carry a name most of a ring
// away from the ring itself, or off the top of the frame — which is why the on-screen
// claim in the DOM suite exempts cluster names, and why the last rung comes home.
const CLUSTER_RUNGS = [0, -29, 29, -58, 58, -87, 87, -116, 116, 0];
// How many dependencies a pinned detail panel lists before it summarises the rest.
const PANEL_CAP = 20;
// Widths are estimated, not measured: getBBox() on two hundred texts every frame
// is what makes panning stutter, and an estimate 6% generous only ever drops a
// label that would have just fit.
const textW = (s, px) => s.length * px * 0.56 + 8;
// The two rectangles the label pass reserves, as functions of where a label ended
// up. They are declared here rather than inside placeLabels so that the geometry a
// test scores collisions with is the page's own and not a copy of it.
const labelBox = (cx, cy, w, h) => ({ x0: cx - w / 2, x1: cx + w / 2, y0: cy - h, y1: cy + 3 });
// A cluster's title and its subtitle are one box; the subtitle rides 13px under.
const clusterBox = (cx, cy, w) => ({ x0: cx - w / 2, x1: cx + w / 2, y0: cy - 12, y1: cy + 16 });
const sx = x => x * view.k + view.x;
const sy = y => y * view.k + view.y;
// L is what styleGraph decided; placeLabels only lays it out, so a node drag can
// reposition labels without recomputing the filter.
const L = { shown: new Set(), near: new Set(), sel: new Set(), focus: new Set(), focused: false };

// Sequence badges: a focused endpoint numbers its own wires, which is the whole
// answer to "in what order does this endpoint meet its constructions". The texts are
// pooled and reused between focuses — the widest flow in the coordinator map reaches
// 57 constructions — so focusing a node changes what is positioned and what is
// hidden, never the page's DOM structure. They are laid out by the same collision
// pass as every other label, and scored by the DOM suite against the wire midpoint
// they belong to.
const SEQ_PX = 9.5;
const SEQ_POOL = [];
// One leader per badge, in a layer of its own under the numbers: a badge the collision
// pass had to move off its own wire is joined back to it by a tick, which is what makes
// the ladder honest. The line is created with the badge and shares its lifetime, so a
// slot is never a number without its tick or a tick without its number.
const SEQ_LEADS = [];
function seqPool(want) {
  const labels = document.getElementById('glabels');
  const leads = document.getElementById('gseqleads');
  while (SEQ_POOL.length < want) {
    const t = svg('text', { class: 'gseq', 'text-anchor': 'middle' });
    t.style.display = 'none';
    labels.append(t);
    SEQ_POOL.push(t);
    const lead = svg('line', { class: 'gseqlead' });
    lead.style.display = 'none';
    leads.append(lead);
    SEQ_LEADS.push(lead);
  }
  return SEQ_POOL;
}
// Which wires carry a number right now: the focused endpoint's own, to state it is
// shown, in the order the request meets them. A hover is not enough — it changes as
// fast as the pointer moves, and a number is something a reader stops to read.
function seqLinks() {
  const n = state.focus ? gById[state.focus] : null;
  if (!n || n.kind !== 'ep') return [];
  return n.links.filter(l => l.seq && L.shown.has(l.t.id) && L.shown.has(l.s.id))
    .sort((a, b) => a.seq - b.seq);
}

// Where a badge may sit: on its wire's own midpoint, then slid along the wire, then
// stepped off it along the normal — in screen pixels, like every other label position, so
// a number keeps its distance from its wire at every zoom.
//
// One position per badge is what an endpoint with 57 wires cannot afford. The wires
// leaving one endpoint for one cluster put their midpoints on top of each other, the
// collision pass dropped the losers, and the numbering that survived on the widest
// handler in the coordinator read `3, 5, 7, 9, 10, 32, 36, 56` — an order with holes in
// it, which is worse than no numbering at all, because a reader cannot tell a gap from a
// step. With the ladder the same focus keeps 33 of its 57 numbers and reads 1..12 without
// a gap.
//
// The slides come before the normals because a slide keeps the badge *on* its own curve
// while a step leaves it between two wires, and in a fan that dense some other wire is
// always within a pixel of the vacated space. Measured over the widest handler: slides
// first shows more numbers (33 against 26) and puts fewer of them nearer a neighbour's
// curve than their own. What settles the remainder is the leader tick, not the ordering —
// the fan is dense enough that proximity alone cannot say which wire a moved number
// belongs to, so `placeLabels` draws the answer instead of implying it.
//
// The direction comes from the two dots rather than from the control point because the
// tangent at the midpoint of a quadratic is parallel to its chord, so the chord *is* the
// direction the badge slides along.
const SEQ_RUNGS = [[0, 0], [-14, 0], [14, 0], [-26, 0], [26, 0], [0, -8], [0, 8],
  [-38, 0], [38, 0], [-14, -8], [14, 8]];
function seqSpots(l) {
  const bx = sx(l.cx), by = sy(l.cy) + SEQ_PX / 2;
  const dx = sx(l.t.x) - sx(l.s.x), dy = sy(l.t.y) - sy(l.s.y);
  const d = Math.hypot(dx, dy) || 1;
  const ux = dx / d, uy = dy / d;
  return SEQ_RUNGS.map(([a, n]) => [bx + ux * a - uy * n, by + uy * a + ux * n]);
}
// Below this the badge is close enough to its wire's midpoint that a tick would be
// shorter than the gap it is meant to bridge, and it is drawn without one.
const SEQ_LEAD_MIN = 7;
// How much of the tick is given up at each end: the wire keeps a little clear space so
// the tick does not read as part of it, and the digits keep enough that the tick stops at
// the number rather than under it.
const SEQ_LEAD_TRIM = 2.5;
const SEQ_LEAD_GAP = 6;
// drawLead joins a moved badge to the point on its own wire that it is numbering. `from`
// is the wire's midpoint — rung zero, which is where the badge would be if it had fit —
// and `to` is where it actually went; both are baseline positions, so the tick is drawn
// between the points those baselines hang off.
function drawLead(lead, from, to, color) {
  const x0 = from[0], y0 = from[1] - SEQ_PX / 2;
  const x1 = to[0], y1 = to[1] - SEQ_PX / 2;
  const d = Math.hypot(x1 - x0, y1 - y0);
  if (d < SEQ_LEAD_MIN) { lead.style.display = 'none'; return; }
  const ux = (x1 - x0) / d, uy = (y1 - y0) / d;
  lead.setAttribute('x1', (x0 + ux * SEQ_LEAD_TRIM).toFixed(1));
  lead.setAttribute('y1', (y0 + uy * SEQ_LEAD_TRIM).toFixed(1));
  lead.setAttribute('x2', (x1 - ux * SEQ_LEAD_GAP).toFixed(1));
  lead.setAttribute('y2', (y1 - uy * SEQ_LEAD_GAP).toFixed(1));
  lead.setAttribute('stroke', color);
  lead.style.display = '';
}

function placeLabels() {
  const box = gsvg.getBoundingClientRect();
  const W = box.width || 1200, H = box.height || 620;
  const taken = [];
  const fits = b => {
    if (b.x1 < 2 || b.y1 < 2 || b.x0 > W - 2 || b.y0 > H - 2) return false;
    for (const o of taken) if (b.x0 < o.x1 && o.x0 < b.x1 && b.y0 < o.y1 && o.y0 < b.y1) return false;
    return true;
  };
  const place = (node, cx, cy, w, h) => {
    const b = labelBox(cx, cy, w, h);
    if (!fits(b)) return false;
    taken.push(b);
    node.setAttribute('x', cx.toFixed(1));
    node.setAttribute('y', cy.toFixed(1));
    node.style.display = '';
    return true;
  };
  const hide = node => { node.style.display = 'none'; };

  // Cluster names anchor the reader, so they are never dropped — but zoomed far
  // out the rings crowd together and two names would print on top of each other,
  // which reads as one unparseable name rather than as two boundaries. So each is
  // offset until it clears the ones already placed: the ladder tries the ideal
  // position, then rungs above and below it in turn, nearest first, and settles for
  // the ideal position if every rung is taken — an anchor that is missing is worse
  // than one that is crowded. Below is a real position, not a fallback: a name 29px
  // under the top of its own ring is inside the ring, which still reads as that
  // boundary's name. Far out on a crowded map a name can end up ~90px from ideal,
  // which is the price of never dropping one.
  for (const id of clusterIds) {
    const t = hullLabels[id], sub = hullSubs[id];
    const cx = sx(center[id].x), cy = sy(center[id].y - radius[id]) - 2;
    const w = Math.max(textW(t.textContent, CLUSTER_LABEL_PX), textW(sub.textContent, CLUSTER_SUB_PX));
    let y = cy;
    for (const rung of CLUSTER_RUNGS) {
      y = cy + rung;
      if (fits(clusterBox(cx, y, w))) break;
    }
    t.setAttribute('x', cx.toFixed(1));
    t.setAttribute('y', y.toFixed(1));
    sub.setAttribute('x', cx.toFixed(1));
    sub.setAttribute('y', (y + 13).toFixed(1));
    t.style.display = sub.style.display = '';
    taken.push(clusterBox(cx, y, w));
  }
  for (const gid in groupLabels) {
    const grp = GROUPS[gid], t = groupLabels[gid];
    if (grp.r * view.k < GROUP_LABEL_MIN) { hide(t); continue; }
    place(t, sx(grp.cx), sy(grp.cy - grp.r) - 1,
      textW(t.textContent, GROUP_LABEL_PX), GROUP_LABEL_H) || hide(t);
  }

  // Candidates, in the order they earn their place. `pick` is what the reader
  // asked for and is exempt from the budget; `rest` competes for what is left.
  const pick = [], rest = [], chosen = new Set();
  const add = (list, n) => { if (chosen.has(n.id)) return; chosen.add(n.id); list.push(n); };
  const eligible = n => L.shown.has(n.id) && (!L.focused || L.focus.has(n.id));
  for (const n of GNODES) if (eligible(n) && (L.sel.has(n.id) || n.id === state.focus)) add(pick, n);
  for (const n of GNODES) if (eligible(n) && L.near.has(n.id)) add(pick, n);
  for (const n of depsByDegree) if (eligible(n)) add(rest, n);
  if (view.k >= EP_LABEL_ZOOM || L.focused || L.near.size) {
    for (const n of epsByDegree) if (eligible(n)) add(rest, n);
  }
  for (const n of GNODES) if (!chosen.has(n.id)) hide(n.text);

  const draw1 = (n, priority) => {
    const size = LABEL_PX[n.kind];
    const w = textW(n.text.textContent, size), h = size + 2;
    n.text.classList.toggle('pri', priority);
    const cx = sx(n.x);
    if (place(n.text, cx, sy(n.y) - n.r * view.k - 5, w, h)) return true;
    // Below is the only other place a label can go without pointing at the wrong
    // dot, and it is worth trying: the rings crowd from above.
    return place(n.text, cx, sy(n.y) + n.r * view.k + size + 4, w, h);
  };
  for (const n of pick) if (!draw1(n, true)) hide(n.text);

  // The numbers come after the names the reader asked for and before the ones the
  // picture offers: a focused endpoint's own dependency labels are what the badges
  // are numbering, so they win the space, and the busiest-dependency names in `rest`
  // do not outrank an answer to the question the click asked. Exempt from the budget
  // for the same reason `pick` is.
  const seq = seqLinks();
  const pool = seqPool(seq.length);
  for (let i = seq.length; i < SEQ_POOL.length; i++) { hide(SEQ_POOL[i]); hide(SEQ_LEADS[i]); }
  seq.forEach((l, i) => {
    const t = pool[i];
    const color = modeColor[l.mode] || 'var(--dim)';
    t.textContent = String(l.seq);
    t.setAttribute('fill', color);
    const w = textW(t.textContent, SEQ_PX), h = SEQ_PX + 2;
    const spots = seqSpots(l);
    // The first rung that fits wins, and `place` is what reports it — so the index is
    // also how far the badge had to travel, which is what the leader draws.
    const at = spots.findIndex(([x, y]) => place(t, x, y, w, h));
    if (at < 0) { hide(t); hide(SEQ_LEADS[i]); return; }
    drawLead(SEQ_LEADS[i], spots[0], spots[at], color);
  });

  let budget = LABEL_BUDGET;
  for (const n of rest) {
    if (budget <= 0 || !draw1(n, false)) hide(n.text);
    else budget--;
  }
}

function styleGraph() {
  const vis = { ep: new Set(), dep: new Set() };
  for (const ep of DATA.routes) {
    if (!matches(ep)) continue;
    vis.ep.add(ep.id);
    ep.dependencies.forEach(d => vis.dep.add(d));
  }
  const near = new Set();
  if (hover) {
    near.add(hover.id);
    for (const l of hover.links) { near.add(l.s.id); near.add(l.t.id); }
  }
  // The focused node and everything on its own edges. Nothing else is drawn at
  // more than a whisper, which is the difference between "here is the system" and
  // "here is what this touches".
  const fnode = state.focus ? gById[state.focus] : null;
  const fset = new Set();
  if (fnode) {
    fset.add(fnode.id);
    for (const l of fnode.links) { fset.add(l.s.id); fset.add(l.t.id); }
  }
  // With no filter applied, a declared node no endpoint reaches still belongs in
  // the picture — dashed rather than dimmed away, because it is a real boundary
  // driven by a background worker, not something the filter excluded.
  const narrowed = filtering();
  const shown = n => n.kind === 'ep'
    ? vis.ep.has(n.ep.id)
    : (vis.dep.has(n.dep) || ontPicks(n.dep) || (!narrowed && !reached(n.dep))) && ontOK(n.dep);
  const selected = n => (n.kind === 'ep' ? state.open === n.name : state.dep === n.dep);
  L.shown.clear(); L.near.clear(); L.sel.clear(); L.focus.clear();
  L.focused = !!fnode;
  for (const id of near) L.near.add(id);
  for (const id of fset) L.focus.add(id);
  for (const n of GNODES) {
    const on = shown(n);
    if (on) L.shown.add(n.id);
    if (selected(n)) L.sel.add(n.id);
    n.g.classList.toggle('mute', !on);
    n.g.classList.toggle('hi', near.has(n.id));
    n.g.classList.toggle('sel', selected(n));
    n.g.classList.toggle('shade', !!fnode && !fset.has(n.id));
    n.g.classList.toggle('unreached', n.kind === 'dep' && !reached(n.dep));
    n.text.textContent = n.kind === 'ep' ? n.name : shortName(n.dep);
    n.tip.textContent = n.kind === 'ep'
      ? n.name + (showProse() && n.ep.description ? ' — ' + n.ep.description : '')
      : n.dep + (showProse() ? ' — ' + label(n.dep) : '');
  }
  for (const l of GLINKS) {
    const live = shown(l.s) && shown(l.t) &&
      (!state.mode || l.mode === state.mode) &&
      (!state.dep || l.t.dep === state.dep) &&
      (!state.ns || l.s.ns === state.ns);
    const lit = hover && (l.s === hover || l.t === hover);
    const shaded = !!fnode && l.s !== fnode && l.t !== fnode;
    l.node.classList.toggle('mute', !live);
    l.node.classList.toggle('hi', !!lit && live);
    l.node.classList.toggle('shade', shaded);
    // A focused node's own wires. Opacity applies to a path *and to the markers it
    // references*, so a head on a wire at the base 22% is a hint of a head — which is
    // most of the reason the arrows could not be seen even after they were sized right.
    // The focus already darkens everything else; this is the other half of it.
    l.node.classList.toggle('pick', live && !!fnode && !shaded);
    // What syncArrows needs, recorded here rather than recomputed there: the zoom can
    // change which wires carry a head without changing any of this.
    l.live = live;
    l.lit = !!lit;
    l.shaded = shaded;
  }
  syncArrows();
  // A foreign key is visible whenever both of its tables are: it is a fact about the
  // schema, so no access-mode or namespace filter has an opinion about it, and the
  // node filters already decide whether the tables themselves are on the picture.
  for (const l of FKLINKS) {
    const live = shown(l.s) && shown(l.t);
    const lit = hover && (l.s === hover || l.t === hover);
    l.node.classList.toggle('mute', !live);
    l.node.classList.toggle('hi', !!lit && live);
    l.node.classList.toggle('shade', !!fnode && l.s !== fnode && l.t !== fnode);
  }
  // The dots and the lines between them are derived; the rings drawn around them
  // are the one piece of curated indirection in the picture — a category names its
  // cluster, a namespace joins its service's — so under the overlay view the
  // boundaries say so about themselves.
  gsvg.classList.toggle('prov', state.view === 'overlay');
  for (const id of clusterIds) {
    hullLabels[id].textContent = clusterTitle(id);
    hullSubs[id].textContent = (CLUSTERS[id].kind || '') + ' · ' +
      plural(members[id].length, 'node') + (state.view === 'overlay' ? ' · curated boundary' : '');
  }
  for (const gid in groupLabels) {
    groupLabels[gid].textContent = groupTitle(GROUPS[gid]) + ' · ' + GROUPS[gid].nodes.length;
  }
  document.body.classList.toggle('focused', !!fnode);
  if (fnode) {
    document.getElementById('gfocusname').textContent =
      fnode.kind === 'ep' ? fnode.name : shortName(fnode.dep);
    document.getElementById('gfocuscount').textContent =
      '· ' + plural(fnode.links.length, 'edge') + ', ' + (fset.size - 1) + ' neighbours';
  }
  placeLabels();
  // A hover always wins the panel — it is a question being asked right now — but
  // only the focused node gets the pinned, full-prose treatment.
  const subject = hover || fnode;
  drawInfo(subject, !!fnode && subject === fnode);
}

// ---------------------------------------------------------------------------
// The node panel. A hover is a preview; a click pins the full account of one
// node, and that is where the enrichment lives: what the thing is, what it
// represents, where it is constructed, how it is guarded, what a restart does to
// it. The derived facts and the prose are in separate labelled sections, because
// the whole point is that a reader can tell which is which.
// ---------------------------------------------------------------------------
const DOC_FIELDS = [
  ['represents', 'Represents'],
  ['construction', 'Constructed'],
  ['access', 'Accessed'],
  ['concurrency', 'Concurrency'],
  ['lifecycle', 'Lifecycle'],
  ['restart', 'On restart'],
];

function section(host, title) {
  host.append(el('h5', null, title));
}
function defList(pairs, marker) {
  const dl = el('dl');
  for (const [k, v] of pairs) {
    if (!v) continue;
    dl.append(el('dt', null, k));
    const dd = el('dd', null, v);
    dl.append(marker ? marker(dd) : dd);
  }
  return dl;
}
function identChip(dep) {
  const tier = identTier(dep);
  const c = el('span', 'ident i-' + tier, IDENT_LABEL[tier]);
  const by = ((DATA.nodes[dep] || {}).namedBy || []).join(', ');
  c.title = IDENT_WHY[tier] + (by ? '\n\nmapping tables: ' + by : '');
  return c;
}

function drawInfo(n, pinned) {
  const host = document.getElementById('ginfo');
  host.textContent = '';
  host.classList.toggle('pinned', !!pinned);
  if (!n) {
    host.append(el('h4', null, 'The whole system at once'));
    host.append(el('div', 'k', 'Every endpoint sits inside its namespace, every dependency inside ' +
      'its category, and both inside the process that owns them. Hover for what reaches what; ' +
      'click a node to shadow everything it does not touch and pin its detail here. Edge colour ' +
      'is the derived access mode; its dash is the indirection the handler reaches through, and a ' +
      'focused endpoint numbers its wires in the order the request meets them.'));
    const ul = el('ul');
    for (const [k, v] of Object.entries(modeColor)) {
      const li = el('li');
      const b = el('span', 'badge m-' + k, k);
      b.style.marginRight = '6px';
      li.append(b, el('span', null, DATA.stateModeLegend[k] || ''));
      li.style.color = v;
      ul.append(li);
    }
    host.append(ul);
    const kinds = el('ul');
    for (const k of KINDS) {
      const li = el('li');
      const arrow = el('span', 'kind k-' + k, KIND_ARROW[k]);
      arrow.style.marginRight = '6px';
      li.append(arrow, el('span', null, KIND_LABEL[k] || k));
      li.title = kindWhy(k);
      kinds.append(li);
    }
    host.append(kinds);
    if (FKLINKS.length) {
      host.append(el('div', 'k', 'The dotted arcs between tables are declared foreign keys: ' +
        FKLINKS.length + ' of them, read out of the REFERENCES the service itself issues.'));
    }
    return;
  }
  const head = el('div', 'row');
  head.append(el('h4', null, n.kind === 'ep' ? n.ep.method + ' ' + n.ep.path : shortName(n.dep)));
  if (pinned) {
    const x = el('button', 'x', '×');
    x.title = 'Clear the focus';
    x.setAttribute('aria-label', 'Clear the focus');
    x.onclick = clearFocus;
    head.append(x);
  }
  host.append(head);
  const meta = CLUSTERS[n.cluster];
  if (n.kind === 'ep') { drawEpInfo(host, n, meta, pinned); return; }
  drawDepInfo(host, n, meta, pinned);
}

function drawEpInfo(host, n, meta, pinned) {
  const ep = n.ep;
  host.append(pc(el('div', 'k', ep.namespace + ' · ' +
    (serviceTitle[ep.service] || ep.service) + ' · ' + meta.title)));
  const auth = el('div');
  auth.append(pc(el('span', null, ep.auth), true));
  if (say(ep.authDetail)) auth.append(pp(el('span', null, ' — ' + ep.authDetail), true));
  host.append(auth);
  host.append(el('div', 'k mono', ep.handler));
  if (say(ep.description)) host.append(pp(el('div', 'k', ep.description)));
  if (pinned) {
    if (say(ep.details)) host.append(pp(el('div', 'k', ep.details)));
    section(host, 'Derived');
    host.append(defList([
      ['Middleware', ep.middleware.length ? ep.middleware.join(' → ') : 'none'],
      ['Gates', ep.gates.length ? ep.gates.join(', ') : 'none'],
    ]));
    const src = el('div');
    src.append(srcLink(ep.source, ep.sourceUrl), el('span', null, ' '),
      srcLink(ep.routeFile + ':' + ep.routeLine, ep.routeUrl));
    host.append(src);
    if (showProse() && (ep.callers || []).length) {
      section(host, 'Prose');
      host.append(pp(defList([['Callers', ep.callers.join(', ')]])));
    }
  }
  // Ordered, not alphabetical: the flow names exactly the dependencies the list used
  // to, so nothing is lost by numbering them, and the order is the answer to the
  // question a reader opens an endpoint with.
  const flow = ep.flow || [];
  section(host, flow.length
    ? plural(flow.length, 'construction') + ' reached, in wiring order'
    : plural(ep.dependencies.length, 'dependency', 'dependencies') + ' reached');
  host.append(wiringList(ep, pinned ? PANEL_CAP : 8, { paths: pinned }));
}

// wiringList is the ordered account of one endpoint's state: the sequence the request
// meets each construction in, what it does to it, the indirection it is reached
// through, how many places touch it, and — where there is room — the call path itself
// and the lines it was read off. It is one builder because the graph panel and the
// endpoint table are asking the same question, and a reader who compares them must
// not find two different answers.
//
// Every fact in it is derived, so none of it is prose-marked and none of it is
// withheld in the code view. Only the node's *label* is prose, and it falls back to
// the id there like every other label.
function wiringList(ep, cap, opts) {
  const o = opts || {};
  // `role="list"` because the CSS removes the markers — the sequence number is drawn
  // as text instead — and a list with `list-style: none` loses its list semantics in
  // WebKit, which would drop the one announcement that says how many steps there are.
  const ol = el('ol', 'wiring');
  ol.setAttribute('role', 'list');
  const flow = ep.flow || [];
  // A route with dependencies but no flow cannot happen from this generator; the IR
  // permits it, so the unordered list stays as the fallback rather than the endpoint
  // silently losing its state.
  const steps = flow.length ? flow : ep.dependencies.map(d => ({ node: d, mode: epMode(ep, d) }));
  if (!steps.length) {
    ol.append(el('li', null, 'no state reached'));
    return ol;
  }
  for (const s of steps.slice(0, cap)) {
    const li = el('li');
    const kind = stepKind(s);
    // The row's subject, stated rather than left to be parsed out of its text: the
    // label beside it is prose and disappears in the code view, so this is what a
    // reader's tooling — and the DOM suite — addresses the row by.
    li.dataset.node = s.node;
    li.append(el('span', 'seqn', s.seq ? String(s.seq) : '·'));
    li.append(el('span', 'badge m-' + (s.mode || '?'), s.mode || '?'));
    const link = el('span', 'lk', showProse() ? label(s.node) : s.node);
    link.onclick = () => { state.focus = 'dep:' + s.node; selectDep(s.node); };
    li.append(el('span', null, ' '), showProse() ? pp(link, true) : link, el('span', null, ' '));
    const arrow = el('span', 'kind k-' + kind, KIND_ARROW[kind] || '→');
    arrow.title = kindWhy(kind);
    const lead = s.leadKind ? (KIND_LABEL[s.leadKind] || s.leadKind) : '';
    // The arrow is the strongest indirection over the whole step, and the path printed
    // under it belongs to the *earliest* touch. When those are two different touches the
    // two disagree on purpose, and saying which is which is the difference between a
    // second fact and an apparent contradiction.
    if (lead) arrow.title += '\nThe earliest touch — the one the path below is — is a ' + lead + '.';
    li.append(arrow);
    // The glyph is a picture, and `title` is a hover affordance rather than a reliable
    // announcement — so the indirection is also stated in text that only assistive tech
    // reads. Without it the row's one statement of how the endpoint reaches this
    // construction is a bare arrow character.
    li.append(el('span', 'sronly', ' ' + (KIND_LABEL[kind] || kind) + ' '));
    // Touches counts source sites, not executions — nothing here runs the program —
    // and a loop is the one place where one site is known to run more than once. The
    // path count is a floor for the same reason the map is static: evidence is
    // collapsed per site and frame, so two routes reaching one construction through
    // one frame are one path here.
    const notes = [];
    if (s.touches > 1) notes.push(plural(s.touches, 'site'));
    if (s.repeats) notes.push('in a loop');
    if (s.wireCount > 1) notes.push('at least ' + plural(s.wireCount, 'path'));
    if (lead) notes.push('first touch ' + lead);
    // Dispatch, not timing: which implementation runs is unknown at compile time, and
    // that is a different question from when the touch happens. It travels beside the
    // ladder rather than on it, so it is only worth a note where the arrow does not
    // already say it.
    if (s.iface && kind !== 'interface') notes.push('through an interface');
    if (s.depth) notes.push('depth ' + s.depth);
    if (notes.length) li.append(el('span', 'desc', ' ' + notes.join(' · ')));
    if (o.paths && (s.wires || []).length) {
      const full = wirePath(s.wires[0]);
      const wire = el('div', 'wire mono', full.map(shortSym).join(' → '));
      wire.title = full.join('\n');
      li.append(wire);
    }
    if (o.cites && (s.sites || []).length) {
      const box = el('div', 'desc');
      for (const i of s.sites) box.append(srcLink(siteName(i)), el('span', null, ' '));
      li.append(box);
    }
    ol.append(li);
  }
  if (steps.length > cap) ol.append(el('li', null, '+' + (steps.length - cap) + ' more'));
  return ol;
}

function drawDepInfo(host, n, meta, pinned) {
  const dep = n.dep;
  host.append(pc(el('div', 'k mono', dep)));
  if (showProse()) host.append(pp(el('div', null, label(dep))));
  const line = el('div');
  line.append(el('span', 'badge m-' + (nodeMode[dep] || '?'), nodeMode[dep] || '?'));
  line.append(pc(el('span', null, ' ' + catTitle(n.cat) + ' · ' + meta.title), true));
  host.append(line);
  const ident = el('div');
  ident.style.marginTop = '5px';
  ident.append(identChip(dep));
  host.append(ident);

  const doc = nodeDoc(dep);
  if (showProse() && doc && doc.overview) host.append(pp(el('div', 'k', doc.overview)));

  const table = tableFor(dep);
  if (table) {
    const open = el('button', null, table.columns.length + ' derived columns — open definition');
    open.style.marginTop = '6px';
    open.onclick = () => { state.table = dep; state.wide = false; drawSchema(); };
    host.append(open);
  }

  section(host, 'Derived');
  host.append(el('div', null, n.links.length
    ? plural(n.links.length, 'endpoint') + ' reach it, in ' +
      plural(uniq(n.links.map(l => l.s.ns)).length, 'namespace')
    : 'No endpoint reaches it — declared, and driven by a background worker.'));
  const ul = el('ul');
  const cap = pinned ? 16 : 8;
  for (const l of n.links.slice(0, cap)) {
    const li = el('li', 'mono');
    li.append(el('span', null, l.mode + ' · '));
    const link = el('span', 'lk', l.s.name);
    link.onclick = () => { state.focus = l.s.id; openEndpoint(l.s.name); };
    li.append(link);
    ul.append(li);
  }
  if (n.links.length > cap) ul.append(el('li', null, '+' + (n.links.length - cap) + ' more'));
  host.append(ul);
  if (!pinned) return;

  // Citations for this node, taken from the namespace associations that evidence
  // it: the exact lines the extractor read.
  const cites = [];
  for (const ns of uniq([...(nodeNamespaces[dep] || [])])) {
    const e = edgeOf(ns, dep);
    if (e) for (const c of e.citations) cites.push(c);
  }
  if (cites.length) {
    section(host, 'Evidenced at');
    const box = el('div');
    for (const c of uniq(cites).slice(0, 8)) { box.append(srcLink(c)); box.append(el('span', null, ' ')); }
    host.append(box);
  }

  const cache = DATA.cacheSemantics && DATA.cacheSemantics[dep];
  if (showProse() && cache) {
    const s = el('div', 'prose-section');
    section(s, 'Cache semantics');
    s.append(pp(defList([
      ['Lookup', cache.lookup], ['Fill / update', cache.fill_update],
      ['Invalidate', cache.invalidate], ['Aggregate', cache.aggregate],
    ])));
    host.append(s);
  }

  if (showProse() && doc) {
    const s = el('div', 'prose-section');
    section(s, 'Prose — what this is');
    s.append(pp(defList(DOC_FIELDS.map(([k, t]) => [t, doc[k]]))));
    if ((doc.sources || []).length) {
      const box = el('div');
      box.style.marginTop = '6px';
      for (const site of doc.sources) { box.append(srcLink(site)); box.append(el('span', null, ' ')); }
      s.append(pp(box));
    }
    host.append(s);
    const cat = DATA.categoryDocs && DATA.categoryDocs[n.cat];
    if (cat) {
      const box = el('details', 'prose-section');
      box.append(el('summary', null, 'About ' + (cat.title || n.cat)));
      box.append(pp(defList([
        ['Overview', cat.overview], ['Construction', cat.construction],
        ['How it is used', cat.walk], ['Durability', cat.durability],
      ])));
      host.append(box);
    }
  } else if (!showProse()) {
    host.append(el('div', 'withheld', 'Prose withheld: 8 curated fields explain what this node is, ' +
      'what constructs it, how it is guarded and what a restart does to it. None of them can move ' +
      'an edge, and no gate checks their words.'));
  }
}

// ---------------------------------------------------------------------------
// drawSchema shows a table's derived definition. The columns are not transcribed
// from a schema doc: they are read out of the CREATE TABLE the service issues plus
// every `ALTER TABLE ... ADD COLUMN` migration that grew it afterwards — which is
// why each row carries its own file:line, and why the migration-added ones are
// marked. A definition read from the CREATE alone would describe a database that
// only exists on a machine that has never been migrated.
//
// The widest table in the coordinator has 79 columns, so the drawer opens wide
// enough to read and can take the whole graph when that is not enough.
// ---------------------------------------------------------------------------
// openTable follows a reference. When the other table has a dependency node the whole
// selection moves — the graph focuses it and the drawer follows it, which is what a click
// means everywhere else on this page. It opens, and only opens: `selectDep` toggles, so
// calling it on the table already selected would close the drawer this was asked to show,
// which is what a reader clicking from `usage` to `models` and back again does in two
// clicks. So the filter is only touched when it has to move, and the focus follows the
// drawer either way — a table with a node is always worth focusing, whether or not the
// reader's own dependency filter already happens to name it.
function openTable(name) {
  const id = 'pg.' + name;
  if (DATA.nodes[id]) {
    state.focus = 'dep:' + id;
    if (state.dep !== id) { selectDep(id); return; }
    state.table = id;
    draw();
    return;
  }
  state.table = id;
  // Nothing in the graph stands for this table, so there is nothing to focus on its
  // behalf — and a focus left pinned to whichever node the reader came from would go on
  // shading the picture around a node that is not what the drawer now shows. The
  // dependency *filter* is left alone: that one is the reader's own narrowing, and this
  // is a click on a reference, not a request to change what the graph contains.
  clearFocus();
}
// One key as a line of the drawer: which columns carry the reference, which table they
// point at, and what the database does when the parent row goes away. The table being
// looked at is plain text; the other one is the link.
function fkItem(from, to, fk) {
  const open = tableFor(state.table);
  const here = open ? open.name : '';
  const name = t => {
    if (t === here) return el('span', 'mono', t);
    const a = el('span', 'lk mono', t);
    a.onclick = () => openTable(t);
    return a;
  };
  const li = el('li');
  li.append(name(from), el('span', 'mono', colList(fk.columns) + ' → '),
    name(to), el('span', 'mono', colList(fk.refColumns)));
  const acts = fkActions(fk);
  if (acts) li.append(el('span', 'desc', ' ' + acts));
  li.append(el('span', null, ' '), srcLink(fk.site, fk.url));
  return li;
}

function drawSchema() {
  const host = document.getElementById('gschema');
  host.textContent = '';
  const table = tableFor(state.table);
  host.hidden = !table;
  host.classList.toggle('wide', !!state.wide);
  if (!table) return;

  const head = el('div', 'gs-head');
  head.append(el('h4', null, table.name));
  const wide = el('button', null, state.wide ? '⤡' : '⤢');
  wide.title = state.wide ? 'Shrink the definition' : 'Expand the definition';
  wide.setAttribute('aria-label', wide.title);
  wide.onclick = () => { state.wide = !state.wide; drawSchema(); };
  head.append(wide);
  const close = el('button', null, '×');
  close.title = 'Close the table definition';
  close.setAttribute('aria-label', 'Close the table definition');
  close.onclick = () => { state.table = null; state.wide = false; drawSchema(); };
  head.append(close);
  host.append(head);

  const migrations = table.columns.filter(c => c.migration).length;
  const summary = el('div', 'k');
  if (showProse()) summary.append(pp(el('span', null, label(state.table)), true), el('span', null, ' · '));
  summary.append(el('span', null, plural(table.columns.length, 'column') +
    (migrations ? ', ' + migrations + ' added by migration' : '') +
    ' · derived from ' + plural(table.ddl.length, 'DDL statement')));
  host.append(summary);

  // Who touches it, derived from the same associations the graph draws — the
  // question a reader actually has when they open a table.
  const spaces = uniq([...(nodeNamespaces[state.table] || [])]);
  if (spaces.length) {
    host.append(el('div', 'k', 'Reached by ' + plural(spaces.length, 'namespace') + ':'));
    const row = el('div', 'gs-reach');
    for (const ns of spaces) {
      const e = edgeOf(ns, state.table);
      const c = el('span', 'chip' + (state.ns === ns ? ' on' : ''));
      c.append(pc(el('span', null, ns), true));
      c.append(el('span', 'badge m-' + ((e || {}).mode || '?'), (e || {}).mode || '?'));
      c.title = (e || {}).reason || '';
      c.onclick = () => selectNs(ns);
      row.append(c);
    }
    host.append(row);
  } else {
    host.append(el('div', 'k', 'No endpoint reaches this table; a background worker owns it.'));
  }

  const t = el('table');
  const thead = el('thead');
  const hr = el('tr');
  for (const [h, w] of [['Column', ''], ['Type', ''], ['Definition', ''], ['Declared at', '108px']]) {
    const th = el('th', null, h);
    if (w) th.style.width = w;
    hr.append(th);
  }
  thead.append(hr);
  t.append(thead);
  const tbody = el('tbody');
  const cell = (...kids) => { const td = el('td'); td.append(...kids); return td; };
  for (const col of table.columns) {
    const tr = el('tr');
    const name = cell(el('span', 'mono', col.name));
    if (col.migration) {
      const tag = el('span', 'badge gs-mig', 'migration');
      tag.title = 'Added by an ALTER TABLE ... ADD COLUMN, not by the original CREATE.';
      name.append(tag);
    }
    tr.append(name, cell(el('span', 'mono', col.type || '—')),
      el('td', 'desc', col.extra || ''), cell(srcLink(col.site, col.url)));
    tbody.append(tr);
  }
  t.append(tbody);
  host.append(t);

  // Foreign keys in both directions. Outgoing is the table's own declaration;
  // incoming is every other table that points at it, which is the half a CREATE TABLE
  // cannot tell you and the half that says what a delete here costs. Both are read
  // out of the DDL the service issues, so each line carries its own file:line, and the
  // other table is a link because a key is only useful if you can follow it.
  const outgoing = table.foreignKeys || [];
  const incoming = fkInbound[table.name] || [];
  if (outgoing.length || incoming.length) {
    const box = el('details');
    box.open = true;
    box.append(el('summary', null, 'Foreign keys · ' + outgoing.length + ' declared here, ' +
      incoming.length + ' pointing here'));
    const ul = el('ul', 'fklist');
    for (const fk of outgoing) ul.append(fkItem(table.name, fk.table, fk));
    for (const inb of incoming) ul.append(fkItem(inb.from, table.name, inb.fk));
    box.append(ul);
    host.append(box);
  } else {
    // Said rather than left blank: a table with no keys in either direction and a
    // table whose keys the derivation missed look identical when the section is
    // simply absent, and the two are opposite claims.
    host.append(el('div', 'desc', 'Foreign keys · none declared in either direction.'));
  }

  if ((table.constraints || []).length) {
    const box = el('details');
    box.open = true;
    box.append(el('summary', null, 'Table constraints (' + table.constraints.length + ')'));
    const ul = el('ul');
    for (const c of table.constraints) {
      const li = el('li');
      li.append(el('span', 'mono', c.text), el('span', null, ' '), srcLink(c.site, c.url));
      ul.append(li);
    }
    box.append(ul);
    host.append(box);
  }

  for (const stmt of table.ddl) {
    const box = el('details');
    // The CREATE is the shape of the thing; the migrations are its history, and
    // they stay folded until asked for.
    box.open = stmt.kind === 'create';
    const sum = el('summary');
    sum.append(el('span', null, stmt.kind.toUpperCase() + ' · '), srcLink(stmt.site, stmt.url));
    box.append(sum);
    box.append(el('pre', null, stmt.sql));
    host.append(box);
  }
}

// ---------------------------------------------------------------------------
// View transform.
// ---------------------------------------------------------------------------
function applyView() {
  scene.setAttribute('transform', 'translate(' + view.x + ' ' + view.y + ') scale(' + view.k + ')');
  // The heads are annotations on the scene rather than parts of it, so they are resized
  // against the new scale here, beside the transform that made them wrong.
  sizeMarkers();
  placeLabels();
}
function bbox(nodes) {
  const pad = 70;
  const xs = nodes.map(n => n.x), ys = nodes.map(n => n.y);
  return { x0: Math.min(...xs) - pad, y0: Math.min(...ys) - pad,
    x1: Math.max(...xs) + pad, y1: Math.max(...ys) + pad };
}
// framed records whether the view was ever computed against a real pixel size, so
// a first resize after layout can refit instead of keeping a fallback scale.
let framed = false;
function frame(nodes) {
  const b = bbox(nodes);
  const box = gsvg.getBoundingClientRect();
  // A hidden or not-yet-laid-out container reports a zero rect; falling back to
  // the CSS size keeps the transform finite instead of NaN.
  const rect = { width: box.width || 1200, height: box.height || 620 };
  framed = framed || !!box.width;
  gsvg.setAttribute('viewBox', '0 0 ' + rect.width + ' ' + rect.height);
  view.k = Math.min(rect.width / (b.x1 - b.x0), rect.height / (b.y1 - b.y0));
  view.x = rect.width / 2 - ((b.x0 + b.x1) / 2) * view.k;
  view.y = rect.height / 2 - ((b.y0 + b.y1) / 2) * view.k;
  applyView();
  styleGraph();
}
const fit = () => frame(GNODES);
const focusCluster = id => frame(members[id]);

function zoomBy(factor, cx, cy) {
  const box = gsvg.getBoundingClientRect();
  const rect = { width: box.width || 1200, height: box.height || 620 };
  const px = cx == null ? rect.width / 2 : cx, py = cy == null ? rect.height / 2 : cy;
  const k = Math.max(0.15, Math.min(8, view.k * factor));
  view.x = px - ((px - view.x) / view.k) * k;
  view.y = py - ((py - view.y) / view.k) * k;
  view.k = k;
  applyView();
  styleGraph();
}
gsvg.addEventListener('wheel', ev => {
  ev.preventDefault();
  const rect = gsvg.getBoundingClientRect();
  zoomBy(Math.exp(-ev.deltaY * 0.0015), ev.clientX - rect.left, ev.clientY - rect.top);
}, { passive: false });
// The graph is viewport-sized by default and can take the whole screen. The SVG's
// viewBox is a function of the element's pixel size, so every size change has to
// update it — otherwise the scene keeps the old aspect ratio and skews.
const graphBox = document.getElementById('graph');
const isFull = () => (document.fullscreenElement || document.webkitFullscreenElement) === graphBox;
function toggleFull() {
  if (isFull()) {
    (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    return;
  }
  const request = graphBox.requestFullscreen || graphBox.webkitRequestFullscreen;
  // Fullscreen can be unavailable or refused; the viewport-sized default already
  // shows the whole graph, so failing quietly is the right outcome.
  if (request) Promise.resolve(request.call(graphBox)).catch(() => {});
}
function resizeView() {
  const box = gsvg.getBoundingClientRect();
  if (!box.width || !box.height) return;
  // The first real size arrives after the initial fit ran against the fallback
  // rect, so that one refits; later resizes only restate the viewBox and leave the
  // reader where they were.
  if (!framed) { fit(); return; }
  gsvg.setAttribute('viewBox', '0 0 ' + box.width + ' ' + box.height);
  applyView();
  styleGraph();
}
for (const ev of ['fullscreenchange', 'webkitfullscreenchange']) {
  document.addEventListener(ev, () => {
    document.getElementById('gfull').textContent = isFull() ? 'Exit full screen' : 'Full screen';
    // Entering or leaving full screen is a deliberate reframing, so refit rather
    // than preserving a zoom chosen for the other size.
    requestAnimationFrame(fit);
  });
}
// Resizing preserves the view: only the viewBox changes, not where the reader was.
new ResizeObserver(resizeView).observe(graphBox);
// The zoom controls are the buttons that name a zoom action; the arrow toggle sits in
// the same bar and has its own handler, so the lookup is guarded rather than assuming
// every button in the bar is a zoom.
for (const b of document.querySelectorAll('.gbar button[data-z]')) {
  b.onclick = () => ({ in: () => zoomBy(1.35), out: () => zoomBy(1 / 1.35), fit,
    full: toggleFull }[b.dataset.z]());
}
// auto → all → read → auto: the judgement, then both ways of overruling it.
const ARROW_MODES = ['auto', 'all', 'read'];
const arrowsBtn = document.getElementById('garrows');
arrowsBtn.onclick = () => {
  state.arrows = ARROW_MODES[(ARROW_MODES.indexOf(state.arrows) + 1) % ARROW_MODES.length];
  // The label and the reason both come from syncArrows, which is where the rule lives.
  styleGraph();
};
gsvg.addEventListener('pointerdown', ev => {
  if (ev.target.closest('.gnode')) return;
  const start = { x: ev.clientX, y: ev.clientY, vx: view.x, vy: view.y };
  let moved = false;
  gsvg.classList.add('drag');
  gsvg.setPointerCapture(ev.pointerId);
  const move = e => {
    if (Math.abs(e.clientX - start.x) + Math.abs(e.clientY - start.y) > 2) moved = true;
    view.x = start.vx + (e.clientX - start.x);
    view.y = start.vy + (e.clientY - start.y);
    applyView();
  };
  const up = () => {
    gsvg.classList.remove('drag');
    gsvg.removeEventListener('pointermove', move);
    gsvg.removeEventListener('pointerup', up);
    // A press on empty canvas is how you put the whole system back.
    if (!moved && state.focus) clearFocus();
  };
  gsvg.addEventListener('pointermove', move);
  gsvg.addEventListener('pointerup', up);
});
// A node drag repositions it (and stays inside its own boundary); a press with no
// movement is a click, which focuses the node and opens its detail.
function dragNode(n) {
  n.g.addEventListener('pointerdown', ev => {
    ev.stopPropagation();
    const start = { x: ev.clientX, y: ev.clientY, nx: n.x, ny: n.y };
    let moved = false;
    n.g.setPointerCapture(ev.pointerId);
    const move = e => {
      const dx = (e.clientX - start.x) / view.k, dy = (e.clientY - start.y) / view.k;
      if (Math.abs(dx) + Math.abs(dy) > 2) moved = true;
      n.x = start.nx + dx; n.y = start.ny + dy;
      clamp(n);
      positionGraph();
    };
    const up = () => {
      n.g.removeEventListener('pointermove', move);
      n.g.removeEventListener('pointerup', up);
      if (!moved) clickNode(n);
    };
    n.g.addEventListener('pointermove', move);
    n.g.addEventListener('pointerup', up);
  });
}

// ---------------------------------------------------------------------------
// The inventory underneath the graph.
// ---------------------------------------------------------------------------
function drawBoundaries() {
  const host = document.getElementById('boundaries');
  host.textContent = '';
  const byCat = {};
  for (const id of Object.keys(DATA.nodes)) (byCat[DATA.nodes[id].category] = byCat[DATA.nodes[id].category] || []).push(id);
  const visible = new Set();
  for (const ep of DATA.routes) if (matches(ep)) ep.dependencies.forEach(d => visible.add(d));
  for (const cat of Object.keys(DATA.categories)) {
    const ids = (byCat[cat] || []).sort();
    if (!ids.length) continue;
    const meta = DATA.categories[cat];
    const col = el('div', 'col');
    // The category's name places it in a cluster (structural); its blurb is prose.
    // Which nodes are in it, and how many, is derived.
    col.append(pc(el('h3', null, catTitle(cat) + ' (' + ids.length + ')')));
    if (say(meta.desc)) col.append(pp(el('p', null, meta.desc)));
    for (const id of ids) {
      col.append(chip(id, { cls: (visible.has(id) || ontPicks(id)) && ontOK(id) ? 'on' : 'off' }));
    }
    host.append(col);
  }
}

function detailRow(ep) {
  const tr = el('tr');
  const td = el('td');
  td.colSpan = 5;
  const box = el('div', 'detail');
  if (say(ep.description)) box.append(pp(el('div', null, ep.description)));
  if (say(ep.details)) box.append(pp(el('div', 'desc', ep.details)));
  const dl = el('dl');
  const add = (k, ...kids) => { dl.append(el('dt', null, k)); const dd = el('dd'); dd.append(...kids); dl.append(dd); };
  // Handler, middleware and gates are read out of the route table and the call
  // graph. The auth *class* is the name an overlay rule gives that derived
  // middleware/gate combination, and its detail sentence and callers are prose.
  add('Handler', el('span', 'mono', ep.handler));
  add('Authorization', pc(el('span', null, ep.auth), true),
    say(ep.authDetail) ? pp(el('span', null, ' — ' + ep.authDetail), true) : el('span'));
  add('Middleware', el('span', 'mono', ep.middleware.length ? ep.middleware.join(' → ') : 'none'));
  add('Gates', el('span', 'mono', ep.gates.length ? ep.gates.join(', ') : 'none'));
  if (showProse()) {
    add('Callers', pp(el('span', null, (ep.callers || []).join(', ') || 'unspecified'), true));
  }
  const deps = el('div', 'deps');
  for (const d of ep.dependencies) deps.append(chip(d, { mode: epMode(ep, d), cls: 'on' }));
  if (!ep.dependencies.length) deps.append(el('span', 'desc', 'no state reached'));
  add('Dependencies', deps);
  // The chips above are the set; this is the sequence, with the call path each
  // construction is reached along and the lines it was read off. Both are derived from
  // the same walk, so the row is the same claim stated twice — once as "what", once as
  // "in what order, through what".
  if ((ep.flow || []).length) add('Wiring', wiringList(ep, 12, { paths: true, cites: true }));
  const src = el('div');
  const link = (text, href, ref) => {
    if (href) { const a = el('a', 'mono', text); a.href = href; a.target = '_blank'; a.rel = 'noopener'; src.append(a); }
    else src.append(el('span', 'mono', ref));
    src.append(el('span', 'desc', ' '));
  };
  link(ep.source, ep.sourceUrl, ep.source);
  link('registered at ' + ep.routeFile + ':' + ep.routeLine, ep.routeUrl, ep.routeFile + ':' + ep.routeLine);
  add('Source', src);
  box.append(dl);
  td.append(box);
  tr.append(td);
  return tr;
}

function drawRoutes() {
  const body = document.querySelector('#routes tbody');
  body.textContent = '';
  let shown = 0;
  for (const ep of DATA.routes) {
    if (!matches(ep)) continue;
    shown++;
    const key = ep.method + ' ' + ep.path;
    const tr = el('tr', 'ep' + (state.open === key ? ' sel' : ''));
    const methodCell = el('td');
    methodCell.append(el('span', 'method ' + ep.method, ep.method));
    tr.append(methodCell);
    const pathCell = el('td');
    pathCell.append(el('div', 'path', ep.path));
    if (say(ep.description)) pathCell.append(pp(el('div', 'desc', ep.description)));
    tr.append(pathCell);
    // The path, method and reached dependencies are derived; which namespace and
    // auth class the path falls into is an overlay rule matched against them.
    tr.append(pc(el('td', null, ep.namespace)));
    tr.append(pc(el('td', null, ep.auth)));
    const depCell = el('td', 'deps');
    for (const d of ep.dependencies) depCell.append(chip(d, { mode: epMode(ep, d), cls: 'on' }));
    if (!ep.dependencies.length) depCell.append(el('span', 'desc', '—'));
    tr.append(depCell);
    tr.onclick = () => {
      state.open = state.open === key ? null : key;
      state.focus = state.open ? 'ep:' + ep.id : null;
      location.hash = encodeURIComponent(key);
      draw();
    };
    body.append(tr);
    if (state.open === key) body.append(detailRow(ep));
  }
  const none = document.getElementById('noroutes');
  none.hidden = shown > 0;
  // Zero is the correct answer for the `unreached` identity — those nodes are
  // declared but no endpoint reaches them, which is the definition — so say that
  // rather than letting it read as an over-narrow filter.
  none.textContent = state.ont === 'unreached'
    ? 'No endpoint reaches a declared-but-unreached node — that is what this identity selects. ' +
      'The nodes themselves are highlighted in the graph and the boundaries below.'
    : 'No endpoint matches these filters.';
  document.getElementById('count').textContent = shown + ' of ' + DATA.routes.length + ' endpoints' +
    (state.dep ? ' reaching ' + label(state.dep) : '');
}

function drawEdges() {
  const body = document.querySelector('#edges tbody');
  body.textContent = '';
  for (const e of DATA.stateAccess) {
    if (state.ns && e.namespace !== state.ns) continue;
    if (state.dep && e.dependency !== state.dep) continue;
    // The access-mode control means two different things in the two tables, and it is
    // supposed to. A row here *is* a namespace-scoped association, so its mode is the
    // aggregate and filtering on `e.mode` is filtering on the row's own subject. A row
    // in the endpoint table is one route, so that table filters on `epMode`. Selecting
    // "Writes only" can therefore show an association the endpoint table has no row
    // for — the namespace writes the table, this endpoint only reads it — which is the
    // distinction the two tables exist to show rather than a disagreement.
    if (state.mode && e.mode !== state.mode) continue;
    if (!ontOK(e.dependency)) continue;
    if (state.q && !(e.namespace + ' ' + e.dependency + ' ' +
      (showProse() ? label(e.dependency) + ' ' : '') + e.reason).toLowerCase().includes(state.q)) continue;
    const tr = el('tr');
    tr.append(pc(el('td', null, e.namespace)));
    const dep = el('td');
    // The node's label is prose, its id is the curated identity the mapping
    // assigned; the mode, the reason and every citation are derived.
    if (showProse()) dep.append(pp(el('div', null, label(e.dependency))));
    dep.append(pc(el('div', 'desc mono', e.dependency)));
    tr.append(dep);
    const modeCell = el('td');
    modeCell.append(el('span', 'badge m-' + e.mode, e.mode));
    tr.append(modeCell);
    const why = el('td');
    why.append(el('div', 'desc', e.reason));
    const cites = el('div', 'mono desc');
    cites.textContent = e.citations.join('  ·  ');
    why.append(cites);
    tr.append(why);
    tr.append(el('td', 'desc', String(e.routes.length)));
    body.append(tr);
  }
}

// The declared relationships between tables. Every row is derived: the generator reads
// each REFERENCES out of the DDL the service issues, and the drift gate fails when one
// names a table no CREATE TABLE declares — so this table cannot claim a relationship
// to something that does not exist. It lists every key, including the ones between
// tables the graph draws no line for because no endpoint reaches them.
function drawFks() {
  const body = document.querySelector('#fks tbody');
  body.textContent = '';
  const rows = [];
  for (const name of Object.keys(DATA.tables || {}).sort()) {
    for (const fk of DATA.tables[name].foreignKeys || []) rows.push({ from: name, fk });
  }
  let shown = 0;
  for (const r of rows) {
    const ids = ['pg.' + r.from, 'pg.' + r.fk.table];
    if (state.dep && !ids.includes(state.dep)) continue;
    // The ids, not only the bare names: every other surface on the page calls this
    // table `pg.usage`, so searching for what the reader was just shown has to work
    // here too. A bare name is a substring of its id, so both still match.
    if (state.q && !(ids.join(' ') + ' ' + (r.fk.columns || []).join(' ') + ' ' +
      (r.fk.refColumns || []).join(' ')).toLowerCase().includes(state.q)) continue;
    shown++;
    const tr = el('tr');
    const cell = (name) => {
      const td = el('td');
      const a = el('span', 'lk mono', name);
      a.onclick = () => openTable(name);
      td.append(a);
      return td;
    };
    tr.append(cell(r.from));
    tr.append(el('td', 'mono desc', (r.fk.columns || []).join(', ')));
    const to = cell(r.fk.table);
    to.append(el('span', 'mono desc', ' ' + colList(r.fk.refColumns)));
    tr.append(to);
    tr.append(el('td', 'desc', r.fk.onDelete || 'NO ACTION (default)'));
    const at = el('td');
    at.append(srcLink(r.fk.site, r.fk.url));
    if (r.fk.onUpdate) at.append(el('span', 'desc', ' · ON UPDATE ' + r.fk.onUpdate));
    tr.append(at);
    body.append(tr);
  }
  const none = document.getElementById('nofks');
  none.hidden = shown > 0;
  none.textContent = rows.length
    ? 'No declared foreign key matches these filters.'
    : 'No foreign key is declared in the analyzed source.';
}

// Actors and credentials are passed through from the overlay untouched: no
// extractor produces them and no gate contradicts them, which makes them the only
// sections of the page a stale sentence can survive in indefinitely. They are read
// with the field names the overlay actually uses, so the page shows the words
// rather than the ids.
function drawLegend() {
  const modes = document.getElementById('modes');
  modes.textContent = '';
  for (const [k, v] of Object.entries(DATA.stateModeLegend)) {
    const d = el('div');
    d.append(el('span', 'badge m-' + k, k));
    d.append(el('span', null, ' ' + v));
    modes.append(d);
  }
  // The indirection legend is the picture's own key: each entry draws the wire exactly
  // as the graph draws it, with the same dash and the same arrowhead, so a reader
  // matches a line to a sentence rather than to a second vocabulary. The sentences are
  // the generator's — a kind it adds appears here without this file changing.
  const kinds = document.getElementById('kinds');
  kinds.textContent = '';
  for (const k of KINDS) {
    const why = (DATA.stepKindLegend || {})[k];
    if (!why) continue;
    const d = el('div');
    const head = el('b');
    head.append(el('span', 'kind k-' + k, KIND_ARROW[k]), el('span', null, ' ' + (KIND_LABEL[k] || k)));
    d.append(head);
    // The sample wire restates the glyph and the sentence beside it, so a reader using
    // a screen reader has already been told what it says. It carries the fixed-size head:
    // this SVG has no zoom, and a key that resized with the graph's would be a lie about
    // the size of the thing it is a key to.
    const wire = svg('svg', { class: 'kwire', width: 110, height: 12, viewBox: '0 0 110 12',
      'aria-hidden': 'true', focusable: 'false' });
    wire.append(svg('path', { d: 'M2 6 H96', fill: 'none', stroke: 'var(--rw)',
      'stroke-width': 1.6, 'stroke-dasharray': KIND_DASH[k] || 'none',
      'marker-end': 'url(#' + markerID(k, LEGEND_MODE, true) + ')' }));
    d.append(wire);
    d.append(el('div', 'desc', why));
    kinds.append(d);
  }

  const roles = document.getElementById('roles');
  roles.textContent = '';
  for (const r of DATA.roles || []) {
    const d = px(el('div'));
    d.append(el('b', null, r.title || r.id || ''));
    if (r.kind) d.append(el('div', 'kind', r.kind));
    if (r.summary) d.append(el('div', 'desc', r.summary));
    d.append(defList([
      ['Calls as', (r.callers || []).join(', ')],
      ['Credentials', (r.credentials || []).join(', ')],
      ['Custody', r.custody],
    ]));
    roles.append(d);
  }
  const creds = document.getElementById('creds');
  creds.textContent = '';
  for (const c of DATA.credentials || []) {
    const d = px(el('div'));
    d.append(el('b', null, c.title || c.id || ''));
    if (c.class) d.append(el('div', 'kind', c.class));
    d.append(defList([
      ['Issuer', c.issuer],
      ['Holder', c.holder],
      ['Lifetime', c.lifetime],
      ['On the client', c.clientStorage],
      ['On the server', c.serverStorage],
      ['Validation', c.validation],
      ['Used by', (c.usedBy || []).join(', ')],
    ]));
    if ((c.sources || []).length) {
      const box = el('div');
      for (const s of c.sources) {
        const a = el('a', null, s.label || s.url);
        a.href = s.url;
        a.target = '_blank';
        a.rel = 'noopener';
        box.append(a, el('span', null, ' '));
      }
      d.append(box);
    }
    creds.append(d);
  }
}

// ---------------------------------------------------------------------------
// The provenance view control. `code` is subtractive, and the banner it reveals
// says exactly what left and what did not, with the drawn-topology fingerprint as
// the receipt.
// ---------------------------------------------------------------------------
const WITHHELD = (() => {
  let fields = 0;
  for (const d of Object.values(DATA.depDocs || {})) {
    if (d && typeof d === 'object') fields += Object.keys(d).length;
  }
  return {
    labels: Object.keys(DATA.labels || {}).length,
    descriptions: DATA.routes.filter(r => r.description).length,
    fields,
    roles: (DATA.roles || []).length,
    creds: (DATA.credentials || []).length,
  };
})();
function setView(next) {
  state.view = next;
  for (const b of document.querySelectorAll('.seg button')) {
    b.classList.toggle('on', b.dataset.view === next);
    b.setAttribute('aria-pressed', String(b.dataset.view === next));
  }
  document.body.classList.remove('v-all', 'v-code', 'v-overlay');
  document.body.classList.add('v-' + next);
  fillDeps();
  sizeStage();
  draw();
}
// The banner is real vertical space, and the graph is sized against the viewport,
// so the stage hands that space back.
function sizeStage() {
  const bar = state.view === 'code' ? document.getElementById('codebar')
    : state.view === 'overlay' ? document.getElementById('provbar') : null;
  document.documentElement.style.setProperty('--barh', bar ? bar.offsetHeight + 10 + 'px' : '0px');
}

function draw() {
  styleGraph();
  drawSchema();
  drawBoundaries();
  drawRoutes();
  drawEdges();
  drawFks();
  document.getElementById('topo').textContent = topoFingerprint();
}

document.getElementById('q').oninput = e => { state.q = e.target.value.trim().toLowerCase(); draw(); };
document.getElementById('ns').onchange = e => { state.ns = e.target.value; draw(); };
document.getElementById('auth').onchange = e => { state.auth = e.target.value; draw(); };
document.getElementById('dep').onchange = e => {
  state.dep = e.target.value;
  state.table = tableFor(state.dep) ? state.dep : null;
  draw();
};
document.getElementById('mode').onchange = e => { state.mode = e.target.value; draw(); };
document.getElementById('ont').onchange = e => { state.ont = e.target.value; draw(); };
for (const b of document.querySelectorAll('.seg button')) {
  b.onclick = () => setView(b.dataset.view);
}
// Reset clears what the reader chose to look at. It leaves the provenance view
// alone: that is not a filter on the system, it is a statement about who wrote
// the page, and it stays where it was put.
document.getElementById('reset').onclick = () => {
  Object.assign(state, { q: '', ns: '', auth: '', dep: '', mode: '', ont: '',
    open: null, table: null, wide: false, focus: null });
  for (const id of ['q', 'ns', 'auth', 'dep', 'mode', 'ont']) document.getElementById(id).value = '';
  location.hash = '';
  fit();
  draw();
};
document.getElementById('gfocusclear').onclick = clearFocus;
addEventListener('keydown', e => { if (e.key === 'Escape' && state.focus) clearFocus(); });
addEventListener('resize', () => { sizeStage(); fit(); });

document.getElementById('withheld').textContent =
  WITHHELD.labels + ' node labels, ' + WITHHELD.descriptions + ' endpoint descriptions, ' +
  WITHHELD.fields + ' node prose fields, ' + WITHHELD.roles + ' actors, ' + WITHHELD.creds +
  ' credentials';

if (location.hash.length > 1) state.open = decodeURIComponent(location.hash.slice(1));
// Markers first: the legend below and the wires above both reference them by id.
buildMarkers();
drawLegend();
buildGraph();
setView('all');
