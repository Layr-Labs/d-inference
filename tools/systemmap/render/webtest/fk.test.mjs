// The declared foreign keys, as the picture draws them.
//
// The inventory half of this feature was never in doubt: `tableLinks` is derived from
// the same DDL the column definitions come from, and the *Table relationships* table
// lists every key including the ones the graph cannot draw. What went wrong was the
// drawing, and it went wrong invisibly — the arcs had correct geometry, correct
// endpoints and a correct tooltip, stroked thinly enough at the zoom that fits the
// whole map to not be there. Nothing in a DOM check that asks "is the path present"
// could tell that apart from a working feature, so these tests ask about the width of
// the line in *screen* pixels, which is the quantity a reader actually sees.
//
// The rule, and it is the same one the arrowheads follow: a stroke inside the zoomed
// scene is scaled with the scene, so anything that has to stay legible across the
// page's whole zoom range must opt out. Access wires do not, deliberately — 990 of
// them have collective mass. Fifteen do not, which is the asymmetry this file pins.

import test from 'node:test';
import assert from 'node:assert/strict';
import { load, inventory, drag, frame } from './harness.mjs';
import { headShape, encode } from './timeline.mjs';

// The zooms a reader actually lands on: the fit, the postgres cluster (where all of
// this map's keys live), and the extremes of the button range.
const styleText = p => p.peek(`[...document.querySelectorAll('style')].map(s => s.textContent).join('\\n')`);

// The declaration block for one selector, as written. Read out of the page rather
// than out of page.css, so the assertion covers what was actually shipped.
function rule(p, selector) {
  const css = styleText(p);
  const at = css.indexOf(selector + ' {');
  assert.ok(at >= 0, `the page's stylesheet has no \`${selector}\` rule at all`);
  const end = css.indexOf('}', at);
  return css.slice(at + selector.length + 2, end).trim();
}

test('every declared key between two drawn tables is an arc', async t => {
  const p = await load({ t });
  const D = inventory();
  const drawable = (D.tableLinks || []).filter(l => D.nodes[l.from] && D.nodes[l.to] && l.from !== l.to);
  assert.ok(drawable.length, 'the map declares no foreign key between two drawn tables, so this file asserts nothing');

  const arcs = [...p.peek(`FKLINKS.map(l => ({ from: l.fk.from, to: l.fk.to,
    d: l.node.getAttribute('d') || '', tip: l.node.textContent || '',
    marker: l.node.getAttribute('marker-end') || '',
    inScene: !!l.node.closest('#scene') }))`)];
  assert.equal(arcs.length, drawable.length,
    `${drawable.length} keys join two drawn tables, but the picture holds ${arcs.length} arcs`);

  const want = new Set(drawable.map(l => l.from + '>' + l.to));
  for (const a of arcs) {
    assert.ok(want.has(a.from + '>' + a.to), `the picture draws a key ${a.from} → ${a.to} the inventory does not declare`);
    // A path with no `d` is the failure a "the element exists" test passes on.
    assert.match(a.d, /^M-?[\d.]+ -?[\d.]+Q-?[\d.]+ -?[\d.]+ -?[\d.]+ -?[\d.]+$/,
      `the arc for ${a.from} → ${a.to} has no usable path: ${JSON.stringify(a.d)}`);
    assert.ok(a.tip.includes(a.to.replace('pg.', '')),
      `the arc for ${a.from} → ${a.to} does not name the table it points at in its tooltip`);
    // Whether it wears a head depends on whether it is long enough to (see below); that
    // it is *inside* the scene is what makes it move with its tables.
    assert.ok(a.inScene, `the arc for ${a.from} → ${a.to} is drawn outside the scene, so it will not follow its tables`);
  }
});

// The other half of the same legibility problem, and the one the stroke fix created: a
// head is screen-sized, so it does not shrink with the arc it sits on.
test('a key too short for its head is drawn without one, and gets it back on zoom', async t => {
  const p = await load({ t });
  // `px` is measured off the drawn path rather than off l.ink, so a page that computed
  // its rule against the wrong quantity cannot satisfy this by computing it consistently.
  const state = () => [...p.peek(`FKLINKS.map(l => {
    const m = /^M(-?[\\d.]+) (-?[\\d.]+)Q-?[\\d.]+ -?[\\d.]+ (-?[\\d.]+) (-?[\\d.]+)$/.exec(l.node.getAttribute('d'));
    return { key: l.fk.from + '>' + l.fk.to,
      px: Math.hypot(m[3] - m[1], m[4] - m[2]) * view.k,
      head: !!l.node.getAttribute('marker-end') };
  })`)];
  const headPx = p.peek('FK_ARROW_PX.w');

  // The page's own rule, held to at every zoom the reader can reach: a head goes on when
  // the arc draws at least 1.6 of them and comes off below that. Asserting the threshold
  // and not merely "the head is no longer than the line" is what stops the rule being
  // quietly relaxed to 1.0, where a head exactly covers its arc.
  const check = where => {
    for (const a of state()) {
      if (a.head) assert.ok(a.px >= 1.6 * headPx,
        `${where}: ${a.key} draws ${a.px.toFixed(1)}px of ink and wears a ${headPx}px head, which is more of the line than an annotation may be`);
      else assert.ok(a.px < 1.6 * headPx * 1.05,
        `${where}: ${a.key} draws ${a.px.toFixed(1)}px of ink, room enough for its ${headPx}px head, but was left bare`);
    }
  };
  const atFit = state();
  check('at the fit');

  // Which keys are short enough to be suppressed depends on where the layout happens to
  // put their tables — a plain map and a `-history` one place the same tables differently,
  // because the second lays out the union of every revision. So the recoverability claim
  // is about the direction of the change and not about a particular zoom: zooming in only
  // ever adds heads, never takes one away, and a key hidden at the fit comes back.
  const headed = s => new Set(s.filter(a => a.head).map(a => a.key));
  let prev = headed(atFit);
  for (let i = 0; i < 6; i++) {
    p.press('.gbar button[data-z="in"]');
    await new Promise(r => setTimeout(r, 60));
    const now = state();
    check(`after ${i + 1} zoom steps`);
    const lost = [...prev].filter(k => !headed(now).has(k));
    assert.equal(lost.length, 0, `zooming in took the head off ${lost.join(', ')}, which only gets longer on screen`);
    prev = headed(now);
  }
  const hidden = atFit.filter(a => !a.head);
  if (hidden.length) assert.ok(prev.size > headed(atFit).size,
    'no suppressed key regained its head across six zoom steps, so suppression is permanent for ' +
      hidden.map(a => `${a.key} (${a.px.toFixed(1)}px at the fit)`).join(', '));
});

// The regression. A key's stroke has to be a screen-pixel quantity, or the whole
// feature disappears at the only zoom the page opens on.
test('a key is the same dotted line at every zoom', async t => {
  const p = await load({ t });
  const decl = rule(p, '.fklink');
  assert.match(decl, /vector-effect:\s*non-scaling-stroke/,
    'a foreign key is stroked in scene units, so it is 0.4px wide at the zoom that fits the map ' +
    'and 3px wide at the postgres cluster — the stroke must opt out of the scene transform:\n  ' + decl);

  // And the hover state too: a key a reader is pointing at must not go back to
  // scaling, which would make the emphasis mean something different at each zoom.
  const hi = rule(p, '.fklink.hi');
  assert.ok(!/vector-effect:\s*(?!non-scaling)/.test(hi),
    `.fklink.hi overrides the vector effect: ${hi}`);
});

// The other half of the asymmetry, stated so that "make everything non-scaling"
// cannot silently become the rule. An access wire scales on purpose.
test('an access wire still scales, because a thousand of them carry each other', async t => {
  const p = await load({ t });
  assert.ok(!rule(p, '.glink').includes('non-scaling-stroke'),
    'access wires were made non-scaling; at close zoom a thousand screen-width lines ' +
    'fill the picture, which is why only the foreign keys opt out');
});

// The arcs are geometry over node positions, so they have to follow the zoom the way
// the dots do: what scales is the distance between two tables, and only that.
test('an arc follows its tables when the view moves', async t => {
  const p = await load({ t });
  const chords = () => [...p.peek(`FKLINKS.map(l => Math.round(Math.hypot(l.t.x - l.s.x, l.t.y - l.s.y) * 100) / 100)`)];
  const paths = () => [...p.peek(`FKLINKS.map(l => l.node.getAttribute('d'))`)];

  const atFit = chords(), drawnAtFit = paths();
  assert.ok(atFit.every(c => c > 0), `two tables are drawn on top of each other: ${atFit}`);

  // Zooming is a transform on the scene, so the scene-space chords must not move: a
  // zoom that re-solved the layout would shuffle the map under the reader.
  p.press('.gbar button[data-z="in"]');
  await new Promise(r => setTimeout(r, 120));
  assert.deepEqual(chords(), atFit, 'zooming in changed where the tables are, not just how big they look');
  assert.deepEqual(paths(), drawnAtFit, 'zooming in redrew the arcs, which means the zoom is not a transform');

  // Focusing the cluster the keys live in is the reader's way of getting a zoom where
  // the short ones are legible. It may move the view; it must not move the tables.
  const cluster = p.peek(`(() => {
    const ids = new Set(FKLINKS.flatMap(l => [l.s.cluster, l.t.cluster]));
    return ids.size === 1 ? [...ids][0] : '';
  })()`);
  assert.ok(cluster, 'this map\'s keys span more than one cluster, so no single chip zooms to them');
  const before = p.peek('view.k');
  p.peek(`(focusCluster(${JSON.stringify(cluster)}), 1)`);
  await new Promise(r => setTimeout(r, 700));
  assert.ok(p.peek('view.k') > before,
    `focusing ${cluster} did not zoom in, so a reader has no way to reach the short keys`);
  assert.deepEqual(chords(), atFit, `focusing ${cluster} moved its tables`);
});

// Dragging a table changes how long its keys are without changing the zoom, so a rule
// guarded on the zoom alone would keep a head the line no longer has room for — and
// panning, which re-runs the view at an unchanged scale, would not clear it either. This
// is the same defect as the original one, reachable with one drag instead of none.
test('dragging a table re-decides its keys’ heads, and a pan does not undo that', async t => {
  const p = await load({ t });
  const headed = () => [...p.peek(`FKLINKS.map(l => !!l.node.getAttribute('marker-end'))`)];
  // Zoom until at least one key has room for a head, because a map whose keys are all
  // short at the fit — the five-route fixture is one — has nothing to take away yet.
  for (let i = 0; i < 12 && !headed().some(h => h); i++) {
    p.press('.gbar button[data-z="in"]');
    await new Promise(r => setTimeout(r, 40));
  }
  assert.ok(headed().some(h => h),
    'no key wears a head at any zoom the buttons reach, so dragging cannot take one off');

  // Drag the child table of a headed key onto its parent: the arc collapses, so the head
  // must go. The nodes are dragged in screen space, so the target is where the parent is.
  const at = p.peek(`(() => {
    const i = FKLINKS.findIndex(l => l.node.getAttribute('marker-end'));
    const l = FKLINKS[i];
    return { i, from: { x: l.s.x * view.k + view.x, y: l.s.y * view.k + view.y },
                 to: { x: l.t.x * view.k + view.x, y: l.t.y * view.k + view.y } };
  })()`);
  const node = p.peek(`FKLINKS[${at.i}].s.g`);
  drag(p, node, at.from, at.to);
  await new Promise(r => setTimeout(r, 60));
  assert.equal(headed()[at.i], false,
    'a table dragged onto the one it references kept its head, which is now wider than the line under it');

  // A pan is `applyView` at an unchanged scale. It must not resurrect the head.
  drag(p, p.peek('gsvg'), { x: 300, y: 300 }, { x: 360, y: 260 });
  await new Promise(r => setTimeout(r, 60));
  assert.equal(headed()[at.i], false, 'panning brought back a head the drag had removed');
});

// A key exists exactly when both of its tables do, so the slider has to say the same
// thing about an arc that it says about the tables at its ends. It has no delta of its
// own for foreign keys — they are not in the union's link table, because they take no
// part in the drawn topology — so this is derived from the two endpoints, and before it
// was, an arc between two tables that did not exist yet was drawn as a 5% ghost: the one
// edge class the timeline said nothing about.
test('a key is absent where its table is, and goes when its table goes', async t => {
  const D = inventory();
  const key = (D.tableLinks || []).find(l => D.nodes[l.from] && D.nodes[l.to] && l.from !== l.to);
  assert.ok(key, 'the map declares no foreign key between two drawn tables, so this file asserts nothing');

  // Three points around one table: it exists, this commit drops it, it is back. The
  // middle point is the only place `went` can be observed — it is what *this* commit
  // removed, not merely what the revision lacks.
  const head = headShape(D);
  const without = {
    ...head, rev: 'gone0000000', date: '2026-05-01', subject: 'the commit that dropped it',
    nodes: head.nodes.filter(n => n.id !== key.from),
    links: head.links.filter(l => l.node !== key.from),
  };
  const TL = encode([{ ...head, rev: 'was00000000', date: '2026-04-01' }, without,
    { ...head, rev: D.revision || 'now00000000', date: '2026-09-08' }], { head: D.revision || 'now00000000' });

  const p = await load({ t, timeline: TL });
  const arc = () => p.peek(`(() => {
    const l = FKLINKS.find(l => l.fk.from === ${JSON.stringify(key.from)});
    const c = l.node.classList;
    return { absent: c.contains('absent'), went: c.contains('went'), mute: c.contains('mute') };
  })()`);

  p.type('#gtrange', '1');
  await frame(p);
  const dropped = arc();
  assert.ok(dropped.went,
    `at the commit that dropped ${key.from}, its key is not marked as gone — the slider ` +
    `says nothing about the arc while saying it about the table: ${JSON.stringify(dropped)}`);

  p.type('#gtrange', '0');
  await frame(p);
  const alive = arc();
  assert.ok(!alive.absent && !alive.went,
    `at a revision that has ${key.from}, its key is not drawn: ${JSON.stringify(alive)}`);
});

// A key takes no part in the drawn topology: adding a REFERENCES to the schema must
// not move a dot or an edge. The fingerprint is how the page states that, so the arcs
// must be outside it — including the one a reader is hovering.
test('a key is not part of the drawn topology', async t => {
  const p = await load({ t });
  const marked = p.peek(`FKLINKS.filter(l => l.node.hasAttribute('data-topo')).length`);
  assert.equal(marked, 0, `${marked} foreign-key arcs carry data-topo, so a schema-only change would move the fingerprint`);
});
