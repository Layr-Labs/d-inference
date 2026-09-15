// Loads the generated system map into a DOM and runs its script.
//
// The page under test is the real artifact: `render.HTML` injects page.css, the
// three script parts (page.js, page.timeline.js, page.boot.js) and the inventory
// into page.html, and this harness opens *that file* rather than any of its parts.
// So a test here fails when the explorer breaks, not when a string moves — and the
// concatenation order the parts depend on is itself under test, since a boot part
// running too early throws before the first assertion.
//
// What jsdom does prove: the script parses and executes to the end, every
// handler the toolbar installs runs, the DOM those handlers build is the one the
// assertions read, and every geometric decision the page makes — the layout, the
// zoom transform, the label collision pass, the topology fingerprint — is real,
// because it is computed in JavaScript from numbers rather than measured off a
// rendered glyph.
//
// What it does not prove: painting. jsdom applies no stylesheet-driven layout, so
// element sizes are whatever the polyfill below says, `display:none` is read back
// as an attribute rather than as invisibility, and the Fullscreen API is a stub
// that flips a flag. A CSS regression that hides a working control is out of
// reach here and is not claimed to be covered.
//
// One real measurement is missing rather than stubbed, and it is worth naming: the
// page never measures text (no `getBBox` anywhere, and `getBoundingClientRect` only
// on the SVG itself), it estimates glyph width arithmetically. labels.mjs scores
// collisions with that same estimate, so this suite proves the collision pass is
// consistent with the page's own estimator — not that the estimator matches a real
// font. Since text width is the only geometric input jsdom cannot supply, that is
// the whole of the gap.
//
// This file loads the page and drives it. Scoring the geometry it produced is
// labels.mjs; the assertions themselves are explorer.test.mjs and graph.test.mjs.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { JSDOM, VirtualConsole } from 'jsdom';

export const PAGE = process.env.SYSTEMMAP_PAGE;
if (!PAGE) {
  throw new Error('set SYSTEMMAP_PAGE to a generated system-map.html (see the Go driver, or `make -C tools/systemmap webtest`)');
}

// The graph reads its own pixel size and lays out against it, so a stable rect is
// part of the fixture: the same numbers give the same label placement on every
// machine. 1200x620 is the CSS size the page falls back to on its own.
export const VIEWPORT = { width: 1200, height: 620 };

// Full screen is a bigger frame, and that is the whole point of it — so the stub
// reports one. Without a size change, "entering full screen refits" is not an
// observable claim: a no-op satisfies it.
const FULLSCREEN = { width: 1920, height: 1080 };

// Every browser API the page uses that jsdom does not implement. They are stubs
// on purpose and each one is a stated limit of this harness, not an emulation:
// ResizeObserver never fires and pointer capture is a no-op.
function polyfill(win, viewport) {
  win.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  };
  win.Element.prototype.setPointerCapture = function () {};
  win.Element.prototype.releasePointerCapture = function () {};
  win.Element.prototype.scrollIntoView = function () {};
  // Fullscreen, as a flag the test can read and the page can toggle, plus the
  // larger frame that makes it mean something. The real API needs a user gesture
  // and a compositor; what the page's own logic decides from it — which label the
  // button carries, and that it reframes against the new size — is testable, and
  // that is the part under test.
  let full = null;
  win.Element.prototype.getBoundingClientRect = function () {
    const size = full ? FULLSCREEN : viewport;
    return {
      x: 0, y: 0, top: 0, left: 0,
      width: size.width, height: size.height,
      right: size.width, bottom: size.height,
      toJSON() { return this; },
    };
  };
  Object.defineProperty(win.Document.prototype, 'fullscreenElement', {
    configurable: true,
    get() { return full; },
  });
  win.Element.prototype.requestFullscreen = function () {
    full = this;
    this.ownerDocument.dispatchEvent(new win.Event('fullscreenchange'));
    return Promise.resolve();
  };
  win.Document.prototype.exitFullscreen = function () {
    full = null;
    this.dispatchEvent(new win.Event('fullscreenchange'));
    return Promise.resolve();
  };
}

// load opens the page and returns it with the handful of accessors the tests
// share. Errors are collected rather than printed: a page that throws during
// bootstrap must fail a test, and jsdom's default is to log and continue.
//
// Pass the test's own `t` and that check is automatic — every test then asserts
// that nothing threw, including the ones whose subject is something else, which is
// where a stray exception would otherwise hide.
//
// Every test loads its own copy. The explorer is one long-lived object graph with
// a `state` the reader mutates, and a suite that shared one page would assert
// about whatever the previous test left selected.
//
// `viewport` is how a test crowds the label pass on purpose: the same map in a
// smaller frame is a harder packing problem, which is what puts the collision claim
// within reach of the five-route fixture as well as the real map.
export function load({ hash = '', t = null, viewport = VIEWPORT, timeline = null } = {}) {
  const errors = [];
  const virtualConsole = new VirtualConsole();
  virtualConsole.on('jsdomError', err => errors.push(err));
  virtualConsole.on('error', (...args) => errors.push(new Error(args.join(' '))));

  let html = readFileSync(PAGE, 'utf8');
  if (timeline) html = withTimeline(html, timeline);
  const dom = new JSDOM(html, {
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    url: 'https://example.invalid/system-map.html' + hash,
    virtualConsole,
    beforeParse: win => polyfill(win, viewport),
  });
  const win = dom.window;
  const doc = win.document;
  if (t) t.after(() => assert.deepEqual(errors.map(String), [], 'the page threw'));
  const p = {
    dom,
    win,
    doc,
    errors,
    viewport,
    // The page is one classic script at global scope, so its `function`s land on
    // `window` but its `const`s do not. Reading them back through eval is how a
    // test asserts about `state`, `view` or `GNODES` without the page having to
    // export anything for the test's benefit.
    peek: expr => win.eval(expr),
    $: sel => doc.querySelector(sel),
    $$: sel => [...doc.querySelectorAll(sel)],
    text: sel => (doc.querySelector(sel) || {}).textContent || '',
    // Typing into the search box, choosing in a select, pressing a button: the
    // page installs `oninput`/`onchange`/`onclick`, so the event has to be
    // dispatched rather than the property called.
    type: (sel, value) => {
      const node = doc.querySelector(sel);
      node.value = value;
      node.dispatchEvent(new win.Event('input'));
    },
    // Assigning a value a `<select>` has no `<option>` for silently leaves it at
    // `''`, which is the "no filter" setting on every select on this page — so a
    // page that stopped offering an identity would still pass a test that chose it
    // and then asserted about an unfiltered table. The value is read back.
    choose: (sel, value) => {
      const node = doc.querySelector(sel);
      node.value = value;
      assert.equal(node.value, value,
        `${sel} has no option ${JSON.stringify(value)}, so choosing it selected nothing`);
      node.dispatchEvent(new win.Event('change'));
    },
    options: sel => [...doc.querySelectorAll(sel + ' option')].map(o => o.value),
    click: node => node.dispatchEvent(clickEvent(win)),
    press: sel => doc.querySelector(sel).dispatchEvent(clickEvent(win)),
    view: name => {
      const b = [...doc.querySelectorAll('.seg button')].find(x => x.dataset.view === name);
      b.dispatchEvent(clickEvent(win));
    },
    // A node click is a pointerdown/pointerup pair that never moved — the page
    // reads a press with no movement as a click, which is what focuses the node.
    clickNode: g => {
      g.dispatchEvent(pointerEvent(win, 'pointerdown', 40, 40));
      g.dispatchEvent(pointerEvent(win, 'pointerup', 40, 40));
    },
    key: name => doc.dispatchEvent(new win.KeyboardEvent('keydown', { key: name, bubbles: true })),
  };
  // A test that wants "a dependency two endpoints reach" is describing a shape the
  // map happens to have. Asking for it here means the miss is a sentence about the
  // map rather than a TypeError on the next line.
  p.pick = (pred, what) => {
    const n = p.peek('GNODES').find(pred);
    assert.ok(n, `this map has no ${what}, so the test cannot run against it`);
    return n;
  };
  p.pickDep = (links = 0) =>
    p.pick(n => n.kind === 'dep' && n.links.length > links,
      `dependency with more than ${links} endpoint${links === 1 ? '' : 's'} reaching it`);
  return p;
}

// The inventory, read straight out of the file. A test that has to build a fixture
// from the map's own facts — a timeline whose endpoints and nodes are ones the head
// revision really has — needs them before the page boots, and booting a throwaway page
// to read a JSON block out of it costs a second per test for nothing.
export function inventory() {
  const html = readFileSync(PAGE, 'utf8');
  const open = html.indexOf('id="inventory">');
  assert.ok(open > 0, 'the page carries no inventory block');
  const from = open + 'id="inventory">'.length;
  return JSON.parse(html.slice(from, html.indexOf('</script>', from)).replace(/<\\\//g, '</'));
}

// The page reads its history out of an embedded JSON block, exactly the way it reads
// its inventory, so a test supplies one by putting a block there. That is deliberate:
// building a real timeline means one full type-check per commit and a checkout with the
// right history in it, neither of which belongs in a DOM test — and the shapes worth
// asserting about (an endpoint that appears, one that vanishes, a wire whose access
// mode changes) are ones a fixture can state exactly and the real repository cannot be
// relied on to contain.
//
// The generator escapes `</` on the way in and the page unescapes it on the way out, so
// the fixture goes through the same encoding the real artifact does.
function withTimeline(html, tl) {
  const at = html.indexOf('</script>', html.indexOf('id="inventory"'));
  assert.ok(at > 0, 'the page has no inventory block to insert a timeline after');
  const json = JSON.stringify(tl).replace(/<\//g, '<\\/');
  return html.slice(0, at + 9) +
    '\n<script type="application/json" id="timeline">' + json + '</script>' +
    html.slice(at + 9);
}

// drag is a press, a move and a release on one element. The page reads the same
// gesture two ways depending on where it starts — on the canvas it pans the view,
// on a node it moves the node inside its own boundary — and both handlers install
// their move/up listeners on the element the press landed on, so the whole gesture
// is dispatched there.
export function drag(p, target, from, to) {
  target.dispatchEvent(pointerEvent(p.win, 'pointerdown', from.x, from.y));
  target.dispatchEvent(pointerEvent(p.win, 'pointermove', to.x, to.y));
  target.dispatchEvent(pointerEvent(p.win, 'pointerup', to.x, to.y));
}

// MouseEvent stands in for PointerEvent: jsdom has no PointerEvent constructor,
// and `clientX`, `clientY` and `pointerId` are all the page's handlers read.
function pointerEvent(win, type, x, y) {
  const ev = new win.MouseEvent(type, { bubbles: true, cancelable: true, clientX: x, clientY: y });
  Object.defineProperty(ev, 'pointerId', { value: 1 });
  return ev;
}

function clickEvent(win) {
  return new win.MouseEvent('click', { bubbles: true, cancelable: true });
}

// visible mirrors what the label pass decides: `placeLabels` hides a label by
// setting `display:none` inline, so a label is shown exactly when it is not.
export const visible = node => node.style.display !== 'none';

// The two ends of an arc, read back out of the `M x y Q cx cy ex ey` the page writes.
// The target end stops short of the circle so its arrowhead lands on the rim instead
// of under the dot, so a test that wants "this wire still reaches that node" has to
// measure the distance rather than match the coordinates.
export function arcEnds(d) {
  const n = d.match(/-?\d+(?:\.\d+)?/g).map(Number);
  return [{ x: n[0], y: n[1] }, { x: n[n.length - 2], y: n[n.length - 1] }];
}
export const touches = (d, n) =>
  arcEnds(d).some(pt => Math.hypot(pt.x - n.x, pt.y - n.y) <= n.r + 2);

// frame waits for one animation frame, which is how the page defers a refit after
// entering or leaving full screen.
export const frame = p => new Promise(resolve => p.win.requestAnimationFrame(() => resolve()));

// drawnTable is a derived table definition the graph has a dot for. Not every table
// does: a table nothing reachable reads has no dependency node, so it is in the
// inventory and in the foreign-key list and yet cannot be selected in the graph. A
// test that wants to open a table's definition has to ask for one that is drawn.
//
// The optional predicate is for a test that needs more than "drawn" — a table with
// foreign keys, say. Taking the first drawn table and then skipping the assertions it
// happens not to satisfy is how a test passes without testing anything.
export function drawnTable(D, want) {
  const drawn = Object.keys(D.tables || {})
    .filter(name => D.tables[name].node && D.nodes[D.tables[name].node]);
  const pick = want ? drawn.find(want) : drawn[0];
  assert.ok(pick, want
    ? 'no drawn table in this map matches what the test needs'
    : 'no derived table in this map has a dependency node to select it by');
  return pick;
}

// searchTerm is a term the map is guaranteed to contain, taken from the data rather
// than invented, so a search test cannot be satisfied by a page that filters
// nothing. A path of "/" has no segment to take, which no map has today and none
// has to acquire silently.
export function searchTerm(D) {
  for (const r of D.routes) {
    const seg = r.path.split('/').filter(Boolean).pop();
    if (seg) return seg.toLowerCase();
  }
  assert.fail('no route in this map has a path segment to search for');
}
