// The wiring, executed: the half of the page that answers "in what order, through
// what, and how do these tables relate to each other".
//
// Three claims live here, and each is a picture rather than a sentence, so each is
// scored against the DOM the page built rather than against its source:
//
//   1. an endpoint's wires carry its derived order — numbered on the graph, listed in
//      the panel and in the endpoint table, and the three agree;
//   2. a wire states its indirection — the dash always, the arrowhead where a line is
//      being read — from the generator's vocabulary and not from a second one here;
//   3. a declared foreign key is drawn between two tables the map has dots for, listed
//      whether or not it is drawn, and followable in both directions.
//
// Everything is read out of the embedded inventory, so this file runs unchanged over
// the fixture map the Go driver renders and over the real coordinator map CI points it
// at. Where the fixture is the only map that can exercise a branch, the test says so.

import test from 'node:test';
import assert from 'node:assert/strict';
import { load, visible, touches, drawnTable } from './harness.mjs';
import { assertLabels, labelUnits } from './labels.mjs';

// The vocabularies, read back off the page: KINDS is the order the generator resolves
// a step's kind in, and the glyph/dash tables are how each is drawn. A test that wrote
// them out again would pass while the page and the copy drifted apart.
const vocab = p => ({
  kinds: p.peek('KINDS'),
  dash: p.peek('KIND_DASH'),
  arrow: p.peek('KIND_ARROW'),
  modeColor: p.peek('modeColor'),
  markerID: p.peek('markerID'),
});

// An endpoint the map derived a real order for. Numbering, and the claim that the
// panel and the table state the same order, are vacuous on a one-step flow.
//
// The *widest* flow, not the first that qualifies: the panel's cap, the endpoint
// table's cap, the badge pool and the truncation note are only reached by the endpoint
// that touches the most state, and the first endpoint in graph order is a two-step
// health check. On the real map this is the 57-step handler; on the fixture it is
// whatever the fixture's longest route is, which is why the caps themselves are proved
// against the real map in CI.
function flowNode(p, steps = 2) {
  const eps = [...p.peek('GNODES')].filter(n => n.kind === 'ep' && (n.ep.flow || []).length >= steps);
  assert.ok(eps.length,
    `this map has no endpoint whose derived flow reaches ${steps} constructions, so the test cannot run against it`);
  return eps.reduce((a, b) => (b.ep.flow.length > a.ep.flow.length ? b : a));
}

// Every *other* table that points at one, which is the half of a relationship its own
// CREATE TABLE cannot tell you. A self-reference is excluded on purpose: it is one
// constraint and the table's own declaration already, so counting it inbound as well
// would ask the drawer to print it twice.
const inbound = (D, name) =>
  declaredFks(D).filter(r => r.fk.table === name && r.from !== name);

// The rows of one wiring list, as the page wrote them: each addressed by the
// construction it declares itself to be about, which is the only part of the row that
// is not prose and does not disappear in the code view.
const wiringRows = (p, sel) => p.$$(sel + ' li[data-node]');
const rowNodes = (p, sel) => wiringRows(p, sel).map(li => li.dataset.node);
const txt = (li, sel) => (li.querySelector(sel) || {}).textContent || '';

// An array that came back through `p.peek` belongs to the page's realm, and
// `deepStrictEqual` compares prototypes — so two identical lists, one from the page
// and one built here, are not equal to it. Comparing them as text is what makes a
// cross-realm list assertable, and it prints the same way when it fails.
const list = xs => [...xs].join(' | ');

// What the page's own step index says about one (endpoint, construction) pair.
const stepOf = (r, dep) => (r.flow || []).find(s => s.node === dep);

// Every foreign key the inventory declares, in the order the page lists them: by
// table, and within a table in declaration order.
function declaredFks(D) {
  const out = [];
  for (const name of Object.keys(D.tables || {}).sort()) {
    for (const fk of D.tables[name].foreignKeys || []) out.push({ from: name, fk });
  }
  return out;
}

test('the indirection legend is the generator\'s vocabulary, drawn as the graph draws it', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const v = vocab(p);
  const legend = D.stepKindLegend || {};
  assert.ok(Object.keys(legend).length > 0, 'the artifact carries no indirection legend');

  // One entry per kind the generator explains, in the generator's order — weakest
  // indirection first, which is the order it resolves a step's kind in.
  const want = v.kinds.filter(k => legend[k]);
  const entries = p.$$('#kinds > div');
  assert.equal(entries.length, want.length,
    `the legend has ${entries.length} entries for ${want.length} explained kinds`);
  want.forEach((k, i) => {
    const d = entries[i];
    // The sentence is the generator's, verbatim: a kind it adds has to arrive on the
    // page as an explanation rather than as a bare glyph.
    assert.ok(d.textContent.includes(legend[k]),
      `the legend entry for ${k} does not carry the generator's sentence`);
    assert.equal(txt(d, '.kind'), v.arrow[k], `the ${k} entry draws the wrong glyph`);
    const wire = d.querySelector('svg.kwire path');
    assert.ok(wire, `the ${k} entry draws no wire`);
    assert.equal(wire.getAttribute('stroke-dasharray'), v.dash[k] || 'none',
      `the ${k} entry's wire is not dashed the way the graph dashes it`);
    // And the head on it is a marker that exists: an `url(#…)` at a missing id paints
    // nothing, which is a legend with a line and no arrow on it. The legend's family is
    // the fixed-size one — see the zoom test — so the id it points at says so.
    const id = v.markerID(k, 'RW', true);
    assert.equal(wire.getAttribute('marker-end'), 'url(#' + id + ')');
    assert.ok(p.$('#gdefs #' + id), `the legend points at marker ${id}, which the page never defined`);
  });

  // Nothing in the picture is left unexplained: every kind any wire or any step
  // carries is one the legend has a sentence for.
  const used = new Set(p.peek('GLINKS').map(l => l.kind));
  for (const r of D.routes) for (const s of r.flow || []) used.add(s.kind || 'direct');
  for (const k of used) {
    assert.ok(legend[k], `wires are drawn as ${k}, which the legend does not explain`);
  }
});

test('every wire is drawn with the dash and colour of its own step', t => {
  const p = load({ t });
  const v = vocab(p);
  const seen = new Set();
  for (const l of p.peek('GLINKS')) {
    seen.add(l.kind);
    assert.ok(v.kinds.includes(l.kind),
      `${l.s.id} → ${l.t.id} is drawn as ${l.kind}, which is not one of the generator's kinds`);
    assert.ok(l.node.classList.contains('k-' + l.kind),
      `${l.s.id} → ${l.t.id} carries no k-${l.kind} class`);
    const dash = v.dash[l.kind];
    assert.equal(l.node.getAttribute('stroke-dasharray'), dash ? dash : null,
      `${l.s.id} → ${l.t.id} (${l.kind}) is dashed ${l.node.getAttribute('stroke-dasharray')}`);
    // The colour is the other half of what a wire says: what the endpoint does to the
    // state, as opposed to how it reaches it.
    assert.equal(l.node.getAttribute('stroke'), v.modeColor[l.mode] || 'var(--dim)',
      `${l.s.id} → ${l.t.id} is not drawn in its access mode's colour`);
    // The dash is a property of the wire, not of a hover: it is drawn from the start.
    assert.equal(l.kind === 'direct', !l.node.getAttribute('stroke-dasharray'),
      `only a direct call is drawn unbroken; ${l.s.id} → ${l.t.id} is ${l.kind}`);
  }
  assert.ok(seen.size > 1,
    `every wire in this map is ${[...seen][0]}, so "the dash is the kind" is untested here`);
});

test('arrowheads state a wire\'s kind and mode, and follow the page\'s own rule about when', t => {
  const p = load({ t });
  const v = vocab(p);
  const heads = () => [...p.peek('GLINKS')].filter(l => l.node.getAttribute('marker-end'));
  // Both branches of the rule, forced from the toolbar rather than inferred, so the
  // fixture map and the real one test the same two things. `read` is the crowded map's
  // branch — heads only where a line is actually being read, because 857 of them at once
  // is a smear — and `all` is every live wire, which is what `auto` resolves to as soon
  // as a filter, a focus or a close zoom has narrowed the picture.
  const arrows = mode => {
    for (let i = 0; i < 3 && p.peek('state.arrows') !== mode; i++) p.press('#garrows');
    assert.equal(p.peek('state.arrows'), mode, 'the arrow toggle does not reach ' + mode);
    assert.equal(p.$('#garrows').textContent, '↦ ' + mode, 'the toggle does not say which rule is in force');
  };

  arrows('read');
  const noHeads = where => assert.equal(list(heads().map(l => l.s.id + ' → ' + l.t.id)), '',
    `wires carry arrowheads ${where}`);
  noHeads('with nothing hovered or focused');

  const node = p.pickDep(1);
  node.g.dispatchEvent(new p.win.Event('pointerenter'));
  const lit = heads();
  assert.equal(lit.length, node.links.length,
    `hovering ${node.id} put heads on ${lit.length} of its ${node.links.length} wires`);
  for (const l of lit) {
    assert.ok(l.s === node || l.t === node, `hovering ${node.id} put a head on ${l.s.id} → ${l.t.id}`);
    const id = v.markerID(l.kind, l.mode);
    assert.equal(l.node.getAttribute('marker-end'), 'url(#' + id + ')',
      `${l.s.id} → ${l.t.id} points with the wrong head`);
    assert.ok(p.$('#gdefs #' + id), `the wire points at marker ${id}, which the page never defined`);
  }
  node.g.dispatchEvent(new p.win.Event('pointerleave'));
  noHeads('after the hover ended');

  // A focus is the other way a line gets read, and it holds: the focused node's own
  // wires keep their heads, and nothing else acquires one.
  const ep = flowNode(p, 1);
  p.clickNode(ep.g);
  const onFocus = heads();
  assert.ok(onFocus.length > 0, 'focusing an endpoint pointed none of its wires');
  for (const l of onFocus) {
    assert.ok(l.s === ep || l.t === ep,
      `focusing ${ep.id} put a head on the unrelated wire ${l.s.id} → ${l.t.id}`);
  }
  p.key('Escape');
  noHeads('after the focus was cleared');

  // And the other branch: every wire that is on the picture is pointed, and every one
  // that is not stays unpointed — a head on a muted wire would be an arrow into a part
  // of the map the reader filtered away.
  arrows('all');
  const live = [...p.peek('GLINKS')].filter(l => l.live);
  assert.ok(live.length > 1, 'this map draws no live wires, so "every wire is pointed" is vacuous');
  assert.equal(list(heads().map(l => l.s.id + ' → ' + l.t.id).sort()),
    list(live.map(l => l.s.id + ' → ' + l.t.id).sort()),
    'the pointed wires are not the live ones');
  for (const l of live) {
    assert.equal(l.node.getAttribute('marker-end'), 'url(#' + v.markerID(l.kind, l.mode) + ')',
      `${l.s.id} → ${l.t.id} points with the wrong head`);
  }
  // Even `all` stops at the shadow: a focus is a claim that everything off this node's
  // edges is not the answer, and heads over the shaded rest of the map is the noise the
  // focus was asked to remove.
  p.clickNode(ep.g);
  const focused = heads();
  assert.ok(focused.length > 0, 'focusing an endpoint with arrows forced on pointed nothing');
  for (const l of focused) {
    assert.ok(l.s === ep || l.t === ep,
      `with arrows forced on, focusing ${ep.id} still pointed the shaded wire ${l.s.id} → ${l.t.id}`);
  }
  p.key('Escape');
  // Back to the shipped default, and `auto` is held to its own rule rather than to a
  // number: on a map small enough to carry them it is `all`, and on one that is not it is
  // `read`. Both maps this file runs over therefore check the branch they are. The real
  // coordinator map is the one where the budget binds — 857 wires at the fitted zoom —
  // and the fixture is the one where it does not, so between them the rule is covered in
  // both directions.
  arrows('auto');
  const budget = p.peek('ARROW_ALL_MAX'), zoom = p.peek('ARROW_ALL_ZOOM');
  const narrow = live.length <= budget || p.peek('view.k') >= zoom;
  assert.equal(heads().length, narrow ? live.length : 0,
    `${live.length} live wires at zoom ${p.peek('view.k').toFixed(2)} (budget ${budget}, ` +
    `zoom ${zoom}) should carry ${narrow ? 'a head each' : 'none until read'}`);
});

// The bug this test exists for: a marker on a path inside the scaled scene is measured in
// scene units, so the heads were 8 units wide and the coordinator map fits at k≈0.43 —
// three screen pixels with a half-pixel outline. They were drawn, correctly, and could
// not be seen. The claim is therefore about screen size and has to hold at every zoom.
test('an arrowhead is the same size on screen at every zoom, and the legend\'s does not move', t => {
  const p = load({ t });
  const px = p.peek('ARROW_PX'), fkpx = p.peek('FK_ARROW_PX');
  const markers = p.peek('SCENE_MARKERS.map(m => ({ id: m.node.id, w: m.px.w, h: m.px.h }))');
  assert.ok(markers.length > 4, 'the page defines no scene arrowheads');
  const onScreen = () => {
    const k = p.peek('view.k');
    return markers.map(m => {
      const node = p.$('#gdefs #' + m.id);
      return { id: m.id, want: m,
        w: +node.getAttribute('markerWidth') * k, h: +node.getAttribute('markerHeight') * k };
    });
  };
  const check = where => {
    for (const m of onScreen()) {
      // A quarter of a pixel of rounding is the two-decimal attribute, not a policy.
      assert.ok(Math.abs(m.w - m.want.w) < 0.25 && Math.abs(m.h - m.want.h) < 0.25,
        `${m.id} is ${m.w.toFixed(2)}x${m.h.toFixed(2)} screen px ${where}, not ${m.want.w}x${m.want.h}`);
    }
  };
  check('at the fitted zoom');
  const fitted = p.peek('view.k');
  p.win.zoomBy(4);
  assert.ok(p.peek('view.k') > fitted, 'zooming in did not change the scale');
  check('zoomed in');
  p.win.zoomBy(1 / 32);
  assert.ok(p.peek('view.k') < fitted, 'zooming out did not change the scale');
  check('zoomed out');
  p.press('.gbar button[data-z=fit]');

  // Every kind is pointed in both families, and the legend's is the fixed one: its sample
  // wires are unscaled SVG, so a head sized against the graph's zoom would make the key
  // grow when the reader zooms out of a picture whose heads did not change.
  for (const k of p.peek('KINDS')) {
    const fixed = p.$('#gdefs #' + p.peek('markerID')(k, p.peek('LEGEND_MODE'), true));
    assert.ok(fixed, `no fixed-size head is defined for ${k}`);
    assert.equal(+fixed.getAttribute('markerWidth'), px.w, `the legend's ${k} head is the wrong size`);
  }
  assert.ok(fkpx.w > 0 && fkpx.w < px.w, 'a foreign key should be pointed more quietly than an access');

  // Every head fits inside its viewBox with room for its own outline. A 1px stroke
  // straddles the path, so a box tight to the ink clips half a stroke off the outermost
  // point of it — which jsdom cannot show and a browser draws as a blunted barb or a
  // diamond with its corners sliced off. The margin is checked here rather than looked at.
  const [vx, vy, vw, vh] = p.peek('ARROW_VIEW').split(' ').map(Number);
  for (const m of markers) {
    const d = p.$('#gdefs #' + m.id).querySelector('path').getAttribute('d');
    const n = d.match(/[\d.]+/g).map(Number);
    for (let i = 0; i < n.length; i += 2) {
      assert.ok(n[i] - 0.5 >= vx && n[i] + 0.5 <= vx + vw &&
        n[i + 1] - 0.5 >= vy && n[i + 1] + 0.5 <= vy + vh,
        `${m.id} draws (${n[i]}, ${n[i + 1]}), whose outline leaves the viewBox ` +
        `${p.peek('ARROW_VIEW')} — it will be clipped`);
    }
  }
});

test('focusing an endpoint numbers its wires in the order the request meets them', t => {
  const p = load({ t });
  const v = vocab(p);
  const badges = () => p.$$('#glabels text.gseq').filter(visible);
  const numbers = () => list(badges().map(n => n.textContent));
  assert.equal(numbers(), '', 'wires are numbered with nothing focused');

  const ep = flowNode(p);
  p.clickNode(ep.g);
  const numbered = [...p.peek('seqLinks()')];
  assert.ok(numbered.length > 1,
    `focusing ${ep.id} numbered ${numbered.length} wires, which is not an order`);
  // The order is the derived one: the sequence the generator recorded, ascending, and
  // restricted to the wires actually on the picture.
  const seqs = numbered.map(l => l.seq);
  assert.equal(list(seqs), list([...seqs].sort((a, b) => a - b)),
    'the numbered wires are not in the order the request meets them');
  for (const l of numbered) {
    assert.equal(l.seq, stepOf(ep.ep, l.t.dep).seq,
      `the wire to ${l.t.dep} is numbered ${l.seq}, not its step's own sequence`);
  }

  // Each badge carries its step's number and its wire's access-mode colour. Where it
  // sits is `assertLabels`' business — it now scores a badge against the midpoint of
  // the wire it belongs to — and this is what is written in it.
  const shown = badges();
  assert.ok(shown.length > 0, 'the focused endpoint drew no numbers at all');
  const pool = p.peek('SEQ_POOL');
  numbered.forEach((l, i) => {
    assert.equal(pool[i].textContent, String(l.seq),
      `the badge on the wire to ${l.t.dep} reads ${pool[i].textContent}`);
    assert.equal(pool[i].getAttribute('fill'), v.modeColor[l.mode] || 'var(--dim)',
      `the badge on the wire to ${l.t.dep} is not in its wire's colour`);
  });
  assert.ok(labelUnits(p).some(u => u.kind === 'seq'),
    'the label scorer found no badge to score');
  assertLabels(p, 'with an endpoint focused');

  // Numbers answer a question the click asked, so they go when it is withdrawn — and
  // the pool that held them must not leave a stale number behind.
  p.key('Escape');
  assert.equal(numbers(), '', 'the numbers outlived the focus');
  assertLabels(p, 'after clearing the focus');

  // A construction is not a request, so it has no order to state: only an endpoint
  // numbers anything.
  p.clickNode(p.pickDep(1).g);
  assert.equal(numbers(), '', 'focusing a construction numbered something');
});

// The ladder, as a claim about what a reader can read rather than about the code that
// produced it. A single position per badge satisfies every other test in this file —
// every number is on its own midpoint, nothing overlaps, nothing is off frame — and
// still hands the widest handler in the coordinator the numbering `3, 5, 7, 9, 10, 32,
// 36, 56`, which a reader cannot tell apart from a flow that skips steps. So the thing
// to assert is the prefix: whatever the picture has to drop, it drops from the end.
//
// The bound is `min(4, total)` rather than a ratio because a ratio is a statement about
// one map's crowding. Four is out of reach for a single-rung page on any endpoint whose
// midpoints collide at all — and on a small flow, where nothing collides, the stronger
// claim applies and every number is expected.
test('a flow keeps a readable prefix of its numbers, however crowded its midpoints are', t => {
  const p = load({ t });
  // The crowded end and the quiet end of the same map: the widest flow is where the
  // ladder is doing all its work, and the narrowest is where the stronger claim below
  // bites — a handful of midpoints that cannot collide must all keep their number.
  const eps = [...p.peek('GNODES')].filter(n => n.kind === 'ep' && (n.ep.flow || []).length);
  const narrowest = eps.reduce((a, b) => (b.ep.flow.length < a.ep.flow.length ? b : a));
  for (const ep of [flowNode(p), narrowest]) {
    p.clickNode(ep.g);
    const total = p.peek('seqLinks()').length;
    const pool = p.peek('SEQ_POOL');
    const shown = pool.slice(0, total).filter(visible).map(n => Number(n.textContent));
    shown.sort((a, b) => a - b);
    let run = 0;
    while (shown[run] === run + 1) run++;
    const want = Math.min(4, total);
    assert.ok(run >= want, `focusing ${ep.id} numbered ${total} wires and shows ` +
      `[${shown.join(',')}] — the first ${want} steps are not all readable, so a reader ` +
      'cannot tell a dropped number from a step the endpoint does not take');
    if (total <= 3) {
      assert.equal(shown.length, total,
        `${ep.id} has only ${total} numbered wires and dropped one of them`);
    }
    assertLabels(p, `with ${ep.id} focused`);
    p.key('Escape');
  }
});

test('the numbers follow their wires through a zoom, a pan and a drag', t => {
  const p = load({ t });
  const ep = flowNode(p);
  p.clickNode(ep.g);
  const at = () => p.$$('#glabels text.gseq').filter(visible)
    .map(n => n.getAttribute('x') + ',' + n.getAttribute('y')).join(';');
  const before = at();
  assert.ok(before, 'the focused endpoint drew no numbers');

  // Each of these moves the midpoints the badges are placed on, so a pass that
  // stopped running would leave every number where it was — which is what
  // `assertLabels` catches, since it asks where each one *should* be.
  for (const factor of [1 / 1.35, 1.35 * 1.35]) {
    p.win.zoomBy(factor);
    assertLabels(p, `with an endpoint focused at zoom ${p.peek('view.k').toFixed(2)}`);
  }
  assert.notEqual(at(), before, 'zooming did not move the numbers');
  p.win.eval('fit()');
  assertLabels(p, 'refitted with an endpoint focused');

  // Dragging a numbered wire's target moves one midpoint and no others.
  const target = p.peek('seqLinks()')[0].t;
  p.win.eval(`(() => { const n = gById[${JSON.stringify(target.id)}];
    n.x += 40; n.y -= 25; positionGraph(); placeLabels(); })()`);
  assertLabels(p, 'after moving a numbered wire\'s construction');
});

test('the pinned panel lists the derived order, with the indirection and what it is read from', t => {
  const p = load({ t });
  const ep = flowNode(p);
  const legend = p.peek('DATA').stepKindLegend || {};
  const v = vocab(p);
  p.clickNode(ep.g);
  assert.ok(p.$('#ginfo').classList.contains('pinned'), 'clicking the endpoint did not pin the panel');

  const cap = p.peek('PANEL_CAP');
  const flow = ep.ep.flow;
  const rows = wiringRows(p, '#ginfo ol.wiring');
  assert.equal(rows.length, Math.min(flow.length, cap),
    `the panel listed ${rows.length} of ${flow.length} constructions`);
  assert.equal(list(rowNodes(p, '#ginfo ol.wiring')), list(flow.slice(0, cap).map(s => s.node)),
    'the panel is not in wiring order');
  // The sequence numbers are drawn as text and the browser's markers are turned off, and
  // a list with no markers stops being a list in WebKit — so the role is stated.
  assert.equal(p.$('#ginfo ol.wiring').getAttribute('role'), 'list',
    'the wiring list is styled out of its own list semantics without restoring them');
  if (flow.length > cap) {
    assert.match(p.text('#ginfo ol.wiring li:last-child'), /^\+\d+ more$/,
      'the panel dropped the rest of the flow without saying so');
  }

  rows.forEach((li, i) => {
    const s = flow[i];
    const kind = s.kind || 'direct';
    assert.equal(txt(li, '.seqn'), String(s.seq), `row ${i + 1} states the wrong sequence`);
    assert.equal(txt(li, '.badge'), s.mode, `row ${i + 1} states the wrong access mode`);
    const arrow = li.querySelector('.kind');
    assert.equal(arrow.textContent, v.arrow[kind], `row ${i + 1} draws the wrong indirection glyph`);
    assert.ok(arrow.classList.contains('k-' + kind), `row ${i + 1} carries no k-${kind} class`);
    // The glyph is a symbol, so the sentence behind it is the generator's own.
    const why = legend[kind] || '';
    assert.ok(arrow.title.startsWith(why), `row ${i + 1}'s glyph explains itself differently`);
    // And the glyph is a picture, so the kind is stated again in text that only assistive
    // tech reads: `title` is a hover affordance, which leaves a screen reader with an
    // arrow character as the row's only account of how the endpoint reaches this state.
    assert.equal(txt(li, '.sronly').trim(), p.peek('KIND_LABEL')[kind] || kind,
      `row ${i + 1} states its indirection as a glyph and nothing else`);

    // Touches count source sites and not executions, and a loop is the one place one
    // site is known to run more than once — so the row says which it is saying.
    const notes = txt(li, '.desc');
    if (s.touches > 1) assert.match(notes, new RegExp('\\b' + s.touches + ' sites\\b'), `row ${i + 1} hides its ${s.touches} touch sites`);
    else assert.doesNotMatch(notes, /\bsites\b/, `row ${i + 1} claims several sites for a single touch`);
    assert.equal(/in a loop/.test(notes), !!s.repeats, `row ${i + 1} disagrees about being in a loop`);
    // A floor and not a census — the walk keeps one path per frame — so the row must
    // not print the number as if it were the whole count.
    if (s.wireCount > 1) {
      assert.match(notes, new RegExp('at least ' + s.wireCount + ' paths\\b'),
        `row ${i + 1} states its ${s.wireCount} call paths as a total`);
    }
    // The glyph is the strongest indirection anywhere on the step; the path printed
    // under it belongs to the earliest touch. Where those differ the row has to say so
    // in both places, or it reads as a sentence about unwinding beside a wire that does
    // not unwind.
    if (s.leadKind) {
      const lead = p.peek('KIND_LABEL')[s.leadKind] || s.leadKind;
      assert.match(notes, new RegExp('first touch ' + lead),
        `row ${i + 1} prints a ${kind} glyph over a ${lead} path without saying so`);
      assert.ok(arrow.title.includes(lead) && arrow.title !== why,
        `row ${i + 1}'s glyph does not explain that its path is a ${lead}`);
    } else {
      assert.equal(arrow.title, why, `row ${i + 1}'s glyph explains a lead kind it does not have`);
      assert.doesNotMatch(notes, /first touch/, `row ${i + 1} names a lead kind the step does not publish`);
    }
    // Dispatch is off the timing ladder, so it is stated where the glyph does not
    // already state it and nowhere else.
    assert.equal(/through an interface/.test(notes), !!s.iface && kind !== 'interface',
      `row ${i + 1} disagrees about being dispatched through an interface`);
    if (s.depth) assert.match(notes, new RegExp('depth ' + s.depth + '\\b'), `row ${i + 1} hides its depth`);

    // The pinned panel is where the call path itself is shown, one frame per hop.
    if ((s.wires || []).length) {
      const wire = li.querySelector('.wire');
      assert.ok(wire, `row ${i + 1} shows no call path`);
      const full = s.wires[0].map(j => p.peek('DATA').symbols[j]);
      assert.equal(wire.title, full.join('\n'), `row ${i + 1}'s call path is not the derived one`);
      assert.equal(wire.textContent.split(' → ').length, full.length,
        `row ${i + 1} draws ${wire.textContent} for a ${full.length}-frame path`);
      assert.ok(full[full.length - 1].endsWith(wire.textContent.split(' → ').pop()),
        `row ${i + 1}'s path does not end at ${full[full.length - 1]}`);
    }
  });

  // A hover is a preview, so it lists the same order and stops sooner.
  p.key('Escape');
  ep.g.dispatchEvent(new p.win.Event('pointerenter'));
  const preview = rowNodes(p, '#ginfo ol.wiring');
  assert.equal(list(preview), list(flow.slice(0, preview.length).map(s => s.node)),
    'the hover preview lists a different order from the pinned panel');
  assert.ok(preview.length <= 8, `the hover preview listed ${preview.length} rows`);
  assert.equal(p.$('#ginfo ol.wiring .wire'), null,
    'the hover preview spends its room on call paths');
});

test('the endpoint table states the same wiring as the panel, and cites it', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const ep = flowNode(p);
  // Open the row for that endpoint through the table, the way a reader does.
  const row = p.$$('#routes tbody tr.ep')
    .find(tr => tr.querySelector('.path').textContent === ep.ep.path &&
      tr.children[0].textContent === ep.ep.method);
  assert.ok(row, `the route table has no row for ${ep.name}`);
  p.click(row);

  const dl = [...p.$$('#routes tbody tr .detail dt')].find(d => d.textContent === 'Wiring');
  assert.ok(dl, 'the open endpoint states no wiring');
  assert.ok(dl.nextElementSibling.querySelector('ol.wiring'), 'the wiring entry holds no ordered list');
  const table = rowNodes(p, '#routes tbody tr .detail ol.wiring');
  assert.equal(list(table), list(ep.ep.flow.slice(0, 12).map(s => s.node)),
    'the endpoint table is not in wiring order');

  // The table is where the lines each touch was read off are named, which is what makes
  // the order checkable against the source rather than merely stated.
  let cited = 0;
  wiringRows(p, '#routes tbody tr .detail ol.wiring').forEach((li, i) => {
    const s = ep.ep.flow[i];
    const links = [...li.querySelectorAll('a.mono, span.k.mono')]
      .map(a => a.textContent).filter(x => x.includes('.go:'));
    if (!(s.sites || []).length) return;
    cited++;
    assert.equal(list(links), list([...s.sites].map(j => D.sites[j])),
      `row ${i + 1} cites lines that are not its step's`);
  });
  assert.ok(cited > 0, 'no row in the endpoint table cites a source line');

  // The same claim the panel makes, from the same builder: a reader comparing the two
  // must not find two answers. The table caps at 12 and the panel at PANEL_CAP, so the
  // shorter list is the one they are compared over. Opening the row already focused the
  // dot — the selection is one state, not two, which is why the panel is readable here
  // without touching the graph.
  assert.equal(p.peek('state.focus'), 'ep:' + ep.ep.id, 'opening the row did not focus the endpoint');
  const panel = rowNodes(p, '#ginfo ol.wiring');
  const n = Math.min(panel.length, table.length);
  assert.ok(n > 0, 'one of the two wiring lists is empty, so they were not compared');
  assert.equal(list(table.slice(0, n)), list(panel.slice(0, n)),
    'the endpoint table and the graph panel disagree about the wiring order');
});

test('a foreign key is drawn between two tables the map has dots for', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const links = D.tableLinks || [];
  const drawable = links.filter(l => D.nodes[l.from] && D.nodes[l.to]);
  const arcs = p.$$('#gfks > path');
  assert.equal(arcs.length, drawable.length,
    `${arcs.length} arcs drawn for ${drawable.length} keys between drawn tables`);
  assert.ok(arcs.length > 0, 'this map draws no foreign key at all, so nothing here is tested');

  const gById = p.peek('gById');
  p.peek('FKLINKS').forEach((l, i) => {
    const d = l.node.getAttribute('d');
    assert.ok(touches(d, l.s) && touches(d, l.t),
      `the key ${l.fk.from} → ${l.fk.to} is not drawn between its two tables: ${d}`);
    // The head is on the referenced table: the arrow points the way the reference
    // does, from the row that carries the column to the row it must exist in.
    assert.equal(l.node.getAttribute('marker-end'), 'url(#a-fk)');
    assert.ok(p.$('#gdefs #a-fk'), 'the key points at a marker the page never defined');
    assert.equal(txt(l.node, 'title'), p.peek('fkSentence')(l.fk),
      'the key\'s tooltip is not its own sentence');
    // The link names node ids; the graph keys its dots by kind, so a key between two
    // tables is an arc between those tables' own dots and no others.
    assert.ok(gById['dep:' + l.fk.from] === l.s && gById['dep:' + l.fk.to] === l.t,
      `the arc for ${l.fk.from} → ${l.fk.to} is drawn between ${l.s.id} and ${l.t.id}`);
  });

  // Two keys drawn on the same curve are one visible arc with one reachable tooltip, so
  // the second of a pair is bowed further out. Every map so far has one key per pair,
  // which makes this the guard rather than the demonstration.
  const curves = p.peek('FKLINKS').map(l => l.node.getAttribute('d'));
  assert.equal(new Set(curves).size, curves.length,
    'two foreign keys are drawn along the same curve, so one of them cannot be read or hovered');

  // A key is a fact about the schema, so it takes no part in what the picture claims
  // the endpoints do: no `data-topo`, and not one of the associations.
  assert.equal(p.$$('#gfks > path[data-topo]').length, 0,
    'a foreign key was counted into the drawn topology');
  assert.equal(p.$$('#glinks path.fklink').length, 0,
    'a foreign key was drawn among the associations');
  const arc = p.$('#gfks > path');
  const before = p.text('#topo');
  arc.remove();
  assert.equal(p.peek('topoFingerprint()'), before,
    'removing a foreign key changed the drawn topology');
});

test('the relationship table lists every declared key, drawn or not, and filters with the page', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const all = declaredFks(D);
  const rows = () => p.$$('#fks tbody tr');
  assert.equal(rows().length, all.length, 'the relationship table is not the declared set');
  assert.ok(all.length > 0, 'this map declares no foreign key, so nothing here is tested');
  assert.equal(p.$('#nofks').hidden, true, 'the empty state is showing over a full table');

  rows().forEach((tr, i) => {
    const { from, fk } = all[i];
    const cells = [...tr.children].map(td => td.textContent);
    assert.equal(cells[0], from, `row ${i + 1} names the wrong table`);
    assert.equal(cells[1], (fk.columns || []).join(', '), `row ${i + 1} names the wrong columns`);
    assert.ok(cells[2].startsWith(fk.table), `row ${i + 1} points at the wrong table`);
    // NO ACTION is the database's default, and the page says so rather than printing a
    // clause the DDL does not contain.
    assert.equal(cells[3], fk.onDelete || 'NO ACTION (default)',
      `row ${i + 1} states the wrong referential action`);
    assert.ok(cells[4].includes(fk.site), `row ${i + 1} does not cite where it was read`);
    if (fk.onUpdate) assert.ok(cells[4].includes('ON UPDATE ' + fk.onUpdate));
  });

  // It lists the keys the graph cannot draw as well, and there are two ways a key can
  // be one: a table nothing reachable reads has no dot, so there is nothing to draw the
  // key between; and a self-reference is one node rather than an edge between two. Both
  // are relationships the schema really has, so both are in this table.
  const undrawable = all.filter(r => r.from === r.fk.table ||
    !D.nodes['pg.' + r.from] || !D.nodes['pg.' + r.fk.table]);
  assert.equal(rows().length - undrawable.length, p.$$('#gfks > path').length,
    'the table and the picture disagree about how many keys can be drawn');

  // The page's filters reach it, because a reader who narrowed to one table is asking
  // about that table's relationships too.
  const chosen = all.find(r => D.nodes['pg.' + r.from]);
  assert.ok(chosen, 'no declared key is on a table the graph draws');
  p.choose('#dep', 'pg.' + chosen.from);
  const kept = rows().map(tr => tr.children[0].textContent + '.' + tr.children[1].textContent);
  const want = all.filter(r => 'pg.' + r.from === 'pg.' + chosen.from || 'pg.' + r.fk.table === 'pg.' + chosen.from)
    .map(r => r.from + '.' + (r.fk.columns || []).join(', '));
  assert.deepEqual(kept, want, `choosing ${chosen.from} left the wrong keys`);

  p.press('#reset');
  assert.equal(rows().length, all.length, 'reset did not put the relationship table back');

  // And a filter that matches nothing says so in its own words, rather than by showing
  // an empty table with no explanation.
  p.type('#q', 'zzzznotatable');
  assert.equal(rows().length, 0);
  const none = p.$('#nofks');
  assert.equal(none.hidden, false, 'the empty state stayed hidden over an empty table');
  assert.match(none.textContent, /matches these filters/,
    'the empty state does not say the filters are why');
});

test('a table\'s definition states its keys in both directions, and follows them', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  // A table with keys, and drawn so the definition can be opened by selecting it. The
  // first drawn table of the real map declares none, and every assertion below is
  // vacuous on it.
  const name = drawnTable(D, n => (D.tables[n].foreignKeys || []).length > 0 || inbound(D, n).length > 0);
  p.choose('#dep', D.tables[name].node);
  assert.equal(p.peek('state.table'), D.tables[name].node, 'choosing a table did not open its definition');

  const outgoing = D.tables[name].foreignKeys || [];
  const incoming = inbound(D, name);
  const box = [...p.$$('#gschema details')]
    .find(d => (d.querySelector('summary') || {}).textContent.startsWith('Foreign keys'));
  assert.ok(box, `${name}'s definition states none of its ${outgoing.length + incoming.length} keys`);
  // Both directions, because the incoming half is the one a CREATE TABLE cannot tell
  // you and the half that says what a delete here costs.
  assert.equal(box.querySelector('summary').textContent,
    'Foreign keys · ' + outgoing.length + ' declared here, ' + incoming.length + ' pointing here');
  const items = p.$$('#gschema ul.fklist li');
  assert.equal(items.length, outgoing.length + incoming.length,
    'the drawer lists a different number of keys than its own summary');
  for (const li of items) {
    assert.match(li.textContent, /\(.+\) → /, `a key line does not name the columns: ${li.textContent}`);
    assert.match(li.textContent, /\.go:\d+/, `a key line does not cite where it was read: ${li.textContent}`);
  }
  // The table being looked at is plain text and the other one is a link: a key is only
  // useful if you can follow it. A self-reference names one table twice, so it offers
  // nothing to follow — which is the right answer rather than a missing link — and the
  // lines are in the order the drawer appends them, its own declarations first.
  const pairs = [...outgoing.map(fk => [name, fk.table]), ...incoming.map(r => [r.from, name])];
  items.forEach((li, i) => {
    const [from, to] = pairs[i];
    assert.equal(li.querySelectorAll('.lk').length, from === to ? 0 : 1,
      `the line for ${from} → ${to} offers the wrong number of tables to follow: ${li.textContent}`);
  });

  // Following one to a table the graph draws moves the whole selection, which is what a
  // click means everywhere else on this page.
  const away = [...items].find(li => {
    const lk = li.querySelector('.lk');
    return lk && D.nodes['pg.' + lk.textContent];
  });
  if (away) {
    const to = away.querySelector('.lk').textContent;
    p.click(away.querySelector('.lk'));
    assert.equal(p.peek('state.focus'), 'dep:pg.' + to, `following ${to} did not focus it`);
    assert.equal(p.peek('state.table'), 'pg.' + to, `following ${to} did not open its definition`);
    // And following it *back* opens the table it came from rather than closing the
    // drawer: the selection toggles everywhere else on the page, and a relationship
    // followed in two clicks must not end on an empty panel.
    const back = [...p.$$('#gschema ul.fklist li .lk')].find(lk => lk.textContent === name);
    if (back) {
      p.click(back);
      assert.equal(p.peek('state.table'), D.tables[name].node,
        `following ${to} → ${name} closed the drawer instead of opening it`);
      assert.equal(p.peek('state.dep'), D.tables[name].node,
        `following ${to} → ${name} left the selection on ${to}`);
    }
  } else {
    assert.ok(items.length > 0,
      'no key on this table points at another drawn table, so following one rests on the other map');
  }

  // A table with no relationship in either direction says so, rather than leaving the
  // section out — absent and "none declared" are opposite claims about the derivation.
  const bare = Object.keys(D.tables || {}).find(n =>
    !(D.tables[n].foreignKeys || []).length && !inbound(D, n).length);
  if (bare) {
    p.win.eval(`clearFocus(); openTable(${JSON.stringify(bare)})`);
    assert.equal([...p.$$('#gschema details')]
      .find(d => (d.querySelector('summary') || {}).textContent.startsWith('Foreign keys')), undefined,
      `${bare} declares no key, so the drawer must not open a list for it`);
    assert.match(p.text('#gschema'), /none declared in either direction/,
      `${bare} has no relationship, and the drawer does not say so`);
  }

  // A table nothing reachable reads has no dot to focus, so the drawer opens on its
  // own. Only a map with such a table exercises that path.
  const orphan = Object.keys(D.tables || {}).find(n => !D.nodes['pg.' + n]);
  if (orphan) {
    // Focused on a drawn table first, so that "the focus was cleared" is a claim about
    // what following the reference did rather than about where the page happened to
    // start: a focus left pinned to the table the reader came from goes on shading the
    // graph around a node that is not what the drawer shows.
    p.win.eval(`state.focus = ${JSON.stringify('dep:' + D.tables[name].node)};` +
      `openTable(${JSON.stringify(orphan)})`);
    assert.equal(p.peek('state.table'), 'pg.' + orphan,
      `${orphan} has no node, so following it should still open its definition`);
    assert.equal(p.peek('state.focus'), null,
      `following ${orphan} left the focus on the table it was followed from`);
  } else {
    assert.ok(Object.keys(D.tables || {}).length > 0,
      'this map draws every table it declares, so the undrawn-table path rests on the fixture map');
  }

  // A key from a table to itself is one constraint, and it is the table's own
  // declaration: the drawer shows both directions, so counting it as inbound too would
  // print the same constraint on two lines and read as two keys the schema does not
  // have. The coordinator declares none today, so this is the fixture's claim.
  const selfRef = declaredFks(D).find(r =>
    r.fk.table === r.from && (D.tables[r.from] || {}).node);
  if (selfRef) {
    const own = (D.tables[selfRef.from].foreignKeys || []).length;
    const at = inbound(D, selfRef.from).length;
    p.win.eval(`openTable(${JSON.stringify(selfRef.from)})`);
    const summary = [...p.$$('#gschema details summary')].find(s => s.textContent.startsWith('Foreign keys'));
    assert.ok(summary, `${selfRef.from} references itself and the drawer states no keys at all`);
    assert.equal(summary.textContent,
      'Foreign keys · ' + own + ' declared here, ' + at + ' pointing here',
      `${selfRef.from} references itself, and the drawer counts that one constraint twice`);
    assert.equal(p.$$('#gschema ul.fklist li').length, own + at,
      `${selfRef.from} references itself, and the drawer lists that one constraint twice`);
  } else {
    assert.ok(declaredFks(D).length > 0,
      'no table in this map references itself, so that claim rests on the other map');
  }
});
