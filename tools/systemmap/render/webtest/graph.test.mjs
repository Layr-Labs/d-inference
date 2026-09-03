// The picture, executed. These are the claims the graph makes about itself that
// no string check can reach: that a node is drawn inside the boundary it belongs
// to, that two boundaries never overlap, that no two labels are ever laid on top
// of each other at any zoom, and that nothing a reader does to the view changes
// what the picture says is connected to what.
//
// All of it is arithmetic the page does in JavaScript, so jsdom runs the real
// algorithms — this is not a stand-in for the layout, it is the layout.

import test from 'node:test';
import assert from 'node:assert/strict';
import { load, frame, drag, visible, searchTerm } from './harness.mjs';
import { assertLabels, frameSize } from './labels.mjs';

// The zoom range the page allows, walked from the fit scale out to the floor and
// in to the ceiling. Labels have to survive all of it: the collision pass runs in
// screen space, so every scale is a different packing problem.
const ZOOM_STEPS = [1 / 1.35, 1 / 1.35, 1 / 1.35, 1 / 1.35, 1.35, 1.35, 1.35, 1.35, 1.35, 1.35, 1.35, 1.35];

const topo = p => p.text('#topo');
const labelIds = p => assertLabels(p, 'on a fresh load').map(u => u.kind + ':' + u.id);

// A boundary's name is the one label the page never drops: a ring with no name on
// it is an unreadable picture, so it is lifted clear of whatever is already placed
// rather than hidden. This is the other half of the no-overlap claim — a pass could
// satisfy that one by drawing nothing.
function assertClustersNamed(p, where) {
  const hullLabels = p.peek('hullLabels'), hullSubs = p.peek('hullSubs');
  for (const id of p.peek('clusterIds')) {
    assert.ok(visible(hullLabels[id]), `cluster ${id} lost its name ${where}`);
    assert.ok(visible(hullSubs[id]), `cluster ${id} lost its subtitle ${where}`);
    assert.equal(hullLabels[id].getAttribute('x'), hullSubs[id].getAttribute('x'),
      `cluster ${id}'s subtitle parted company with its title ${where}`);
    // 13px apart, to the tenth the page rounds its coordinates to.
    const gap = Number(hullSubs[id].getAttribute('y')) - Number(hullLabels[id].getAttribute('y'));
    assert.ok(Math.abs(gap - 13) <= 0.11,
      `cluster ${id}'s subtitle sits ${gap}px under its title, not 13px, ${where}`);
  }
}

test('every node is drawn inside its group, and every group inside its cluster', t => {
  const p = load({ t });
  const centers = p.peek('center'), radii = p.peek('radius');

  for (const n of p.peek('GNODES')) {
    const g = n.grp;
    const d = Math.hypot(n.x - g.cx, n.y - g.cy);
    // `clamp` allows the node's own radius plus 3px of ring, so its disc is inside
    // the group's rather than merely its centre.
    assert.ok(d <= g.r - n.r - 3 + 1e-6,
      `${n.id} sits ${(d - (g.r - n.r - 3)).toFixed(1)}px outside group ${g.id}`);
    const c = centers[g.cluster];
    assert.ok(Math.hypot(g.cx - c.x, g.cy - c.y) + g.r <= radii[g.cluster] + 1e-6,
      `group ${g.id} sticks out of cluster ${g.cluster}`);
  }
});

test('two group discs in one cluster never overlap', t => {
  const p = load({ t });
  const GROUPS = p.peek('GROUPS');
  const ids = Array.from(p.peek('groupIds'));
  const byCluster = {};
  for (const id of ids) (byCluster[GROUPS[id].cluster] ||= []).push(id);

  for (const [cluster, gids] of Object.entries(byCluster)) {
    for (let i = 0; i < gids.length; i++) {
      for (let j = i + 1; j < gids.length; j++) {
        const a = GROUPS[gids[i]], b = GROUPS[gids[j]];
        const d = Math.hypot(a.cx - b.cx, a.cy - b.cy);
        // The packing ends with a separation pass that runs until the worst
        // remaining intrusion is under 0.4px, so that is the tolerance — the claim
        // is that the discs are disjoint to the pixel, not to floating point.
        assert.ok(d >= a.r + b.r - 0.5,
          `${gids[i]} and ${gids[j]} overlap by ${(a.r + b.r - d).toFixed(1)}px in ${cluster}`);
      }
    }
  }
});

test('no two labels overlap, at any zoom the reader can reach', t => {
  const p = load({ t });
  const seen = [];
  assert.ok(assertLabels(p, 'at the initial fit').length > 0, 'the page placed no labels at all');
  assertClustersNamed(p, 'at the initial fit');

  for (const factor of ZOOM_STEPS) {
    p.win.zoomBy(factor);
    const k = p.peek('view.k');
    seen.push(Number(k.toFixed(3)));
    const where = `at zoom ${k.toFixed(2)}`;
    assertLabels(p, where);
    assertClustersNamed(p, where);
    assert.ok(k >= 0.15 && k <= 8, `zoom ${k} left the range the page clamps to`);
  }
  // The sweep has to have actually moved, or this test proves nothing about zoom.
  assert.ok(new Set(seen).size > 4, `the zoom sweep only reached ${new Set(seen).size} scales`);
});

test('no two labels overlap in a frame too small for them all', t => {
  // The same map in a quarter of the room. Crowding is what the collision pass is
  // for, and the small map this suite also runs against does not crowd a 1200x620
  // frame on its own — without this, the whole claim would rest on the real
  // coordinator map, which only CI drives.
  const p = load({ t, viewport: { width: 420, height: 320 } });
  assert.deepEqual(frameSize(p), { width: 420, height: 320 }, 'the page did not lay out against the small frame');
  assert.ok(assertLabels(p, 'in a 420x320 frame').length > 0, 'the page placed no labels at all');
  assertClustersNamed(p, 'in a 420x320 frame');
  for (const factor of ZOOM_STEPS) {
    p.win.zoomBy(factor);
    assertLabels(p, `in a 420x320 frame at zoom ${p.peek('view.k').toFixed(2)}`);
    assertClustersNamed(p, `in a 420x320 frame at zoom ${p.peek('view.k').toFixed(2)}`);
  }
});

test('labels stay laid out through a filter, a focus and a hover', t => {
  const p = load({ t });
  const D = p.peek('DATA');

  p.choose('#ns', D.routes[0].namespace);
  assertLabels(p, 'under a namespace filter');

  const node = p.pickDep(1);
  node.g.dispatchEvent(new p.win.Event('pointerenter'));
  assertLabels(p, 'under a hover');
  node.g.dispatchEvent(new p.win.Event('pointerleave'));

  p.clickNode(node.g);
  assertLabels(p, 'under a focus');
  // A focus is the reader asking for these names in particular, so the labels on
  // its own edges are placed as priority and exempt from the budget.
  const pri = p.$$('#glabels text.pri').filter(visible);
  assert.ok(pri.length > 0, 'focusing a node prioritised no label');
});

test('endpoint names are earned by zooming in, and the label budget is never exceeded', t => {
  const p = load({ t });
  const budget = p.peek('LABEL_BUDGET');
  const earned = p.peek('EP_LABEL_ZOOM');
  const drawn = () => p.peek('GNODES').filter(n => n.text && visible(n.text));
  // What the page had to choose from at this zoom: everything the filter left shown,
  // minus the endpoints if they have not earned a name yet. The budget only means
  // something where this exceeds it.
  const candidates = () => {
    const L = p.peek('L'), k = p.peek('view.k');
    return p.peek('GNODES').filter(n =>
      L.shown.has(n.id) && (n.kind === 'dep' || k >= earned || L.focused || L.near.size)).length;
  };

  assert.equal(drawn().filter(n => n.text.classList.contains('pri')).length, 0,
    'nothing is selected, so nothing should be a priority label');
  // Endpoints are the noisy half: a hundred of them at once is not a picture, so
  // they are withheld until the reader zooms in or narrows to a handful. `fit` is
  // unclamped, so a small enough map is already past that threshold when it opens —
  // in which case the withholding rule has nothing to say and the earning half is
  // still the test.
  if (p.peek('view.k') < earned) {
    assert.equal(drawn().filter(n => n.kind === 'ep').length, 0,
      'endpoint labels were drawn in the wide shot');
  }

  // The ceiling, at every zoom the reader can reach rather than only at the fit: the
  // budget is spent on the busiest nodes first, so it binds where the picture is most
  // crowded — which on the real map is a little way in from the fit, not at it.
  let peak = 0, bound = null;
  for (let i = 0; ; i++) {
    const now = drawn().length;
    assert.ok(now <= budget, `${now} node labels drawn against a budget of ${budget} at zoom ${p.peek('view.k').toFixed(2)}`);
    if (now > peak) peak = now;
    if (now === budget && bound === null) bound = { k: p.peek('view.k'), candidates: candidates() };
    if (i >= 12) break;
    p.win.zoomBy(1.35);
  }
  if (bound) {
    // The budget actually bit here, which is the only condition under which the
    // ceiling above is a statement about the budget rather than about the collision
    // pass: the page had more it was allowed to name and stopped anyway.
    assert.ok(bound.candidates > budget,
      `the page drew exactly ${budget} labels at zoom ${bound.k.toFixed(2)} out of only ${bound.candidates} candidates, which is a coincidence rather than a budget`);
  } else {
    // The fixture. Too few nodes for the budget to ever be the binding constraint —
    // the collision pass runs out of candidates first — so say so rather than let a
    // vacuous `<=` read as coverage. The real map is where this claim is tested.
    assert.ok(peak < budget,
      `this map never reaches the label budget (${peak} of ${budget} at its busiest), so the bound is untested here`);
  }

  // And the earning half, from wherever the walk ended up: zoomed all the way in,
  // endpoints have names.
  let steps = 0;
  while (p.peek('view.k') > earned && steps++ < 40) p.win.zoomBy(1 / 1.35);
  while (p.peek('view.k') < earned && steps++ < 40) p.win.zoomBy(1.35);
  assert.ok(p.peek('view.k') >= earned,
    `the view will not zoom to ${earned}; it clamped at ${p.peek('view.k')}`);
  assert.ok(drawn().some(n => n.kind === 'ep'), 'zooming in earned no endpoint its name');
});

test('the topology fingerprint is a reading of what is drawn', t => {
  const p = load({ t });
  const before = topo(p);
  assert.match(before, /^[0-9a-f]{8}$/);
  // Read off the DOM, so it is a statement about what is drawn rather than about
  // what the page intended to draw.
  assert.equal(p.$$('#gnodes > g[data-topo]').length, p.peek('GNODES').length);
  assert.equal(p.$$('#glinks > path[data-topo]').length, p.peek('GLINKS').length);

  // And sensitive: the stability claims below are worth nothing if the fingerprint
  // is a constant. Remove one association from the picture and it has to notice.
  const after = p.peek("document.querySelector('#glinks > path[data-topo]').remove(); topoFingerprint()");
  assert.notEqual(after, before, 'the fingerprint did not notice an association leaving the picture');
  const node = p.peek("document.querySelector('#gnodes > g[data-topo]').remove(); topoFingerprint()");
  assert.notEqual(node, after, 'the fingerprint did not notice a node leaving the picture');
});

test('the drawn topology survives everything the reader can do to the view', t => {
  const p = load({ t });
  const D = p.peek('DATA');
  const want = topo(p);
  const still = what => assert.equal(topo(p), want, `${what} changed the drawn topology`);

  for (const factor of ZOOM_STEPS) { p.win.zoomBy(factor); still(`zooming to ${p.peek('view.k')}`); }
  p.win.eval('fit()');
  still('refitting');

  p.type('#q', searchTerm(D));
  still('searching');
  p.choose('#ns', D.routes[0].namespace);
  still('filtering by namespace');
  p.choose('#mode', 'W');
  still('filtering by access mode');
  p.choose('#ont', 'unreached');
  still('filtering by identity');
  p.press('#reset');
  still('resetting');

  for (const view of ['code', 'overlay', 'all']) { p.view(view); still(`the ${view} view`); }

  const node = p.pickDep();
  p.clickNode(node.g);
  still('focusing a node');
  p.key('Escape');
  still('clearing the focus');

  const table = Object.keys(D.tables || {})[0];
  if (table) { p.choose('#dep', 'pg.' + table); still('opening a table definition'); }
});

test('dragging a node moves it, keeps it inside its boundary, and says nothing new', t => {
  const p = load({ t });
  const want = topo(p);
  const node = p.pickDep();
  const before = { x: node.x, y: node.y };
  const g = node.grp;

  // Far enough to leave the group disc if nothing held it in.
  drag(p, node.g, { x: 40, y: 40 }, { x: 40 + 4000, y: 40 + 4000 });
  assert.notEqual(node.x, before.x, 'the drag did not move the node');
  assert.ok(Math.hypot(node.x - g.cx, node.y - g.cy) <= g.r - node.r - 3 + 1e-6,
    `dragging ${node.id} pushed it out of group ${g.id}`);
  assert.equal(topo(p), want, 'moving a node changed what is connected to what');
  // The node's own drawn position followed it, and so did the edge to it: the
  // page positions the shape and re-paths every association from the same numbers.
  assert.equal(node.shape.getAttribute('cx'), node.x.toFixed(1), 'the drawn node did not follow the drag');
  assert.equal(node.shape.getAttribute('cy'), node.y.toFixed(1), 'the drawn node did not follow the drag');
  const edge = node.links[0];
  assert.ok(edge.node.getAttribute('d').endsWith(node.x.toFixed(1) + ' ' + node.y.toFixed(1)) ||
    edge.node.getAttribute('d').startsWith('M' + node.x.toFixed(1) + ' ' + node.y.toFixed(1)),
    'an association still ends where the node used to be');
  assertLabels(p, 'after a node drag');

  // A drag is not a click: it must not focus anything.
  assert.equal(p.peek('state.focus'), null, 'a drag was read as a click');

  // And the name goes with the dot. `assertLabels` above scores every label that is
  // shown, but a dragged node whose label was never placed makes that claim vacuous
  // for the only node that moved — so one that *is* named is dragged a short way and
  // its name is required to still be on it. Without this, dropping `placeLabels` from
  // the drag path leaves every name where it was and the whole suite stays green.
  const named = p.pick(n => n.kind === 'dep' && visible(n.text), 'named dependency');
  const was = Number(named.text.getAttribute('x'));
  drag(p, named.g, { x: 100, y: 100 }, { x: 130, y: 120 });
  assert.ok(visible(named.text), `${named.id} lost its name to a 30px drag`);
  assert.notEqual(Number(named.text.getAttribute('x')), was,
    `${named.id} moved and its name did not`);
  assertLabels(p, 'after dragging a named node');
});

test('dragging the canvas pans by exactly the gesture, and a press on it clears the focus', t => {
  const p = load({ t });
  const gsvg = p.$('#gsvg');
  const want = topo(p);
  const before = { ...p.peek('view') };

  drag(p, gsvg, { x: 300, y: 300 }, { x: 380, y: 250 });
  const after = p.peek('view');
  assert.equal(after.x, before.x + 80, 'the pan does not track the pointer horizontally');
  assert.equal(after.y, before.y - 50, 'the pan does not track the pointer vertically');
  assert.equal(after.k, before.k, 'panning changed the scale');
  assert.equal(topo(p), want, 'panning changed the drawn topology');
  assertLabels(p, 'after a pan');

  const node = p.pickDep();
  p.clickNode(node.g);
  assert.equal(p.peek('state.focus'), node.id);
  // A press on empty canvas that never moved is how you put the whole system back.
  drag(p, gsvg, { x: 300, y: 300 }, { x: 300, y: 300 });
  assert.equal(p.peek('state.focus'), null, 'a press on the canvas left the focus pinned');
});

test('the wheel zooms about the pointer', t => {
  const p = load({ t });
  const before = { ...p.peek('view') };
  // The point under the cursor is the fixed point of the transform: zooming in on
  // a node has to leave that node where it is.
  const px = 400, py = 220;
  const scene = { x: (px - before.x) / before.k, y: (py - before.y) / before.k };
  p.$('#gsvg').dispatchEvent(new p.win.WheelEvent('wheel',
    { deltaY: -240, clientX: px, clientY: py, bubbles: true, cancelable: true }));

  const after = p.peek('view');
  assert.ok(after.k > before.k, 'a wheel up did not zoom in');
  assert.ok(Math.abs(scene.x * after.k + after.x - px) < 1e-6, 'the wheel zoom drifted horizontally');
  assert.ok(Math.abs(scene.y * after.k + after.y - py) < 1e-6, 'the wheel zoom drifted vertically');
  assertLabels(p, 'after a wheel zoom');
});

test('framing one cluster frames that cluster', t => {
  const p = load({ t });
  const want = topo(p);
  const D = p.peek('DATA');
  const members = p.peek('members');
  const id = p.peek('clusterIds').find(c => members[c].length > 1);
  assert.ok(id, 'no cluster holds more than one node');
  const before = { ...p.peek('view') };

  p.win.eval(`focusCluster(${JSON.stringify(id)})`);
  const view = p.peek('view');
  // A cluster that holds every node is the whole map, and framing it is a refit that
  // may land on the scale the page already had. Only a proper part has to move it.
  if (members[id].length < p.peek('GNODES').length) {
    assert.notEqual(view.k, before.k, 'framing part of the map did not change the scale');
  }
  // Every node of that cluster is inside the frame, which is what "framed" means.
  const box = frameSize(p);
  for (const n of members[id]) {
    const x = n.x * view.k + view.x, y = n.y * view.k + view.y;
    assert.ok(x >= -1 && x <= box.width + 1 && y >= -1 && y <= box.height + 1,
      `${n.id} is outside the frame drawn around its own cluster`);
  }
  assert.equal(topo(p), want, 'framing a cluster changed the drawn topology');
  assertLabels(p, 'framed on one cluster');
  assert.ok(D.clusters[id], 'the framed cluster is not one the inventory declares');
});

test('full screen is a bigger frame, and the picture is refitted into it', async t => {
  const p = load({ t });
  const want = topo(p);
  const small = { ...p.peek('view') };
  assert.equal(frameSize(p).width, p.viewport.width);

  p.press('#gfull');
  await frame(p);
  const big = frameSize(p);
  assert.ok(big.width > p.viewport.width, 'the frame did not grow');
  // The viewBox is a function of the element's pixel size, so a size change that
  // did not rewrite it would skew the scene's aspect ratio.
  assert.equal(p.$('#gsvg').getAttribute('viewBox'), `0 0 ${big.width} ${big.height}`,
    'the viewBox was not rewritten for the new size');
  assert.notEqual(p.peek('view.k'), small.k, 'the graph kept a scale chosen for the smaller frame');
  assert.equal(topo(p), want, 'entering full screen changed the drawn topology');
  assertLabels(p, 'in full screen');

  p.press('#gfull');
  await frame(p);
  assert.equal(frameSize(p).width, p.viewport.width, 'the frame did not shrink back');
  assert.equal(p.$('#gsvg').getAttribute('viewBox'), `0 0 ${p.viewport.width} ${p.viewport.height}`);
  assert.equal(p.peek('view.k'), small.k, 'leaving full screen did not restore the fit');
  assert.equal(topo(p), want, 'leaving full screen changed the drawn topology');
  assertLabels(p, 'after full screen');
});

test('the layout is deterministic: two loads draw the same picture', t => {
  const a = load({ t }), b = load({ t });
  assert.equal(topo(a), topo(b), 'two loads of the same page drew different topologies');
  const pos = p => p.peek('GNODES').map(n => `${n.id}@${n.x.toFixed(3)},${n.y.toFixed(3)}`).join(';');
  // Same seeding, same force passes, same result — a layout that wandered between
  // loads would make every geometric claim above unrepeatable.
  assert.equal(pos(a), pos(b), 'the layout is not deterministic');
  assert.deepEqual(labelIds(a), labelIds(b), 'the same page placed a different set of labels');
  assert.ok(labelIds(a).length > 0, 'the page placed no labels at all');
});
