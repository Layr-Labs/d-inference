// The explorer, executed. Every test here loads the generated page in a DOM, runs
// its script, drives a control the way a reader would, and asserts about the DOM
// the page produced — not about the text of the script that produced it.
//
// The assertions are written against the embedded inventory rather than against
// hard-coded counts, so this suite runs unchanged over the fixture map (which the
// Go driver renders, and which is what makes `go test ./...` cover the UI) and over
// the real coordinator map (which CI builds and points it at).

import test from 'node:test';
import assert from 'node:assert/strict';
import { load, frame, visible, searchTerm, drawnTable } from './harness.mjs';
import { labelUnits } from './labels.mjs';

const rows = p => p.$$('#routes tbody tr.ep');
const shownCount = p => {
  const said = p.text('#count');
  const n = Number(said.split(' ')[0]);
  assert.ok(Number.isInteger(n), `the counter does not start with a count: ${JSON.stringify(said)}`);
  return n;
};
// The endpoint table and the counter are two statements about one filter, so every
// test checks them against each other and against the inventory.
const assertShown = (p, want, what) => {
  assert.equal(rows(p).length, want, `endpoint rows ${what}`);
  assert.equal(shownCount(p), want, `the counter ${what}`);
};

// nsModes is the namespace-scoped aggregate, keyed the way the page keys it. Both
// helpers below need it, and computing it twice would let the two answers drift.
function nsModes(D) {
  const byNsDep = {};
  for (const e of D.stateAccess) byNsDep[e.namespace + '\0' + e.dependency] = e.mode;
  return byNsDep;
}

// The inventory's own answer to "in what mode does this endpoint reach this state",
// recomputed from the data: the endpoint's own derived mode if it has one, otherwise
// its namespace's aggregate. The distinction is the whole point — an endpoint that
// reads a table its namespace also writes is not an endpoint that writes it.
function modeOf(D) {
  const byNsDep = nsModes(D);
  return (r, d) => (r.depModes || {})[d] || byNsDep[r.namespace + '\0' + d] || '?';
}

// The identity axis, restated from the data. The page's own `identTier` is on
// `window` and could be called instead — but a page that answered one tier for every
// node would then be scored against its own mistake, so the rule is written out:
// nothing names it → declared; source's own CREATE TABLE wins; then a curated name on
// a source literal; otherwise a curated name on a Go symbol.
const LITERAL_KINDS = new Set(['hosts', 'endpoints', 'messages']);
function tierOf(namedBy) {
  if (!namedBy.length) return 'declared';
  if (namedBy.includes('sql')) return 'source';
  if (namedBy.some(k => LITERAL_KINDS.has(k))) return 'literal';
  return 'symbol';
}

// An endpoint whose own mode for some dependency is not its namespace's aggregate.
// Every assertion about endpoint-scoped modes is vacuous without one, so the tests
// that make that claim look for it and say so if this map has none.
//
// `within` bounds how far down an endpoint's dependency list to look, for the caller
// that can only see the first few — the pinned panel lists PANEL_CAP of them and
// summarises the rest, so a divergence past the cap is real but not on screen.
// What the panel lists for one endpoint, in the order it lists it: the derived wiring
// order where the generator produced a flow, and the alphabetical dependency list as
// the page's own fallback where it did not. Written out here so no test hard-codes an
// order, and so "the row at position i" means the same thing to the test as to the page.
const panelOrder = r => ((r.flow || []).length ? r.flow.map(s => s.node) : r.dependencies);

function divergent(D, within = Infinity) {
  const mode = modeOf(D);
  const agg = nsModes(D);
  const aggregate = (r, d) => agg[r.namespace + '\0' + d];
  for (const r of D.routes) {
    for (const d of panelOrder(r).slice(0, within)) {
      if (aggregate(r, d) && mode(r, d) !== aggregate(r, d)) {
        return { route: r, dep: d, own: mode(r, d), aggregate: aggregate(r, d) };
      }
    }
  }
  return null;
}

test('the page executes, and draws the whole inventory', t => {
  const p = load({ t });
  assert.deepEqual(p.errors.map(String), [], 'the page threw while loading');

  const D = p.peek('DATA');
  const nodeCount = Object.keys(D.nodes).length;
  assert.equal(p.$$('#gnodes g.gnode').length, D.routes.length + nodeCount,
    'one square per endpoint and one circle per dependency');
  const links = D.routes.reduce((n, r) => n + r.dependencies.filter(d => D.nodes[d]).length, 0);
  assert.equal(p.$$('#glinks path.glink').length, links, 'one path per (endpoint, dependency) pair');
  assertShown(p, D.routes.length, 'starts at the whole route table');
  assert.match(p.text('#topo'), /^[0-9a-f]{8}$/, 'the topology fingerprint was computed');
  assert.equal(p.$('#noroutes').hidden, true, 'the empty state is showing over a full table');
  assert.ok(p.$$('#boundaries .col').length > 0, 'the boundary columns were drawn');
  assert.equal(p.$$('#gkey .ck').length, p.peek('clusterIds').length, 'one key chip per cluster');
});

test('search narrows the endpoint table, and reset puts it back', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const before = rows(p).length;

  // A term taken from the data rather than invented, so the test cannot be made to
  // pass by a page that filters nothing.
  const term = searchTerm(D);
  p.type('#q', term);
  const hits = rows(p).map(tr => tr.children[0].textContent + ' ' + tr.querySelector('.path').textContent);
  assert.ok(hits.length <= before, `search for ${term} selected ${hits.length} of ${before}`);
  assertShown(p, hits.length, `after searching for ${term}`);

  // Both halves, because either alone is satisfied by a broken filter: a page that
  // selects nothing passes soundness, and a page that selects everything passes
  // completeness.
  //
  // Complete — the search reads the path among other fields, so every route whose
  // path carries the term has to be here. That is a lower bound the page cannot meet
  // by filtering less, because the term came out of one of these paths.
  const key = r => r.method + ' ' + r.path;
  for (const r of D.routes) {
    if (!r.path.toLowerCase().includes(term)) continue;
    assert.ok(hits.includes(key(r)), `${key(r)} contains ${term} and was filtered out`);
  }
  // Sound — every row shown has the term somewhere in its own record, or in a label
  // of some state it reaches, which the search also reads. A weaker statement than
  // the page's field list, deliberately: restating that list here would pass in
  // lockstep with a page that searched the wrong fields.
  for (const hit of hits) {
    const r = D.routes.find(x => key(x) === hit);
    assert.ok(r, `the table shows ${hit}, which is not in the inventory`);
    const hay = (JSON.stringify(r) + ' ' +
      r.dependencies.map(d => (D.labels || {})[d] || '').join(' ')).toLowerCase();
    assert.ok(hay.includes(term),
      `${hit} was selected by a search for ${term}, which appears nowhere in it`);
  }

  p.press('#reset');
  assertShown(p, before, 'after reset');
  assert.equal(p.$('#q').value, '', 'reset left the query in the box');
  assert.equal(p.peek('state.focus'), null, 'reset left a focus behind');
  // Reset is about what the reader is looking at, not about who wrote the page.
  p.view('code');
  p.press('#reset');
  assert.equal(p.peek('state.view'), 'code', 'reset changed the provenance view');
});

test('the namespace and auth filters agree with the inventory', t => {
  const p = load({ t });
  const D = p.peek('DATA');

  const ns = D.routes[D.routes.length - 1].namespace;
  p.choose('#ns', ns);
  assertShown(p, D.routes.filter(r => r.namespace === ns).length, `for namespace ${ns}`);
  for (const tr of rows(p)) {
    assert.equal(tr.children[2].textContent, ns, 'a row outside the chosen namespace is shown');
  }

  p.choose('#ns', '');
  const auth = D.routes[0].auth;
  p.choose('#auth', auth);
  assertShown(p, D.routes.filter(r => r.auth === auth).length, `for auth class ${auth}`);

  // Two filters compose rather than replace.
  p.choose('#ns', ns);
  assertShown(p, D.routes.filter(r => r.auth === auth && r.namespace === ns).length,
    `for ${auth} inside ${ns}`);
});

test('the access-mode filter keeps the endpoints that reach state in that mode', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const mode = modeOf(D);

  for (const want of ['R', 'W', 'RW']) {
    p.choose('#mode', want);
    const keep = D.routes.filter(r => r.dependencies.some(d => mode(r, d) === want));
    assertShown(p, keep.length, `for mode ${want}`);
  }
  p.choose('#mode', '');
  assertShown(p, D.routes.length, 'after clearing the mode');

  // The verb a row shows has to be that endpoint's own, not its namespace's
  // aggregate — an endpoint that reads a table its namespace also writes is not an
  // endpoint that writes it, and the graph drew that edge R while the table said RW.
  for (const tr of rows(p)) {
    const method = tr.children[0].textContent;
    const path = tr.querySelector('.path').textContent;
    const route = D.routes.find(r => r.method === method && r.path === path);
    assert.ok(route, `the table shows ${method} ${path}, which is not in the inventory`);
    const badges = [...tr.children[4].querySelectorAll('.badge')].map(b => b.textContent);
    // `Array.from` rather than `.map`: the inventory's arrays belong to the page's
    // realm, and a strict deep comparison of two identical arrays with different
    // Array prototypes fails on the prototype.
    assert.deepEqual(badges, Array.from(route.dependencies, d => mode(route, d)),
      `the chips for ${method} ${path} do not carry this endpoint's own derived modes`);
  }
});

test('every drawn association carries its own endpoint’s mode', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const mode = modeOf(D);
  // The edge, the chip and the panel are three renderings of one derived fact, and
  // the first two once disagreed: an aggregate read here draws the graph's arrows in
  // a mode no endpoint has. Asserting it edge by edge is what makes a page that
  // reverts to the aggregate fail rather than merely look different.
  const links = p.peek('GLINKS');
  assert.ok(links.length > 0, 'the map drew no associations');
  for (const l of links) {
    assert.equal(l.mode, mode(l.ep, l.dep),
      `the edge from ${l.ep.method} ${l.ep.path} to ${l.dep} is drawn ${l.mode}`);
  }

  // And the claim is only worth making if the two answers differ somewhere in this
  // map, which is the shape a regression would hide behind.
  const d = divergent(D);
  assert.ok(d, 'no endpoint in this map reaches state in a mode its namespace does not, so the endpoint-scoped mode is untested here');
  assert.equal(mode(d.route, d.dep), d.own);
  assert.notEqual(d.own, d.aggregate);
});

test('the pinned panel reports the focused endpoint’s own modes', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const mode = modeOf(D);
  const PANEL_CAP = p.peek('PANEL_CAP');
  const d = divergent(D, PANEL_CAP);
  assert.ok(d, `no endpoint in this map reaches state in a mode its namespace does not, in its first ${PANEL_CAP} dependencies`);
  // Pin the panel on the endpoint that diverges, which is where an aggregate read
  // is visible to a reader.
  const node = p.pick(n => n.kind === 'ep' && n.ep.method === d.route.method && n.ep.path === d.route.path,
    `node for ${d.route.method} ${d.route.path}`);
  p.clickNode(node.g);
  assert.ok(p.$('#ginfo').classList.contains('pinned'), 'the click did not pin the panel');

  // Each row states its own subject, so the mode is scored against the state that
  // row is about rather than against the position it happens to hold. The "+N more"
  // summary line past the cap names no node and is therefore not a row.
  const listed = p.$$('#ginfo ol.wiring li[data-node]');
  assert.ok(listed.length > 0, 'the pinned panel listed no dependencies');
  assert.ok(listed.length <= PANEL_CAP,
    `the pinned panel listed ${listed.length} rows, past its own cap of ${PANEL_CAP}`);
  const order = panelOrder(d.route);
  for (let i = 0; i < listed.length; i++) {
    const dep = listed[i].dataset.node;
    assert.equal(dep, order[i], `panel row ${i + 1} is about ${dep}, not ${order[i]}`);
    const badge = listed[i].querySelector('.badge');
    assert.ok(badge, `panel row ${i + 1} (${dep}) carries no access mode`);
    assert.equal(badge.textContent, mode(d.route, dep),
      `the panel says ${JSON.stringify(badge.textContent)} for ${dep}, not ${mode(d.route, dep)}`);
  }
  // And the divergent dependency itself, addressed by the row that names it, so a
  // row about a different dependency cannot satisfy it.
  const at = order.indexOf(d.dep);
  assert.ok(at >= 0 && at < listed.length,
    `${d.dep} is construction ${at} of ${d.route.method} ${d.route.path}, past the panel's cap of ${PANEL_CAP}`);
  assert.equal(listed[at].querySelector('.badge').textContent, d.own,
    `the panel reports ${d.dep} as its namespace's ${d.aggregate} rather than this endpoint's ${d.own}`);
});

test('the identity filter selects nodes by where their name comes from', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const unreached = Object.keys(D.nodes).filter(id => !D.nodes[id].reached);

  // The axis itself: four identities and "any". An option that stopped being offered
  // is a whole reading of the map that quietly left, and every assertion below it
  // would still hold on the unfiltered page.
  assert.deepEqual(p.options('#ont'), ['', 'source', 'literal', 'symbol', 'unreached'],
    'the identity axis no longer offers exactly the four identities and "any"');

  p.choose('#ont', 'unreached');
  // Zero endpoints is the correct answer for this identity — no endpoint reaches a
  // declared-but-unreached node, that is the definition — and the empty state has
  // to say so rather than read as an over-narrow filter.
  assertShown(p, 0, 'for the unreached identity');
  assert.equal(p.$('#noroutes').hidden, false, 'the empty state stayed hidden');
  assert.match(p.text('#noroutes'), /declared-but-unreached/,
    'the empty state reads as a failed filter rather than as the answer');
  // The nodes themselves are what this identity is for, so they stay drawn.
  const drawn = p.peek('GNODES').filter(n => n.kind === 'dep' && !n.g.classList.contains('mute'));
  assert.equal(drawn.length, unreached.length, 'the unreached nodes are not the ones left drawn');

  // The other three identities, each against a count derived from `namedBy` rather
  // than against `> 0`. `> 0` is what let the whole axis collapse to one tier and
  // still read as covered: a page that answered "source" for every node would select
  // every endpoint for every identity and pass.
  const byTier = {};
  for (const id of Object.keys(D.nodes)) byTier[id] = tierOf(D.nodes[id].namedBy || []);
  for (const want of ['source', 'literal', 'symbol']) {
    p.choose('#ont', want);
    const keep = D.routes.filter(r => r.dependencies.some(d => byTier[d] === want));
    assertShown(p, keep.length, `for the ${want} identity`);
    assert.ok(keep.length > 0, `no endpoint in this map reaches a node in the ${want} identity`);
  }

  p.choose('#ont', '');
  assertShown(p, D.routes.length, 'after clearing the identity');
});

test('choosing a Postgres table opens its derived definition', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const table = drawnTable(D);

  const drawer = p.$('#gschema');
  assert.equal(drawer.hidden, true, 'the drawer is open before anything was selected');
  p.choose('#dep', 'pg.' + table);
  assert.equal(drawer.hidden, false, 'selecting a table left the drawer closed');
  assert.equal(p.text('#gschema .gs-head h4'), table, 'the drawer names another table');
  assert.equal(p.$$('#gschema table tbody tr').length, D.tables[table].columns.length,
    'the drawer shows a different number of columns than the map derived');
  // Every column carries the line it was declared at: that citation is the whole
  // claim the drawer makes.
  for (const tr of p.$$('#gschema table tbody tr')) {
    assert.match(tr.lastElementChild.textContent, /:\d+/, 'a column has no declaration site');
  }
  assert.ok(p.$$('#gschema details').length >= D.tables[table].ddl.length,
    'the DDL statements the definition was read from are not shown');

  const [wide, close] = p.$$('#gschema .gs-head button');
  p.click(wide);
  assert.ok(p.$('#gschema').classList.contains('wide'), 'the expand control did nothing');
  p.click(p.$$('#gschema .gs-head button')[1]);
  assert.equal(p.$('#gschema').hidden, true, 'the close control left the drawer open');
  assert.equal(close.isConnected, false,
    'the close button the drawer was built with is still in the document, so the drawer was hidden rather than rebuilt');

  // Deselecting closes it too, so the drawer never outlives its subject.
  p.choose('#dep', 'pg.' + table);
  assert.equal(p.$('#gschema').hidden, false);
  p.choose('#dep', '');
  assert.equal(p.$('#gschema').hidden, true, 'the drawer outlived the selection');
});

test('clicking a node focuses what it touches, and Escape clears it', t => {
  const p = load({ t });
  const all = p.$$('#gnodes g.gnode');
  const node = p.pickDep();

  p.clickNode(node.g);
  assert.equal(p.peek('state.focus'), node.id, 'the click did not focus the node');
  assert.ok(p.doc.body.classList.contains('focused'), 'the page is not in the focused state');
  assert.ok(p.$('#ginfo').classList.contains('pinned'), 'the detail panel was not pinned');
  assert.match(p.text('#gfocuscount'), /edge/, 'the focus bar does not say what it touches');
  // The focus bar is revealed by `body.focused .gfocus`, not by the script, so the
  // class alone does not prove the reader can see it. jsdom resolves that rule — one
  // of the two places in this suite where a claim leans on the stylesheet.
  assert.equal(p.win.getComputedStyle(p.$('.gfocus')).display, 'flex',
    'the focus bar is still hidden while the page is focused');
  // Focus is subtractive in the picture: everything off this node's own edges is
  // shadowed, and the node and its neighbours are not.
  const shaded = p.$$('#gnodes g.shade').length;
  const neighbours = new Set([node.id]);
  for (const l of node.links) { neighbours.add(l.s.id); neighbours.add(l.t.id); }
  assert.equal(shaded, all.length - neighbours.size, 'the shadow does not match the node’s own edges');
  assert.equal(node.g.classList.contains('shade'), false, 'the focused node is shadowed');

  p.key('Escape');
  assert.equal(p.peek('state.focus'), null, 'Escape did not clear the focus');
  assert.equal(p.$$('#gnodes g.shade').length, 0, 'the shadow survived the focus');
  assert.equal(p.doc.body.classList.contains('focused'), false);
});

test('the focus bar clears the focus too', t => {
  const p = load({ t });
  const node = p.pick(n => n.kind === 'ep', 'endpoint node');
  p.clickNode(node.g);
  assert.equal(p.peek('state.focus'), node.id);
  p.press('#gfocusclear');
  assert.equal(p.peek('state.focus'), null, 'the focus bar’s button did nothing');
});

test('full screen toggles, relabels its own control, and refits', async t => {
  const p = load({ t });
  const graph = p.$('#graph');
  assert.equal(p.text('#gfull'), 'Full screen');

  p.press('#gfull');
  assert.equal(p.doc.fullscreenElement, graph, 'the graph did not become the fullscreen element');
  assert.equal(p.text('#gfull'), 'Exit full screen', 'the control still offers what it just did');
  // Entering is a deliberate reframing, so the page refits on the next frame
  // rather than keeping a zoom chosen for the other size.
  await frame(p);
  assert.ok(Number.isFinite(p.peek('view.k')) && p.peek('view.k') > 0, 'the refit produced no scale');

  p.press('#gfull');
  assert.equal(p.doc.fullscreenElement, null, 'exiting full screen did nothing');
  assert.equal(p.text('#gfull'), 'Full screen');
  await frame(p);
});

test('the code view withholds prose and leaves the drawn topology alone', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const topo = p.text('#topo');
  // Scoped to what the page *shows*: the inventory JSON is embedded in the body,
  // so `body.textContent` contains every description in every view and would make
  // this assertion pass over a page that withheld nothing.
  const shown = () => ['.stage', '#routes', '#edges', '#boundaries'].map(s => p.text(s)).join(' ');

  const described = D.routes.find(r => r.description);
  const labelled = Object.entries(D.labels || {}).find(([, v]) => v)?.[1];
  assert.ok(described && labelled, 'the map carries no prose for the code view to withhold');
  assert.ok(shown().includes(described.description), 'the default view is already withholding prose');

  p.view('code');
  assert.ok(p.doc.body.classList.contains('v-code'), 'the code view did not take');
  assert.equal(shown().includes(described.description), false, 'an endpoint description survived the code view');
  assert.equal(shown().includes(labelled), false, 'a curated node label survived the code view');
  assert.equal(p.$$('.p-p').length, 0, 'prose is still marked, so it is still on the page');
  // Actors and credentials are drawn once at bootstrap and withheld by the
  // stylesheet rather than by `showProse`, so what has to hold for them is that the
  // rule still applies — the one claim in this suite that depends on the CSS. A map
  // with no actors and no credentials has no such section, and this says nothing.
  const sections = p.$$('.prose-section');
  for (const s of sections) {
    assert.equal(p.win.getComputedStyle(s).display, 'none', 'an ungated-prose section is still shown');
  }
  // The node id is not prose — it is the curated identity a gate binds to a
  // symbol — so the code view falls back to it rather than to nothing.
  assert.ok(shown().includes(Object.keys(D.nodes)[0]), 'the code view withheld a node id');
  assert.match(p.text('#withheld'), /node labels/, 'the banner does not say what left');
  assert.equal(p.text('#topo'), topo, 'withholding prose moved the drawn topology');
  assertShown(p, D.routes.length, 'in the code view');

  p.view('all');
  assert.ok(shown().includes(described.description), 'the prose did not come back');
  for (const s of sections) {
    assert.notEqual(p.win.getComputedStyle(s).display, 'none',
      'an ungated-prose section did not come back');
  }
  assert.equal(p.text('#topo'), topo, 'coming back from the code view moved the topology');
});

test('the overlay view marks each curated layer in place', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const topo = p.text('#topo');
  p.view('overlay');
  assert.ok(p.doc.body.classList.contains('v-overlay'));
  // A lens, not a filter: it selects nothing and hides nothing, it colours the
  // page by who is responsible for each fact.
  assert.ok(p.$$('.p-c').length > 0, 'nothing is marked as curated structure');
  assert.ok(p.$$('.p-p').length > 0, 'nothing is marked as prose');
  // The third layer: prose no gate touches at all. Actors and credentials are
  // curated end to end, so they are marked apart from the prose the derived facts
  // anchor — a reader who trusts `p-p` because a route backs it must not read these
  // the same way.
  const ungated = (D.roles || []).length + (D.credentials || []).length;
  assert.equal(p.$$('.p-x').length, ungated,
    'the ungated-prose entries are not each marked as such');
  if (ungated) {
    assert.ok(p.$$('.prose-section .p-x').length > 0, 'the ungated prose is marked outside its own sections');
  } else {
    // Nothing to mark, so the equality above held at zero and said nothing. Both maps
    // this suite runs against declare actors and credentials; a map that declares
    // neither leaves this layer untested rather than silently passing.
    t.diagnostic('this map declares no actors or credentials, so the ungated-prose layer is untested here');
  }
  assert.ok(p.$('#gsvg').classList.contains('prov'), 'the graph does not mark its curated boundaries');
  assert.match(p.text('#glabels'), /curated boundary/, 'the boundaries do not say so about themselves');
  assert.equal(p.text('#topo'), topo, 'marking the curated layers moved the drawn topology');
});

test('a boundary chip filters the endpoints that reach it', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const chip = p.$('#boundaries .chip');
  const dep = chip.title.split(' — ')[0];
  p.click(chip);

  assert.equal(p.peek('state.dep'), dep, 'the chip selected a different dependency');
  assert.equal(p.$('#dep').value, dep, 'the toolbar does not agree with the chip');
  assertShown(p, D.routes.filter(r => r.dependencies.includes(dep)).length, `for ${dep}`);
  assert.match(p.text('#count'), /reaching/, 'the counter does not say what it is counting');
  // The associations table narrows with it, to the same dependency.
  for (const tr of p.$$('#edges tbody tr')) {
    assert.match(tr.children[1].textContent, new RegExp(dep.replace(/\./g, '\\.')));
  }
});

test('a cluster in the key reframes the view onto it', t => {
  const p = load({ t });
  const before = { ...p.peek('view') };
  // The key lists every cluster in order, so the first chip is the first cluster.
  // Pressing it frames that cluster, which is a zoom in unless the cluster is the
  // whole map.
  const members = p.peek('members')[p.peek('clusterIds')[0]];
  p.press('#gkey .ck');
  const after = p.peek('view');
  assert.ok(Number.isFinite(after.x) && Number.isFinite(after.y), 'the reframe produced no translation');
  // Framing part of the map is a zoom in. Framing a cluster that *is* the whole map is
  // a refit, which legitimately lands on the scale the page already had — so the claim
  // is conditioned on the cluster being a proper part rather than asserted outright.
  if (members && members.length < p.peek('GNODES').length) {
    assert.ok(after.k > before.k, 'framing part of the map zoomed out rather than in');
  } else {
    assert.equal(p.peek('clusterIds').length, 1,
      'a cluster holding every node in a map that has more than one cluster is a partition bug');
  }
});

test('a deep link opens the endpoint it names', t => {
  const D = load({ t }).peek('DATA');
  const key = D.routes[0].method + ' ' + D.routes[0].path;
  const p = load({ t, hash: '#' + encodeURIComponent(key) });
  const open = p.$('#routes tbody tr.ep.sel');
  assert.ok(open, 'the endpoint the fragment names is not open');
  assert.equal(open.querySelector('.path').textContent, D.routes[0].path);
  // The row below it is the detail: middleware, gates, and the lines they were
  // read from.
  const detail = p.$('#routes tbody tr .detail');
  assert.ok(detail, 'the open endpoint has no detail row');
  assert.match(detail.textContent, /Middleware/);
  assert.match(detail.textContent, /:\d+/, 'the detail cites no source line');
});

test('clicking an endpoint row opens its detail and focuses it in the graph', t => {
  const p = load({ t });
  const row = p.$('#routes tbody tr.ep');
  const path = row.querySelector('.path').textContent;
  p.click(row);

  assert.ok(p.$('#routes tbody tr .detail'), 'the row did not open');
  assert.ok(String(p.peek('state.focus')).startsWith('ep:'), 'opening a row did not focus its node');
  assert.ok(p.doc.body.classList.contains('focused'), 'the picture did not follow the row');
  p.click(p.$('#routes tbody tr.ep'));
  assert.equal(p.$('#routes tbody tr .detail'), null, 'clicking the open row did not close it');
  assert.equal(p.peek('state.focus'), null, 'closing the row left the focus behind');
  assert.equal(p.$$('#routes tbody tr.ep')[0].querySelector('.path').textContent, path,
    'the table was reordered by opening a row');
});

test('hovering a node answers what reaches it without pinning anything', t => {
  const p = load({ t });
  const node = p.pickDep(1);
  node.g.dispatchEvent(new p.win.Event('pointerenter'));
  assert.equal(p.$('#ginfo').classList.contains('pinned'), false, 'a hover pinned the panel');
  assert.ok(p.$$('#gnodes g.hi').length > 1, 'a hover lit nothing up');
  assert.equal(p.peek('state.focus'), null, 'a hover changed the selection');
  assert.ok(p.$$('#glinks path.hi').length > 0, 'a hover lit no association');
  node.g.dispatchEvent(new p.win.Event('pointerleave'));
  assert.equal(p.$$('#gnodes g.hi').length, 0, 'the highlight outlived the hover');
});

test('every label the page shows is a label the reader can read', t => {
  const p = load({ t });
  // Every boundary is named, and the budget is spent rather than banked: a label
  // pass that quietly stopped drawing would satisfy the no-overlap claim in
  // graph.test.mjs perfectly, so the count is asserted here.
  const units = labelUnits(p);
  const clusters = p.peek('clusterIds').length;
  assert.ok(units.length > clusters,
    `the page placed ${units.length} labels for ${clusters} clusters, so nothing but the boundaries is named`);
  assert.ok(units.some(u => u.kind === 'dep'), 'no state node is named');

  // A group ring narrower than GROUP_LABEL_MIN screen pixels has no room for its own
  // name, so which groups are named is a function of the zoom rather than a constant.
  // Zoom until at least one has earned it, then hold the page to exactly that rule.
  const GROUPS = p.peek('GROUPS');
  const min = p.peek('GROUP_LABEL_MIN');
  const roomy = () => Object.keys(GROUPS).filter(gid => GROUPS[gid].r * p.peek('view.k') >= min);
  for (let i = 0; i < 12 && roomy().length === 0; i++) p.win.zoomBy(1.35);
  assert.ok(roomy().length > 0, 'no group ring is ever wide enough for its own name');
  const named = labelUnits(p).filter(u => u.kind === 'group').map(u => u.id);
  // Room is necessary, not sufficient — a group name still competes for space with
  // everything already placed, and loses rather than overlaps. So: only roomy groups
  // are named, and having room is normally enough.
  for (const gid of named) {
    assert.ok(roomy().includes(gid), `group ${gid} is named on a ring too narrow to hold the name`);
  }
  assert.ok(named.length > 0, `${roomy().length} group rings have room for a name and none is named`);

  // Nothing is placed with an unparseable position, and nothing is left in the
  // document with a position and no text: both are how a label pass silently
  // stops drawing.
  let shown = 0;
  for (const node of p.$$('#glabels text')) {
    if (!visible(node)) continue;
    shown++;
    assert.ok(node.textContent.trim().length > 0, 'a placed label has no text');
    assert.ok(Number.isFinite(Number(node.getAttribute('x'))), 'a placed label has no x');
    assert.ok(Number.isFinite(Number(node.getAttribute('y'))), 'a placed label has no y');
  }
  // Every scored unit is at least one shown text, and a cluster is two of them.
  const scored = labelUnits(p);
  assert.ok(shown >= scored.length, `#glabels shows ${shown} texts for ${scored.length} scored labels`);
});
