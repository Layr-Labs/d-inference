import assert from "node:assert/strict";
import { afterEach, test } from "node:test";
import { JSDOM } from "jsdom";
import { bindStoryGestures } from "../src/components/storyGestures.ts";

const cleanups = [];
afterEach(() => cleanups.splice(0).forEach((cleanup) => cleanup()));

function fixture() {
  const dom = new JSDOM(`<article><div class="rail"><div>Video</div></div><section><h2>Story title</h2><p>Story text</p><button>Read more</button></section></article>`);
  const surface = dom.window.document.querySelector("article");
  const viewport = surface.querySelector(".rail");
  const text = surface.querySelector("p");
  const ends = [];
  let starts = 0;
  viewport.scrollLeft = 1000;
  const unbind = bindStoryGestures(surface, viewport, {
    onStart: () => { starts++; },
    onEnd: (travel, cancelled) => ends.push({ travel, cancelled }),
  });
  cleanups.push(() => { unbind(); dom.window.close(); });
  const pointer = (target, type, x, y = 0, pointerType = "mouse") => {
    const event = new dom.window.PointerEvent(type, {
      bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0,
      pointerId: 1, isPrimary: true, pointerType,
    });
    target.dispatchEvent(event);
    return event;
  };
  return { dom, surface, viewport, text, ends, pointer, unbind, starts: () => starts };
}

test("dragging the story text moves the same rail as dragging a video", () => {
  for (const content of ["text", "viewport"]) {
    const f = fixture();
    f.pointer(f[content], "pointerdown", 300);
    const move = f.pointer(f[content], "pointermove", 180);
    assert.equal(f.viewport.scrollLeft, 1120);
    assert.equal(move.defaultPrevented, true);
    f.pointer(f[content], "pointerup", 180);
    assert.deepEqual(f.ends, [{ travel: -120, cancelled: false }]);
    assert.equal(f.surface.classList.contains("is-dragging"), false);
  }
});

test("touch swipes navigate from text while vertical touch gestures stay native", () => {
  const f = fixture();
  f.pointer(f.text, "pointerdown", 200, 100, "touch");
  const vertical = f.pointer(f.text, "pointermove", 202, 180, "touch");
  assert.equal(vertical.defaultPrevented, false);
  assert.equal(f.starts(), 0);
  assert.equal(f.viewport.scrollLeft, 1000);
  f.pointer(f.text, "pointerup", 202, 180, "touch");
  f.pointer(f.text, "pointerdown", 200, 100, "touch");
  f.pointer(f.text, "pointermove", 100, 102, "touch");
  f.pointer(f.text, "pointerup", 100, 102, "touch");
  assert.deepEqual(f.ends, [{ travel: -100, cancelled: false }]);
});

test("horizontal trackpad scrolling over text moves the rail, vertical scrolling does not", async () => {
  const f = fixture();
  const vertical = new f.dom.window.WheelEvent("wheel", { deltaY: 100, bubbles: true, cancelable: true });
  f.text.dispatchEvent(vertical);
  assert.equal(vertical.defaultPrevented, false);
  assert.equal(f.viewport.scrollLeft, 1000);
  for (let i = 0; i < 3; i++) {
    const horizontal = new f.dom.window.WheelEvent("wheel", { deltaX: 25, deltaY: 1, bubbles: true, cancelable: true });
    f.text.dispatchEvent(horizontal);
    assert.equal(horizontal.defaultPrevented, true);
  }
  assert.equal(f.viewport.scrollLeft, 1075);
  assert.equal(f.starts(), 1);
  await new Promise((resolve) => setTimeout(resolve, 180));
  assert.deepEqual(f.ends, [{ travel: -75, cancelled: false }]);
});

test("controls and ordinary clicks are not converted into story changes", () => {
  const f = fixture();
  const button = f.surface.querySelector("button");
  f.pointer(button, "pointerdown", 300);
  f.pointer(button, "pointermove", 100);
  f.pointer(button, "pointerup", 100);
  assert.equal(f.starts(), 0);
  const click = new f.dom.window.MouseEvent("click", { bubbles: true, cancelable: true });
  button.dispatchEvent(click);
  assert.equal(click.defaultPrevented, false);
  f.pointer(f.text, "pointerdown", 100);
  f.pointer(f.text, "pointerup", 100);
  assert.deepEqual(f.ends, []);
});

test("cancelled swipes restore the current story and do not trigger click actions", () => {
  const f = fixture();
  f.pointer(f.text, "pointerdown", 300);
  f.pointer(f.text, "pointermove", 100);
  f.pointer(f.text, "pointercancel", 100);
  assert.deepEqual(f.ends, [{ travel: -200, cancelled: true }]);
  const click = new f.dom.window.MouseEvent("click", { bubbles: true, cancelable: true });
  f.text.dispatchEvent(click);
  assert.equal(click.defaultPrevented, true);
});

test("losing pointer capture cancels a swipe and permits the next gesture", () => {
  const f = fixture();
  f.pointer(f.text, "pointerdown", 300);
  f.pointer(f.text, "pointermove", 100);
  f.pointer(f.surface, "lostpointercapture", 100);
  assert.deepEqual(f.ends, [{ travel: -200, cancelled: true }]);
  assert.equal(f.surface.classList.contains("is-dragging"), false);
  f.pointer(f.text, "pointerdown", 100);
  f.pointer(f.text, "pointermove", 200);
  f.pointer(f.text, "pointerup", 200);
  assert.deepEqual(f.ends[1], { travel: 100, cancelled: false });
});

test("arrow keys browse stories without intercepting control keys and cleanup removes listeners", () => {
  const f = fixture();
  f.surface.dispatchEvent(new f.dom.window.KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true, cancelable: true }));
  assert.deepEqual(f.ends, [{ travel: -48, cancelled: false }]);
  const controlKey = new f.dom.window.KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true, cancelable: true });
  f.surface.querySelector("button").dispatchEvent(controlKey);
  assert.equal(controlKey.defaultPrevented, false);
  assert.equal(f.ends.length, 1);
  f.unbind();
  f.pointer(f.text, "pointerdown", 300);
  f.pointer(f.text, "pointermove", 100);
  assert.equal(f.viewport.scrollLeft, 1000);
  assert.equal(f.starts(), 1);
});
