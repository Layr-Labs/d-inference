// Building the timeline fixtures the DOM suite drives.
//
// Two pieces. `headShape` reads the map's own head revision out of the inventory, so
// the newest point of a fixture is the shape the page is already drawing — which is
// what makes "returning the slider to Now reproduces the map" an assertion rather than
// an aspiration. `encode` turns a list of shapes into the delta-encoded artifact the
// page parses, mirroring history/timeline.go's encoder.
//
// The mirror is deliberate and its cost is stated: the Go encoder has its own tests
// (history/timeline_test.go replays every point in both directions), and this one
// exists so a *decoder* test can specify a sequence of shapes instead of hand-writing
// index lists. Where the ordering itself is the claim — removals before additions —
// the test hand-writes the point rather than going through here.

import assert from 'node:assert/strict';

// The head revision as a shape: the same routes, nodes and wires the page draws, with
// the wire modes chosen the way page.js's `epMode` chooses them (the endpoint's own
// derived mode, the namespace aggregate only as a fallback). history/shape.go's `wires`
// is the Go side of that same rule, and getting it wrong there recoloured a tenth of
// the picture the moment the slider moved.
export function headShape(D, { rev = 'head0000000', date = '2026-09-08', subject = 'the head revision' } = {}) {
  const routes = D.routes.map(r => ({
    key: r.method + ' ' + r.path, ns: r.namespace, group: r.group, auth: r.auth,
  }));
  const nodes = Object.keys(D.nodes).sort().map(id => ({
    id, category: D.nodes[id].category, group: D.nodes[id].group, label: D.nodes[id].label || id,
  }));
  const agg = new Map();
  for (const e of D.stateAccess || []) agg.set(e.namespace + '\0' + e.dependency, e.mode);
  // Keyed, so a dependency listed twice cannot become two wires between the same pair —
  // the page draws one per (endpoint, dependency) and the fixture has to agree.
  const wires = new Map();
  for (const r of D.routes) {
    const key = r.method + ' ' + r.path;
    for (const dep of r.dependencies || []) {
      if (!D.nodes[dep]) continue; // a dependency with no node has no dot to draw to
      const mode = (r.depModes || {})[dep] || agg.get(r.namespace + '\0' + dep) || '?';
      wires.set(key + '\0' + dep, { route: key, node: dep, mode });
    }
  }
  return { rev, date, subject, routes, nodes, links: [...wires.values()],
    tables: Object.keys(D.tables || {}).length };
}

// A shape with most of the head's routes, nodes and wires taken out, plus whatever the
// caller wants added that the head does not have. This is how a fixture says "the
// service in April": a subset, plus the parts of April that did not survive.
//
// The nodes are the ones the kept endpoints actually reach rather than the first N of
// the head's list, so a fixture always has wires in it — a subset picked by two
// independent slices can easily have none, and half of what these tests assert is about
// wires.
export function subset(head, { routes = 3, wires = 8, rev, date, subject,
  addRoutes = [], addNodes = [], addWires = [], fidelity } = {}) {
  const keep = head.routes.slice(0, routes);
  const live = new Set(keep.map(r => r.key));
  const keptWires = head.links.filter(l => live.has(l.route)).slice(0, wires);
  assert.ok(keptWires.length, 'the head revision\'s first endpoints reach no state, so a subset of them has no wires to assert about');
  const reached = new Set(keptWires.map(l => l.node));
  const byID = new Map(head.nodes.map(n => [n.id, n]));
  const keptNodes = [...reached].sort().map(id => byID.get(id));
  // Deduplicated by id: a caller adding a node to make a point of it should not have to
  // know whether the kept wires already reached it, and a point that listed the same node
  // twice would report a node count no revision had.
  const nodes = [...new Map(keptNodes.concat(addNodes).map(n => [n.id, n])).values()];
  return {
    rev, date, subject,
    routes: keep.concat(addRoutes),
    nodes,
    links: keptWires.concat(addWires),
    tables: 2,
    fidelity,
  };
}

// encode is the Go encoder in JavaScript: append-only interned union tables, and one
// point per shape holding only what changed. A wire's identity includes its mode, so a
// wire whose access mode changed encodes as one removal and one addition.
export function encode(shapes, { ref = 'refs/heads/test', head = '' } = {}) {
  const tl = { ref, head, routes: [], nodes: [], links: [], snapshots: [], failed: [] };
  const rIdx = new Map(), nIdx = new Map(), lIdx = new Map();
  const routeIx = r => {
    if (!rIdx.has(r.key)) {
      rIdx.set(r.key, tl.routes.length);
      tl.routes.push({ key: r.key, ns: r.ns, group: r.group, auth: r.auth });
    }
    return rIdx.get(r.key);
  };
  const nodeIx = n => {
    if (!nIdx.has(n.id)) {
      nIdx.set(n.id, tl.nodes.length);
      tl.nodes.push({ id: n.id, category: n.category, group: n.group, label: n.label });
    }
    return nIdx.get(n.id);
  };
  const linkIx = l => {
    const key = l.route + '\0' + l.node + '\0' + l.mode;
    if (!lIdx.has(key)) {
      // Both endpoints are interned by the time a wire is, because every point encodes
      // its routes and nodes first. A miss here is a malformed fixture, not a page bug,
      // so it is said out loud rather than written as an index into nothing.
      assert.ok(rIdx.has(l.route), `fixture wire names route ${l.route}, which no shape has`);
      assert.ok(nIdx.has(l.node), `fixture wire names node ${l.node}, which no shape has`);
      lIdx.set(key, tl.links.length);
      tl.links.push({ r: rIdx.get(l.route), n: nIdx.get(l.node), m: l.mode });
    }
    return lIdx.get(key);
  };
  const diff = (now, was, keyOf) => {
    const a = new Map(now.map(x => [keyOf(x), x]));
    const b = new Map((was || []).map(x => [keyOf(x), x]));
    return [
      [...a].filter(([k]) => !b.has(k)).map(([, x]) => x),
      [...b].filter(([k]) => !a.has(k)).map(([, x]) => x),
    ];
  };
  let prev = null;
  shapes.forEach((sh, i) => {
    const rev = sh.rev || String(i).repeat(11);
    const p = {
      rev, date: sh.date || '2026-0' + (i + 1) + '-01',
      subject: sh.subject || 'commit ' + i,
      module: 'github.com/eigeninference/d-inference', prefix: 'coordinator/',
      tables: sh.tables || 0, fidelity: sh.fidelity || {},
      counts: { routes: sh.routes.length, nodes: sh.nodes.length, links: sh.links.length },
    };
    const [ra, rd] = diff(sh.routes, prev && prev.routes, r => r.key);
    const [na, nd] = diff(sh.nodes, prev && prev.nodes, n => n.id);
    const wkey = l => l.route + '\0' + l.node + '\0' + l.mode;
    const [la, ld] = diff(sh.links, prev && prev.links, wkey);
    // Additions are interned before removals are resolved, because a mode change's two
    // halves share their endpoints and the removed half was interned when it arrived.
    if (ra.length) p.ra = ra.map(routeIx);
    if (na.length) p.na = na.map(nodeIx);
    if (la.length) p.la = la.map(linkIx);
    if (rd.length) p.rd = rd.map(r => rIdx.get(r.key));
    if (nd.length) p.nd = nd.map(n => nIdx.get(n.id));
    if (ld.length) p.ld = ld.map(l => lIdx.get(wkey(l)));
    tl.snapshots.push(p);
    prev = sh;
  });
  return tl;
}

// The shapes the DOM suite walks, newest last and equal to the head revision:
//
//   0  a small service, plus an endpoint and a table it has since deleted
//   1  one more endpoint arrives; the deleted pair goes away here, so this is the
//      point whose ghosts the picture draws
//   2  nothing arrives or leaves — one surviving wire changes access mode
//   3  the commit that touched the service without changing its shape
//   4  the head revision
//
// Every kind of change a commit can make to the picture, in five points, ending at the
// one the page is already drawing.
export const GONE_ROUTE = 'GET /v1/ancient';
export const GONE_NODE = 'pg.ancient';

export function fixture(D, { head = '' } = {}) {
  const H = headShape(D);
  // A wire between two things that both survive, which the head revision does not have.
  // Everything else historical in this fixture leaves with its endpoint, so it is absent
  // from the picture and from the inventory alike; this one is the case where only the
  // *wire* is historical, and it is the leak the panels had. Every revision's wires go
  // into the same adjacency list — that is what makes one layout serve the whole walk —
  // so a node's edge list is the union's, and a panel reading it unfiltered described a
  // shape no commit ever had.
  //
  // A dependency nothing reaches at the head revision is preferred, because then the
  // wrong answer is categorical rather than off by one: "no endpoint reaches it" becomes
  // "one endpoint reaches it", with a working link to the endpoint, on a page whose whole
  // premise is that the graph is authoritative.
  const reached = new Set(H.links.map(l => l.node));
  const orphan = H.nodes.find(n => !reached.has(n.id)) ||
    H.nodes.find(n => !H.links.some(l => l.node === n.id && l.route === H.routes[0].key));
  assert.ok(orphan, 'every node is reached by the head revision\'s first endpoint, so no wire can be historical alone');
  const staleRoute = H.routes[0].key;
  const ancientRoute = { key: GONE_ROUTE, ns: H.routes[0].ns, group: H.routes[0].group, auth: 'public' };
  const ancientNode = { id: GONE_NODE, category: H.nodes[0].category, group: H.nodes[0].group,
    label: 'the ancient table' };
  const p0 = subset(H, {
    rev: 'aaaaaaaaaaa', date: '2026-03-21', subject: 'the first commit that had a route table',
    routes: 3, wires: 6,
    addRoutes: [ancientRoute], addNodes: [ancientNode, orphan],
    addWires: [{ route: GONE_ROUTE, node: GONE_NODE, mode: 'RW' },
      // A wire from a surviving endpoint to the since-deleted table: the association
      // the head revision does not have, which only the union table records.
      { route: H.routes[0].key, node: GONE_NODE, mode: 'R' },
      // And the same thing between two survivors — see `orphan` above.
      { route: staleRoute, node: orphan.id, mode: 'RW' }],
    fidelity: { unmapped: 4 },
  });
  const p1 = subset(H, {
    rev: 'bbbbbbbbbbb', date: '2026-05-02', subject: 'the deleted subsystem goes away',
    routes: 5, wires: 12,
  });
  // The mode change: one wire of p1's, with its access mode inverted. It is a wire that
  // survives to the head revision — otherwise this would be a removal, which is a
  // different case and already covered by the deleted subsystem.
  const flip = m => (m === 'R' ? 'W' : 'R');
  const was = p1.links[0];
  const changed = { route: was.route, node: was.node, head: was.mode, then: flip(was.mode) };
  const p2 = {
    rev: 'ccccccccccc', date: '2026-07-14', subject: 'an endpoint starts writing what it read',
    routes: p1.routes, nodes: p1.nodes, tables: p1.tables,
    links: p1.links.map((l, i) => (i ? l : { ...l, mode: changed.then })),
  };
  const p3 = { ...p2, rev: 'ddddddddddd', date: '2026-08-30',
    subject: 'a refactor that changed no shape' };
  const shapes = [p0, p1, p2, p3, H];
  // `stale` is the wire only the first point has, and how many endpoints reach its
  // dependency at the head revision — which is what a panel describing the head must say
  // however far back the slider is, and is usually zero.
  const stale = { route: staleRoute, node: orphan.id,
    headReachers: H.links.filter(l => l.node === orphan.id).length };
  return { shapes, head: H, changed, stale, timeline: encode(shapes, { head }) };
}
