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

const state = { q: '', ns: '', auth: '', dep: '', mode: '', ont: '',
  view: 'all', open: null, table: null, wide: false, focus: null };

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
      ep.gates.join(' '), ep.dependencies.join(' '),
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
// access mode rather than its namespace's aggregate.
for (const ep of DATA.routes) {
  const s = gById['ep:' + ep.id];
  for (const dep of ep.dependencies) {
    const t = gById['dep:' + dep];
    if (!t) continue;
    const link = { s, t, dep, ep, mode: epMode(ep, dep) };
    GLINKS.push(link);
    s.links.push(link);
    t.links.push(link);
  }
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
  for (const l of GLINKS) {
    l.node = svg('path', { class: 'glink', stroke: modeColor[l.mode] || 'var(--dim)',
      'data-topo': linkTopo(l) });
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

function positionGraph() {
  for (const id of clusterIds) hullPaths[id].setAttribute('d', hullPath(members[id], 26));
  for (const gid in groupPaths) groupPaths[gid].setAttribute('d', hullPath(GROUPS[gid].nodes, 13));
  for (const l of GLINKS) {
    const mx = (l.s.x + l.t.x) / 2, my = (l.s.y + l.t.y) / 2;
    // Bow each association away from the straight line so parallel edges between
    // the same two discs stay distinguishable.
    const dx = l.t.x - l.s.x, dy = l.t.y - l.s.y;
    const d = Math.hypot(dx, dy) || 1;
    const bow = Math.min(60, d * 0.12);
    l.node.setAttribute('d', 'M' + l.s.x.toFixed(1) + ' ' + l.s.y.toFixed(1) +
      'Q' + (mx - (dy / d) * bow).toFixed(1) + ' ' + (my + (dx / d) * bow).toFixed(1) +
      ' ' + l.t.x.toFixed(1) + ' ' + l.t.y.toFixed(1));
  }
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
      'is the derived access mode.'));
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
  section(host, plural(ep.dependencies.length, 'dependency', 'dependencies') + ' reached');
  const ul = el('ul');
  const cap = pinned ? PANEL_CAP : 8;
  for (const d of ep.dependencies.slice(0, cap)) {
    const li = el('li', null, epMode(ep, d) + ' · ');
    const link = el('span', 'lk', showProse() ? label(d) : d);
    link.onclick = () => { state.focus = 'dep:' + d; selectDep(d); };
    li.append(showProse() ? pp(link, true) : link);
    ul.append(li);
  }
  if (!ep.dependencies.length) ul.append(el('li', null, 'no state reached'));
  if (ep.dependencies.length > cap) {
    ul.append(el('li', null, '+' + (ep.dependencies.length - cap) + ' more'));
  }
  host.append(ul);
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
for (const b of document.querySelectorAll('.gbar button')) {
  b.onclick = () => ({ in: () => zoomBy(1.35), out: () => zoomBy(1 / 1.35), fit,
    full: toggleFull }[b.dataset.z]());
}
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
drawLegend();
buildGraph();
setView('all');
