type StoryGestureCallbacks = {
  onStart: () => void;
  onEnd: (travel: number, cancelled: boolean) => void;
};

/** Share one horizontal gesture across the story media and its detail copy. */
export function bindStoryGestures(
  surface: HTMLElement,
  viewport: HTMLElement,
  { onStart, onEnd }: StoryGestureCallbacks,
) {
  const view = surface.ownerDocument.defaultView!;
  let pointer: { id: number; x: number; y: number; scrollLeft: number; started: boolean } | null = null;
  let wheelTimer: number | undefined;
  let wheelStart = 0;
  let suppressClick = false;
  let clickTimer: number | undefined;

  const isControl = (target: EventTarget | null) => target instanceof view.Element &&
    target.closest("button, a, input, textarea, select, video, [contenteditable]") !== null;
  const setDragging = (active: boolean) => {
    surface.classList.toggle("is-dragging", active);
    viewport.classList.toggle("is-dragging", active);
  };
  const finishWheel = () => {
    if (wheelTimer === undefined) return;
    view.clearTimeout(wheelTimer);
    wheelTimer = undefined;
    setDragging(false);
    onEnd(wheelStart - viewport.scrollLeft, false);
  };

  const pointerDown = (event: PointerEvent) => {
    if (event.button !== 0 || !event.isPrimary || isControl(event.target)) return;
    finishWheel();
    suppressClick = false;
    pointer = { id: event.pointerId, x: event.clientX, y: event.clientY, scrollLeft: viewport.scrollLeft, started: false };
  };
  const pointerMove = (event: PointerEvent) => {
    if (!pointer || pointer.id !== event.pointerId) return;
    const x = event.clientX - pointer.x;
    const y = event.clientY - pointer.y;
    if (!pointer.started) {
      if (Math.max(Math.abs(x), Math.abs(y)) < 6) return;
      if (Math.abs(y) > Math.abs(x)) {
        pointer = null;
        return;
      }
      pointer.started = true;
      onStart();
      setDragging(true);
      surface.setPointerCapture?.(event.pointerId);
    }
    viewport.scrollLeft = pointer.scrollLeft - x;
    event.preventDefault();
  };
  const finishPointer = (event: PointerEvent) => {
    if (!pointer || pointer.id !== event.pointerId) return;
    const gesture = pointer;
    pointer = null;
    if (surface.hasPointerCapture?.(event.pointerId)) surface.releasePointerCapture(event.pointerId);
    if (!gesture.started) return;
    setDragging(false);
    suppressClick = true;
    view.clearTimeout(clickTimer);
    clickTimer = view.setTimeout(() => { suppressClick = false; }, 0);
    onEnd(event.clientX - gesture.x, event.type !== "pointerup");
  };
  const click = (event: MouseEvent) => {
    if (!suppressClick) return;
    event.preventDefault();
    event.stopPropagation();
  };
  const wheel = (event: WheelEvent) => {
    if (event.ctrlKey || pointer?.started || isControl(event.target)) return;
    const horizontal = event.shiftKey && !event.deltaX ? event.deltaY : event.deltaX;
    if (!horizontal || (!event.shiftKey && Math.abs(horizontal) <= Math.abs(event.deltaY))) return;
    event.preventDefault();
    if (wheelTimer === undefined) {
      wheelStart = viewport.scrollLeft;
      onStart();
      // Suspend snap while accumulating trackpad deltas; settle once at rest.
      setDragging(true);
    }
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? viewport.clientWidth : 1;
    viewport.scrollLeft += horizontal * unit;
    view.clearTimeout(wheelTimer);
    wheelTimer = view.setTimeout(finishWheel, 140);
  };
  const keyDown = (event: KeyboardEvent) => {
    if (isControl(event.target) || (event.key !== "ArrowLeft" && event.key !== "ArrowRight")) return;
    event.preventDefault();
    finishWheel();
    onStart();
    onEnd(event.key === "ArrowRight" ? -48 : 48, false);
  };

  surface.addEventListener("pointerdown", pointerDown);
  surface.addEventListener("pointermove", pointerMove);
  surface.addEventListener("pointerup", finishPointer);
  surface.addEventListener("pointercancel", finishPointer);
  surface.addEventListener("lostpointercapture", finishPointer);
  surface.addEventListener("click", click, true);
  surface.addEventListener("wheel", wheel, { passive: false });
  surface.addEventListener("keydown", keyDown);
  return () => {
    view.clearTimeout(wheelTimer);
    view.clearTimeout(clickTimer);
    if (pointer && surface.hasPointerCapture?.(pointer.id)) surface.releasePointerCapture(pointer.id);
    setDragging(false);
    surface.removeEventListener("pointerdown", pointerDown);
    surface.removeEventListener("pointermove", pointerMove);
    surface.removeEventListener("pointerup", finishPointer);
    surface.removeEventListener("pointercancel", finishPointer);
    surface.removeEventListener("lostpointercapture", finishPointer);
    surface.removeEventListener("click", click, true);
    surface.removeEventListener("wheel", wheel);
    surface.removeEventListener("keydown", keyDown);
  };
}
