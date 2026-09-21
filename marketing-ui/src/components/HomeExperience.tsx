"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import Image from "next/image";
import { SiteNav } from "./SiteNav";
import { PageWithFooter } from "./Footer";
import { GridMap } from "./GridMap";
import { GridChat, type GridChatHandle } from "./GridChat";
import { STORY_CELL } from "../content/grid";
import { socialLinks, stories } from "../content/site";

type NetworkSnapshot = {
  available: boolean;
  generatedAt?: string;
  tokensServedWindow?: number;
  totalRequests?: number | null;
  tokenWindowLabel?: string;
  activeMacs?: number | null;
  networkEarningsUsd?: number | null;
  earningsWindowLabel?: string;
  stale?: boolean;
  degraded?: boolean;
};

function formatNumber(value: number | null | undefined) {
  if (value == null) return "—";
  if (value >= 1_000_000_000) {
    return `${new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 }).format(value / 1_000_000_000)} billion`;
  }
  if (value >= 1_000_000) {
    return `${new Intl.NumberFormat("en-US", { maximumFractionDigits: 2 }).format(value / 1_000_000)} million`;
  }
  return new Intl.NumberFormat("en-US", { useGrouping: false }).format(value);
}

// Visible immediately during hydration and retained if the live aggregate is
// briefly unreachable. A healthy console response replaces it on mount and
// once per minute; an all-zero response never erases credible grid activity.
const LAST_HEALTHY_NETWORK_SNAPSHOT: NetworkSnapshot = {
  available: true,
  activeMacs: 1231,
  tokensServedWindow: 287_007_823_023,
  totalRequests: 71_962_411,
  tokenWindowLabel: "lifetime",
  stale: true,
  degraded: true,
};

function hasDisplayValue(value: string) {
  return value !== "Not disclosed" && value !== "Not available" && value !== "—";
}

const clamp01 = (value: number) => Math.max(0, Math.min(1, value));
const easeInOutCubic = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const easeOutCubic = (t: number) => 1 - Math.pow(1 - t, 3);

/* The recorded transition uses a fast initial pull and a long, soft settle.
   Resolve the actual cubic-bezier (including its x axis) instead of treating
   the control points as a simple polynomial. */
function cubicBezierAt(progress: number, x1: number, y1: number, x2: number, y2: number) {
  const sample = (t: number, a1: number, a2: number) => {
    const inverse = 1 - t;
    return 3 * inverse * inverse * t * a1 + 3 * inverse * t * t * a2 + t * t * t;
  };
  const slope = (t: number, a1: number, a2: number) =>
    3 * (1 - t) * (1 - t) * a1 + 6 * (1 - t) * t * (a2 - a1) + 3 * t * t * (1 - a2);

  const x = clamp01(progress);
  let t = x;
  for (let index = 0; index < 7; index += 1) {
    const gradient = slope(t, x1, x2);
    if (Math.abs(gradient) < 1e-6) break;
    t = clamp01(t - (sample(t, x1, x2) - x) / gradient);
  }
  return sample(t, y1, y2);
}

const cinematicScrollEase = (progress: number) =>
  cubicBezierAt(progress, 0.62, 0.08, 0.24, 1);

type Story = (typeof stories)[number];

/* R9 scroll beats, as fractions of the hero stage's scroll travel (the stage
   is 700svh tall, so the travel is 600svh). Every visual state of the pinned
   map is a pure function of scroll position; the chat panel is deliberately
   not part of this timeline.
     0 → FLIGHT_END    hero film flies into the map and lands on Figma 66
     ROUTE_START/END   camera zooms to the routed Mac (73)
     CARD_START/END    its connected details unfold beneath the tile (74)
     CHAT_START/END    the card folds, CTA and optional chat enter (75)
   Short holds separate the beats. Movement remains continuously controlled by
   scroll, but a gesture can come to rest on a complete authored frame without
   an automatic snap advancing the next beat. */
const FLIGHT_END = 0.40;
const ROUTE_START = 0.43;
const ROUTE_END = 0.64;
const CARD_START = 0.68;
const CARD_END = 0.75;
const CHAT_START = 0.81;
const CHAT_END = 0.90;
/* Give the final map dive two full viewports of physical travel. This keeps a
   trackpad fling or touch swipe from carrying the user into the story before
   the routed-machine handoff has had time to read. */
const GRID_EXIT_VIEWPORTS = 2;
/* The DOM map only carries the first part of the dive. Its flat portal takes
   over across this overlap and completes the full-screen zoom, allowing the
   map layer to remain warm at a modest scale for a clean reverse gesture. */
const GRID_WORLD_HANDOFF_START = 0.44;
const GRID_WORLD_HANDOFF_END = 0.48;
const LOOPED_STORIES: readonly Story[] = [...stories, ...stories, ...stories];
const FEATURED_STORY_INDEX = 1;
const INITIAL_STORY_LOOP_INDEX = stories.length + FEATURED_STORY_INDEX;

/* The gallery keeps one provider in focus while its neighbours remain visible
   as controls. Story copy lives in a single panel below the rail so changing
   providers feels like moving through one gallery, not three blog posts. */
function StoryGalleryCard({
  story,
  position,
  isClone,
  playing,
  cardRef,
  onSelect,
  onPlay,
}: {
  story: Story;
  position: "before" | "active" | "after";
  isClone: boolean;
  playing: boolean;
  cardRef: (node: HTMLElement | null) => void;
  onSelect: () => void;
  onPlay: () => void;
}) {
  const active = position === "active";
  return (
    <article
      className={`story-gallery-card is-${position}`}
      ref={cardRef}
      role={isClone ? undefined : "button"}
      tabIndex={isClone || active ? -1 : 0}
      aria-hidden={isClone ? true : undefined}
      aria-current={!isClone && active ? "true" : undefined}
      aria-label={isClone ? undefined : `${active ? "Current story" : "View story"}: ${story.headline}`}
      onClick={onSelect}
      onKeyDown={(event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        onSelect();
      }}
    >
      <figure className="story-figure">
        <div className="story-media">
          {playing && story.video ? (
            <video
              className="story-video"
              autoPlay
              controls
              playsInline
              preload="metadata"
              poster={story.image}
              aria-label={story.imageAlt}
              onClick={(event) => event.stopPropagation()}
              onPointerDown={(event) => event.stopPropagation()}
            >
              <source src={story.video} type="video/mp4" />
            </video>
          ) : (
            <>
              <Image src={story.image} alt={story.imageAlt} fill sizes="(max-width: 800px) 84vw, 63vw" />
              {active && !isClone && story.video && (
                <button
                  type="button"
                  className="story-play"
                  aria-label={`Play ${story.mac}'s story`}
                  onPointerDown={(event) => event.stopPropagation()}
                  onClick={(event) => {
                    event.stopPropagation();
                    onPlay();
                  }}
                >
                  <span aria-hidden="true" />
                </button>
              )}
            </>
          )}
        </div>
        <div className="story-meta">
          <div className="story-meta-id">
            <span className="story-meta-mac">{story.mac}</span>
            {hasDisplayValue(story.hardware) && <span className="story-meta-hw">{story.hardware}</span>}
          </div>
          {story.stats.filter((stat) => hasDisplayValue(stat.value)).map((stat) => (
            <div className="story-stat" key={stat.label}>
              <span className="story-stat-label">
                <Image src={`/icons/${stat.icon}.svg`} alt="" width={10} height={10} />
                {stat.label}
              </span>
              <span className="story-stat-value">{stat.value}</span>
            </div>
          ))}
        </div>
      </figure>
    </article>
  );
}

export function HomeExperience() {
  useLayoutEffect(() => {
    if ("scrollRestoration" in window.history) {
      window.history.scrollRestoration = "manual";
    }
    window.scrollTo({ top: 0, left: 0, behavior: "instant" });
  }, []);

  const heroStage = useRef<HTMLDivElement>(null);
  const hero = useRef<HTMLElement>(null);
  const networkSticky = useRef<HTMLDivElement>(null);
  const gridWorld = useRef<HTMLDivElement>(null);
  const gridMapShell = useRef<HTMLDivElement>(null);
  const storySection = useRef<HTMLElement>(null);
  const storyCarousel = useRef<HTMLDivElement>(null);
  const storyCards = useRef<Array<HTMLElement | null>>([]);
  const storyScrollFrame = useRef<number | null>(null);
  const storyLoopTimer = useRef<number | null>(null);
  const storySettlingIndex = useRef<number | null>(null);
  const storyDrag = useRef<{
    active: boolean;
    moved: boolean;
    pointerId: number;
    startIndex: number;
    startScrollLeft: number;
    startX: number;
  }>({
    active: false,
    moved: false,
    pointerId: -1,
    startIndex: INITIAL_STORY_LOOP_INDEX,
    startScrollLeft: 0,
    startX: 0,
  });
  const suppressStoryClick = useRef(false);
  const storyClickResetFrame = useRef<number | null>(null);
  const activeStoryItemRef = useRef<number>(INITIAL_STORY_LOOP_INDEX);
  const activeStoryRef = useRef<Story["slug"]>(stories[FEATURED_STORY_INDEX].slug);
  const closingSection = useRef<HTMLElement>(null);
  const topJump = useRef(false);
  const [network, setNetwork] = useState<NetworkSnapshot>(LAST_HEALTHY_NETWORK_SNAPSHOT);
  const [expandedStories, setExpandedStories] = useState<string[]>([]);
  const [activeStorySlug, setActiveStorySlug] = useState<Story["slug"]>(stories[FEATURED_STORY_INDEX].slug);
  const [activeStoryItemIndex, setActiveStoryItemIndex] = useState<number>(INITIAL_STORY_LOOP_INDEX);
  const [playingStoryItemIndex, setPlayingStoryItemIndex] = useState<number | null>(null);

  const commitStoryItem = useCallback((index: number) => {
    const story = LOOPED_STORIES[index];
    activeStoryItemRef.current = index;
    activeStoryRef.current = story.slug;
    setActiveStoryItemIndex(index);
    setActiveStorySlug(story.slug);
    setPlayingStoryItemIndex((playingIndex) => playingIndex === index ? playingIndex : null);
  }, []);

  const centerStoryItem = useCallback((index: number, behavior: ScrollBehavior = "smooth") => {
    const viewport = storyCarousel.current;
    const card = storyCards.current[index];
    if (!viewport || !card) return;
    storySettlingIndex.current = behavior === "smooth" ? index : null;
    if (behavior !== "smooth") commitStoryItem(index);
    viewport.scrollTo({
      left: card.offsetLeft - (viewport.clientWidth - card.clientWidth) / 2,
      behavior,
    });
  }, [commitStoryItem]);

  const handleStoryScroll = useCallback(() => {
    if (storyScrollFrame.current != null) return;
    storyScrollFrame.current = requestAnimationFrame(() => {
      storyScrollFrame.current = null;
      const viewport = storyCarousel.current;
      if (!viewport) return;

      // Keep the selected media and detail copy stable for the entire mouse
      // gesture. Replacing an active card's image with its video while the rail
      // is moving forces the browser to tear down and recreate media nodes,
      // which presents as a full-content flicker. Programmatic snapping is
      // locked to its destination for the same reason.
      if (storyDrag.current.active || storySettlingIndex.current != null) {
        if (storySettlingIndex.current != null) {
          if (storyLoopTimer.current != null) window.clearTimeout(storyLoopTimer.current);
          storyLoopTimer.current = window.setTimeout(() => {
            const settledIndex = storySettlingIndex.current;
            storySettlingIndex.current = null;
            if (settledIndex == null) return;
            if (settledIndex >= stories.length && settledIndex < stories.length * 2) {
              commitStoryItem(settledIndex);
              return;
            }
            centerStoryItem(stories.length + (settledIndex % stories.length), "auto");
          }, 140);
        }
        return;
      }

      const viewportCenter = viewport.scrollLeft + viewport.clientWidth / 2;
      let closestIndex = activeStoryItemRef.current;
      let closestDistance = Number.POSITIVE_INFINITY;
      LOOPED_STORIES.forEach((_story, index) => {
        const card = storyCards.current[index];
        if (!card) return;
        const cardCenter = card.offsetLeft + card.clientWidth / 2;
        const distance = Math.abs(cardCenter - viewportCenter);
        if (distance < closestDistance) {
          closestIndex = index;
          closestDistance = distance;
        }
      });
      commitStoryItem(closestIndex);

      if (storyDrag.current.active) return;
      if (storyLoopTimer.current != null) window.clearTimeout(storyLoopTimer.current);
      storyLoopTimer.current = window.setTimeout(() => {
        if (closestIndex >= stories.length && closestIndex < stories.length * 2) return;
        const middleIndex = stories.length + (closestIndex % stories.length);
        centerStoryItem(middleIndex, "auto");
      }, 140);
    });
  }, [centerStoryItem, commitStoryItem]);

  const handleStoryPointerDown = useCallback((event: React.PointerEvent<HTMLDivElement>) => {
    if (event.pointerType !== "mouse" || event.button !== 0) return;
    const viewport = storyCarousel.current;
    if (!viewport) return;
    if (storyLoopTimer.current != null) window.clearTimeout(storyLoopTimer.current);
    storySettlingIndex.current = null;
    storyDrag.current = {
      active: true,
      moved: false,
      pointerId: event.pointerId,
      startIndex: activeStoryItemRef.current,
      startScrollLeft: viewport.scrollLeft,
      startX: event.clientX,
    };
    viewport.classList.add("is-dragging");
    try {
      viewport.setPointerCapture(event.pointerId);
    } catch {
      // Pointer capture is unavailable for synthetic or legacy pointer events;
      // the gesture still works while the pointer remains over the rail.
    }
  }, []);

  const handleStoryPointerMove = useCallback((event: React.PointerEvent<HTMLDivElement>) => {
    const viewport = storyCarousel.current;
    const drag = storyDrag.current;
    if (!viewport || !drag.active || drag.pointerId !== event.pointerId) return;
    const travel = event.clientX - drag.startX;
    if (Math.abs(travel) > 4) drag.moved = true;
    viewport.scrollLeft = drag.startScrollLeft - travel;
    event.preventDefault();
  }, []);

  const finishStoryDrag = useCallback((event: React.PointerEvent<HTMLDivElement>, cancelled = false) => {
    const viewport = storyCarousel.current;
    const drag = storyDrag.current;
    if (!viewport || !drag.active || drag.pointerId !== event.pointerId) return;
    const travel = event.clientX - drag.startX;
    const moved = drag.moved;
    const startIndex = drag.startIndex;
    drag.active = false;
    viewport.classList.remove("is-dragging");
    if (viewport.hasPointerCapture(event.pointerId)) viewport.releasePointerCapture(event.pointerId);

    if (moved) {
      suppressStoryClick.current = true;
      if (storyClickResetFrame.current != null) cancelAnimationFrame(storyClickResetFrame.current);
      storyClickResetFrame.current = requestAnimationFrame(() => {
        suppressStoryClick.current = false;
        storyClickResetFrame.current = null;
      });
    }

    const direction = travel < 0 ? 1 : -1;
    const targetIndex = !cancelled && Math.abs(travel) >= 48
      ? Math.max(0, Math.min(LOOPED_STORIES.length - 1, startIndex + direction))
      : startIndex;
    centerStoryItem(targetIndex);
  }, [centerStoryItem]);

  useEffect(() => {
    const viewport = storyCarousel.current;
    if (!viewport) return;
    const align = () => centerStoryItem(activeStoryItemRef.current, "auto");
    const frame = requestAnimationFrame(align);
    const observer = new ResizeObserver(align);
    observer.observe(viewport);
    return () => {
      cancelAnimationFrame(frame);
      observer.disconnect();
      if (storyScrollFrame.current != null) cancelAnimationFrame(storyScrollFrame.current);
      if (storyLoopTimer.current != null) window.clearTimeout(storyLoopTimer.current);
      if (storyClickResetFrame.current != null) cancelAnimationFrame(storyClickResetFrame.current);
    };
  }, [centerStoryItem]);

  const walkthrough = useRef({ top: 0, travel: 1 });
  const chat = useRef<GridChatHandle>(null);

  // One scroll position maps to one visual state in both directions. Wheel,
  // keyboard and back-to-top input are already smoothed at the document level;
  // adding a second spring here made the pinned map keep moving after scroll
  // had stopped and produced different frames on the way back up. Keep this
  // layer deterministic and only batch DOM writes into one RAF per scroll.
  useEffect(() => {
    let frame = 0;
    const progress = { hero: 0, grid: 0, story: 0 };
    const layout = { heroTop: 0, heroTravel: 1, storyTop: 0, closingTop: 0 };
    let geometry: { sx: number; sy: number; ox: number; oy: number; cx: number; cy: number; w: number; h: number; scx: number; scy: number; shellLeft: number; shellTop: number; shellWidth: number; vw: number; vh: number } | null = null;
    let geometryWidth = -1;
    let geometryHeight = -1;
    let lastStoryBackground = "";
    let lastClosingBackground = "";

    const writeVar = (element: HTMLElement, name: string, value: string) => {
      if (element.style.getPropertyValue(name) !== value) element.style.setProperty(name, value);
    };
    const setFlag = (element: HTMLElement, name: string, enabled: boolean) => {
      if (enabled) {
        if (element.getAttribute(name) !== "true") element.setAttribute(name, "true");
      } else if (element.hasAttribute(name)) {
        element.removeAttribute(name);
      }
    };

    const measureGeometry = (viewport: number) => {
      const vw = window.innerWidth;
      if (geometry && geometryWidth === vw && geometryHeight === viewport) return;
      geometryWidth = vw;
      geometryHeight = viewport;
      const desktop = vw > 800;
      const world = gridWorld.current;
      const shell = gridMapShell.current;
      const shellW = shell?.offsetWidth ?? (desktop ? Math.min(vw * 0.89116, 1283.27) : vw * 1.38633458);
      const shellH = shell?.offsetHeight ?? shellW / (1283.27 / 638.023);
      // The composited world is deliberately only as large as the map. Its
      // layout offsets are stable even while its transform is scroll-driven,
      // unlike getBoundingClientRect(), which includes the live camera move.
      const shellLeft = world?.offsetLeft ?? (desktop ? vw * (92 / 1440) : vw * -0.18656716);
      const shellTop = world?.offsetTop ?? viewport * (desktop ? 109.734 / 835 : 0.45892019);
      const tileW = shellW * 0.015338;
      const tileH = shellH * 0.019512;
      // The hero film lands on the tile the intro was authored around.
      const tileCx = shellLeft + shellW * 0.538529 + tileW / 2;
      const tileCy = shellTop + shellH * 0.329188 + tileH / 2;
      // The camera then routes to (and later dives through) STORY_CELL.
      const scx = shellLeft + shellW * (STORY_CELL.x / 100) + tileW / 2;
      const scy = shellTop + shellH * (STORY_CELL.y / 100) + tileH / 2;
      const sx = tileW / vw;
      const sy = tileH / viewport;
      const ox = (tileCx - sx * (vw / 2)) / (1 - sx);
      const oy = (tileCy - sy * (viewport / 2)) / (1 - sy);
      geometry = { sx, sy, ox, oy, cx: tileCx, cy: tileCy, w: tileW, h: tileH, scx, scy, shellLeft, shellTop, shellWidth: shellW, vw, vh: viewport };
    };

    const measureLayout = () => {
      const viewport = window.innerHeight;
      measureGeometry(viewport);
      const scroll = window.scrollY;
      if (heroStage.current) {
        const rect = heroStage.current.getBoundingClientRect();
        layout.heroTop = rect.top + scroll;
        layout.heroTravel = Math.max(1, rect.height - viewport);
        walkthrough.current = { top: layout.heroTop, travel: layout.heroTravel };
      }
      if (storySection.current) {
        const rect = storySection.current.getBoundingClientRect();
        layout.storyTop = rect.top + scroll;
      }
      if (closingSection.current) {
        const rect = closingSection.current.getBoundingClientRect();
        layout.closingTop = rect.top + scroll;
      }
    };

    // Scroll events only read scrollY and cached document geometry. Avoiding
    // getBoundingClientRect here prevents forced layout after compositor writes.
    const measure = () => {
      const viewport = window.innerHeight;
      const scroll = window.scrollY;
      const gridExitTravel = Math.max(1, viewport * GRID_EXIT_VIEWPORTS);
      progress.hero = clamp01((scroll - layout.heroTop) / layout.heroTravel);
      progress.grid = clamp01((scroll + gridExitTravel - layout.storyTop) / gridExitTravel);
      progress.story = clamp01((scroll + viewport - layout.closingTop) / Math.max(1, viewport));
    };

    const paint = () => {
      const heroNode = hero.current;
      const networkNode = networkSticky.current;
      const storyNode = storySection.current;
      const closingNode = closingSection.current;
      if (!geometry || !heroNode || !networkNode || !storyNode || !closingNode) return;

      const heroExit = progress.hero;
      const gridExit = progress.grid;
      // The story→closing transition is carried entirely by native scroll
      // (the closing slides in as a normal next section), so everything tied
      // to it — shade, blackout, media fades — keys off raw scroll to stay
      // exactly in phase with that motion.
      const storyExit = progress.story;

      const heroFlight = easeInOutCubic(clamp01(heroExit / FLIGHT_END));
      const gridIntro = easeOutCubic(clamp01((heroExit - 0.08) / (FLIGHT_END - 0.08)));
      const routeRaw = clamp01((heroExit - ROUTE_START) / (ROUTE_END - ROUTE_START));
      const routeProgress = easeInOutCubic(routeRaw);
      const chatRaw = clamp01((heroExit - CHAT_START) / (CHAT_END - CHAT_START));
      const chatReveal = easeOutCubic(chatRaw);
      const desktopGrid = geometry.vw > 800;

      // Treat the two headlines as one vertical conveyor. The first travels
      // fully beyond the top edge while the second arrives from below, and
      // both share the exact same resting anchor. A viewport-scale journey is
      // long enough to keep the copy from crossing over itself mid-scroll.
      const narrativeTravel = geometry.vh * (desktopGrid ? 0.54 : 0.48);
      const overviewY = -narrativeTravel * routeProgress;
      const overviewOpacity = 1 - easeOutCubic(clamp01((routeRaw - 0.62) / 0.38));
      const routeY = narrativeTravel * (1 - routeProgress);
      const routeOpacity = easeOutCubic(clamp01(routeRaw / 0.38));
      // The selected tile stays blue during the opening part of the camera
      // move, then turns white near the middle instead of flashing early.
      const tileWhite = easeInOutCubic(clamp01((routeRaw - 0.36) / 0.38));
      // The provider detail is its own authored beat after the camera lands.
      // It folds away again as the independent chat surface arrives.
      const cardRaw = clamp01((heroExit - CARD_START) / (CARD_END - CARD_START));
      const cardOpen = easeOutCubic(cardRaw);
      const cardFold = easeInOutCubic(clamp01(chatRaw / 0.5));
      const providerReveal = cardOpen * (1 - cardFold);

      // Frame 66 → 67 in the updated Figma: the map grows 2.8076× and the
      // routed tile ends centred at (811, 405.5) on the 1440×835 reference
      // frame, with its bottom aligned to the second line of the headline. Both are
      // expressed relative to the viewport (not as a fixed group offset) so
      // the camera lands on the tile at every aspect ratio; the map shell's
      // own position is measured, never assumed.
      const responsiveMapFactor = (geometry.vw / 1440) / (geometry.shellWidth / 1283.2701416015625);
      const routeScale = desktopGrid ? 2.807613 * responsiveMapFactor : 5.39123;
      const routeZoom = Math.pow(routeScale, routeProgress);
      const storyLocalX = geometry.scx - geometry.shellLeft;
      const storyLocalY = geometry.scy - geometry.shellTop;
      // Preserve the Figma relationship as the viewport changes: the target
      // is offset from the headline anchor, rather than scaled away from it.
      // This keeps the tile's bottom aligned with the text at non-reference
      // desktop heights too.
      const routeTargetX = desktopGrid
        ? geometry.vw * (160 / 1440) + (811 - 160)
        : geometry.vw * (110.05 / 402);
      const routeTargetY = desktopGrid
        ? geometry.vh * (328 / 835) + (405.5 - 328)
        : geometry.vh * (424 / 852);
      // The selected tile follows one eased path while the map grows
      // exponentially around it; both endpoints are the exact Figma frames.
      const routeCenterX = geometry.scx + (routeTargetX - geometry.scx) * routeProgress;
      const routeCenterY = geometry.scy + (routeTargetY - geometry.scy) * routeProgress;

      // Story dive (Figma 68 → 70): the DOM map starts the move, then a flat
      // portal takes over and grows the routed tile until it covers the frame
      // (76.35× on the reference frame). Keeping the DOM map parked at the
      // handoff scale avoids rebuilding an enormous composited layer when a
      // fast reverse gesture returns from the story.
      const portalDive = Math.pow(clamp01((gridExit - 0.08) / 0.78), 2.0);
      const mapExit = Math.min(gridExit, GRID_WORLD_HANDOFF_END);
      const mapDive = Math.pow(clamp01((mapExit - 0.08) / 0.78), 2.0);
      const diveScale = Math.max(geometry.vw / geometry.w, geometry.vh / geometry.h) * 1.06;
      const portalZoom = routeZoom * Math.pow(diveScale / routeZoom, portalDive);
      const mapZoom = routeZoom * Math.pow(diveScale / routeZoom, mapDive);
      const finalTargetX = geometry.vw / 2;
      const finalTargetY = geometry.vh / 2;
      const portalCenterX = routeCenterX + (finalTargetX - routeCenterX) * portalDive;
      const portalCenterY = routeCenterY + (finalTargetY - routeCenterY) * portalDive;
      const mapCenterX = routeCenterX + (finalTargetX - routeCenterX) * mapDive;
      const mapCenterY = routeCenterY + (finalTargetY - routeCenterY) * mapDive;
      const portalGroupLeft = portalCenterX - storyLocalX * portalZoom;
      const portalGroupTop = portalCenterY - storyLocalY * portalZoom;
      const mapGroupLeft = mapCenterX - storyLocalX * mapZoom;
      const mapGroupTop = mapCenterY - storyLocalY * mapZoom;
      // .grid-world now starts at the map's own layout origin rather than
      // spanning the viewport. Translate from that origin while preserving
      // the exact same camera path.
      const portalPanX = portalGroupLeft - geometry.shellLeft;
      const portalPanY = portalGroupTop - geometry.shellTop;
      const mapPanX = mapGroupLeft - geometry.shellLeft;
      const mapPanY = mapGroupTop - geometry.shellTop;
      const chatFold = easeInOutCubic(clamp01(gridExit / 0.5));
      const chromeFade = 1 - easeOutCubic(clamp01(gridExit / 0.32));
      // Hold the routed screen white through the initial approach, then blend
      // it to blue across the middle of the dive. The portal inherits this
      // same live colour, so taking over from the DOM tile cannot introduce a
      // second, premature blue flash.
      const tileBlue = easeInOutCubic(clamp01((gridExit - 0.32) / 0.28));
      const tileColor = [255, 255, 255]
        .map((channel, index) => Math.round(channel + ([11, 68, 255][index] - channel) * tileBlue))
        .join(" ");
      // Seal the portal before the gallery appears. Frame 70 is a clean blue
      // field with only the global nav; letting the gallery enter during the
      // zoom skips that authored beat.
      const storyCover = easeOutCubic(clamp01((gridExit - 0.88) / 0.12));
      const storyEntry = easeOutCubic(clamp01((gridExit - 0.975) / 0.025));
      const storyPortalCx = geometry.shellLeft + portalPanX + storyLocalX * portalZoom;
      const storyPortalCy = geometry.shellTop + portalPanY + storyLocalY * portalZoom;
      // The portal must stay indistinguishable from the real tile during the
      // overlap, then continues the same path after the DOM map is parked.
      const storyPortalWidth = geometry.w * portalZoom;
      const storyPortalHeight = geometry.h * portalZoom;
      const routeTileLeft = storyPortalCx - geometry.w * portalZoom / 2;
      const routeTileTop = storyPortalCy - geometry.h * portalZoom / 2;
      // Carry the story plane from blue → navy → black before the final
      // section arrives. The final section itself stays black.
      const storyShade = easeInOutCubic(clamp01((storyExit - 0.02) / 0.72));
      const storyBlack = easeInOutCubic(clamp01((storyExit - 0.08) / 0.90));
      const closingCopyEntry = easeOutCubic(clamp01((storyExit - 0.08) / 0.5));
      const closingMediaEntry = easeOutCubic(clamp01((storyExit - 0.18) / 0.58));
      const storyColorRgb = [11, 65, 255]
        .map((channel, index) => {
          const navy = [6, 27, 88][index];
          return Math.round((channel + (navy - channel) * storyShade) * (1 - storyBlack));
        })
        .join(" ");
      const storyBackground = `rgb(${storyColorRgb} / ${storyCover.toFixed(5)})`;

      setFlag(heroNode, "data-dimmed", heroFlight > 0.2);
      setFlag(heroNode, "data-exited", heroFlight > 0.985);
      setFlag(heroNode, "data-transitioning", heroFlight > 0.001 && heroFlight < 0.999);
      // The mobile nav blur (R4) should only show while the hero copy is
      // actually crossing behind the nav — the copy is fully dissolved by
      // ~60% of the exit, well before the map screens.
      setFlag(heroNode, "data-copy-crossing", heroFlight > 0.1 && heroFlight < 0.62);
      writeVar(heroNode, "--hero-exit", heroFlight.toFixed(5));
      writeVar(heroNode, "--hero-scale-x", Math.pow(geometry.sx, heroFlight).toFixed(6));
      writeVar(heroNode, "--hero-scale-y", Math.pow(geometry.sy, heroFlight).toFixed(6));
      writeVar(heroNode, "--hero-origin", `${geometry.ox.toFixed(1)}px ${geometry.oy.toFixed(1)}px`);

      setFlag(networkNode, "data-veiled", heroFlight < 0.86);
      setFlag(networkNode, "data-route-focused", routeRaw > 0.001);
      setFlag(networkNode, "data-route-settled", routeRaw > 0.999);
      setFlag(networkNode, "data-chat-visible", chatRaw > 0.001);
      setFlag(networkNode, "data-chat-ready", chatRaw > 0.5 && gridExit < 0.2);
      setFlag(networkNode, "data-prompt-ready", chatRaw > 0.5 && gridExit < 0.2);
      setFlag(networkNode, "data-exiting", gridExit > 0.001);
      setFlag(networkNode, "data-zooming", gridExit > 0.001 && gridExit < 0.999);
      writeVar(networkNode, "--grid-intro", gridIntro.toFixed(5));
      writeVar(networkNode, "--route-progress", routeProgress.toFixed(5));
      writeVar(networkNode, "--overview-y", `${overviewY.toFixed(2)}px`);
      writeVar(networkNode, "--overview-opacity", overviewOpacity.toFixed(5));
      writeVar(networkNode, "--route-y", `${routeY.toFixed(2)}px`);
      writeVar(networkNode, "--route-opacity", routeOpacity.toFixed(5));
      writeVar(networkNode, "--cta-reveal", chatReveal.toFixed(5));
      writeVar(networkNode, "--tile-white", tileWhite.toFixed(5));
      writeVar(networkNode, "--provider-reveal", providerReveal.toFixed(5));
      writeVar(networkNode, "--chat-reveal", chatReveal.toFixed(5));
      writeVar(networkNode, "--prompt-reveal", chatReveal.toFixed(5));
      writeVar(networkNode, "--chat-fold", chatFold.toFixed(5));
      writeVar(networkNode, "--chrome-fade", chromeFade.toFixed(5));
      writeVar(networkNode, "--grid-exit", gridExit.toFixed(5));
      writeVar(networkNode, "--grid-world-opacity", clamp01((GRID_WORLD_HANDOFF_END - gridExit) / (GRID_WORLD_HANDOFF_END - GRID_WORLD_HANDOFF_START)).toFixed(5));
      writeVar(networkNode, "--grid-zoom", mapZoom.toFixed(5));
      writeVar(networkNode, "--grid-pan-x", `${mapPanX.toFixed(2)}px`);
      writeVar(networkNode, "--grid-pan-y", `${mapPanY.toFixed(2)}px`);
      writeVar(networkNode, "--tile-cx", `${geometry.cx.toFixed(1)}px`);
      writeVar(networkNode, "--tile-cy", `${geometry.cy.toFixed(1)}px`);
      writeVar(networkNode, "--story-cx", `${geometry.scx.toFixed(1)}px`);
      writeVar(networkNode, "--story-cy", `${geometry.scy.toFixed(1)}px`);
      writeVar(networkNode, "--story-tile-color", tileColor);
      writeVar(networkNode, "--route-tile-left", `${routeTileLeft.toFixed(2)}px`);
      writeVar(networkNode, "--route-tile-top", `${routeTileTop.toFixed(2)}px`);
      writeVar(networkNode, "--route-tile-right", `${(routeTileLeft + geometry.w * portalZoom).toFixed(2)}px`);
      writeVar(networkNode, "--route-tile-bottom", `${(routeTileTop + geometry.h * portalZoom).toFixed(2)}px`);
      writeVar(networkNode, "--route-tile-width", `${(geometry.w * portalZoom).toFixed(2)}px`);
      writeVar(networkNode, "--story-portal-cx", `${storyPortalCx.toFixed(2)}px`);
      writeVar(networkNode, "--story-portal-cy", `${storyPortalCy.toFixed(2)}px`);
      writeVar(networkNode, "--story-portal-width", `${storyPortalWidth.toFixed(2)}px`);
      writeVar(networkNode, "--story-portal-height", `${storyPortalHeight.toFixed(2)}px`);

      writeVar(storyNode, "--story-entry", storyEntry.toFixed(5));
      writeVar(storyNode, "--story-exit", storyExit.toFixed(5));
      if (lastStoryBackground !== storyBackground) {
        lastStoryBackground = storyBackground;
        storyNode.style.backgroundColor = storyBackground;
      }
      const closingBackground = `rgb(${storyColorRgb})`;
      if (lastClosingBackground !== closingBackground) {
        lastClosingBackground = closingBackground;
        closingNode.style.backgroundColor = closingBackground;
      }

      writeVar(closingNode, "--closing-copy-opacity", closingCopyEntry.toFixed(5));
      writeVar(closingNode, "--closing-copy-rise", `${((1 - closingCopyEntry) * 52).toFixed(2)}px`);
      writeVar(closingNode, "--closing-media-opacity", closingMediaEntry.toFixed(5));
      writeVar(closingNode, "--closing-media-rise", `${((1 - closingMediaEntry) * 68).toFixed(2)}px`);
      setFlag(closingNode, "data-settled", storyExit > 0.08);
    };

    const step = () => {
      frame = 0;
      paint();
      if (topJump.current && window.scrollY <= 1) topJump.current = false;
    };
    const queueUpdate = () => {
      measure();
      if (!frame) frame = requestAnimationFrame(step);
    };
    const handleResize = () => {
      measureLayout();
      queueUpdate();
    };
    const handleTopJump = () => {
      topJump.current = true;
      queueUpdate();
    };
    const layoutObserver = new ResizeObserver(handleResize);
    if (heroStage.current) layoutObserver.observe(heroStage.current);
    if (storySection.current) layoutObserver.observe(storySection.current);
    if (closingSection.current) layoutObserver.observe(closingSection.current);
    measureLayout();
    queueUpdate();
    window.addEventListener("scroll", queueUpdate, { passive: true });
    window.addEventListener("resize", handleResize);
    window.addEventListener("darkbloom:scroll-top", handleTopJump);
    return () => {
      if (frame) cancelAnimationFrame(frame);
      layoutObserver.disconnect();
      window.removeEventListener("scroll", queueUpdate);
      window.removeEventListener("resize", handleResize);
      window.removeEventListener("darkbloom:scroll-top", handleTopJump);
    };
  }, []);

  // Held Space would otherwise hammer page-down jumps through the scroll
  // choreography; glide at a constant readable rate instead (time-based, so
  // display refresh rate doesn't change the speed). Interactive elements keep
  // their native Space behaviour.
  useEffect(() => {
    const SPEED = 760; // px per second — roughly one viewport per second
    let frame = 0;
    let direction = 0;
    let lastTime = 0;
    const step = (time: number) => {
      frame = 0;
      if (!direction) return;
      const dt = Math.min(64, time - lastTime);
      lastTime = time;
      window.scrollBy({ top: direction * SPEED * (dt / 1000), behavior: "instant" });
      frame = requestAnimationFrame(step);
    };
    const isInteractive = (target: EventTarget | null) =>
      target instanceof Element && target.closest("input, textarea, select, button, a, [contenteditable]") != null;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.defaultPrevented || event.code !== "Space" || event.metaKey || event.ctrlKey || event.altKey || isInteractive(event.target)) return;
      event.preventDefault();
      direction = event.shiftKey ? -1 : 1;
      if (!frame) {
        lastTime = performance.now();
        frame = requestAnimationFrame(step);
      }
    };
    const onKeyUp = (event: KeyboardEvent) => {
      if (event.code === "Space") direction = 0;
    };
    window.addEventListener("keydown", onKeyDown, { passive: false });
    window.addEventListener("keyup", onKeyUp);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      window.removeEventListener("keyup", onKeyUp);
      if (frame) cancelAnimationFrame(frame);
    };
  }, []);

  const loadNetwork = useCallback(async () => {
    try {
      const response = await fetch("/api/network", { cache: "no-store" });
      const payload = (await response.json()) as NetworkSnapshot;
      if (!response.ok) throw new Error("Network snapshot unavailable");
      if (
        !payload.available ||
        (payload.activeMacs ?? 0) <= 0 ||
        (payload.tokensServedWindow ?? 0) <= 0 ||
        (payload.totalRequests ?? 0) <= 0
      ) {
        throw new Error("Network snapshot is incomplete");
      }
      setNetwork(payload);
    } catch {
      // Keep the last healthy snapshot visible. Transient telemetry downtime
      // should not make a demonstrably active network disappear from the UI.
    }
  }, []);

  useEffect(() => {
    const initial = window.setTimeout(() => void loadNetwork(), 0);
    const interval = window.setInterval(() => {
      if (document.visibilityState === "visible") void loadNetwork();
    }, 60_000);
    return () => {
      window.clearTimeout(initial);
      window.clearInterval(interval);
    };
  }, [loadNetwork]);

  // Keep the map choreography continuously tied to physical scroll. Earlier
  // step-to-stop animations could keep advancing after the user's gesture had
  // ended, which made the route/card/chat beats feel automatic. This restrained
  // Lenis-style damping preserves fine control and never invents extra travel.
  useEffect(() => {
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let target = window.scrollY;
    let current = window.scrollY;
    let frame = 0;
    let topFrame = 0;
    let lastTime = 0;
    let lastWritten = -1;
    let topLastWritten = -1;
    let nativeGestureUntil = 0;
    let lastWheelAt = 0;
    const NATIVE_GESTURE_MS = 300;

    const maxScroll = () => {
      const doc = document.scrollingElement ?? document.documentElement;
      return Math.max(0, doc.scrollHeight - window.innerHeight);
    };
    const stop = () => {
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
      lastTime = 0;
      lastWritten = -1;
    };
    const stopTop = (resetJump = false) => {
      if (topFrame) cancelAnimationFrame(topFrame);
      topFrame = 0;
      topLastWritten = -1;
      if (resetJump) topJump.current = false;
    };
    const yieldToBrowser = (now: number) => {
      nativeGestureUntil = now + NATIVE_GESTURE_MS;
      stop();
      current = target = window.scrollY;
    };
    const step = (time: number) => {
      const actual = window.scrollY;
      if (lastWritten >= 0 && Math.abs(actual - lastWritten) > 2) {
        stop();
        current = target = actual;
        if (time - lastWheelAt < NATIVE_GESTURE_MS) yieldToBrowser(time);
        return;
      }
      const dt = Math.min(50, lastTime ? time - lastTime : 16.7) / 1000;
      lastTime = time;
      current += (target - current) * (1 - Math.exp(-6 * dt));
      if (Math.abs(target - current) < 0.5) current = target;
      window.scrollTo({ top: current, behavior: "instant" });
      lastWritten = window.scrollY;
      if (current === target) {
        stop();
        return;
      }
      frame = requestAnimationFrame(step);
    };
    const start = () => {
      if (!frame) {
        lastTime = 0;
        frame = requestAnimationFrame(step);
      }
    };

    const innerScrollerTakes = (node: EventTarget | null, deltaY: number) => {
      let element = node instanceof Element ? node : null;
      while (element && element !== document.body) {
        if (
          element.scrollHeight > element.clientHeight + 1 &&
          /(auto|scroll)/.test(getComputedStyle(element).overflowY)
        ) {
          const room = deltaY > 0
            ? element.scrollTop + element.clientHeight < element.scrollHeight - 1
            : element.scrollTop > 0;
          if (room) return true;
        }
        element = element.parentElement;
      }
      return false;
    };

    const handleWheel = (event: WheelEvent) => {
      if (topFrame) stopTop(true);
      if (event.defaultPrevented || event.ctrlKey) return;
      const now = performance.now();

      // Chrome can latch a non-cancelable gesture to native scrolling. Never
      // let the native compositor and our damped scroll write scrollY at once.
      if (!event.cancelable || now < nativeGestureUntil) {
        yieldToBrowser(now);
        return;
      }
      lastWheelAt = now;
      if (Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
      if (!event.deltaY) {
        event.preventDefault();
        return;
      }
      if (innerScrollerTakes(event.target, event.deltaY)) return;

      event.preventDefault();
      const delta = event.deltaMode === 1
        ? event.deltaY * 16
        : event.deltaMode === 2
          ? event.deltaY * window.innerHeight
          : event.deltaY;
      if (!frame) current = target = window.scrollY;
      target = Math.max(0, Math.min(maxScroll(), target + delta));
      start();
    };

    const handleTopJump = (event: Event) => {
      event.preventDefault();
      stop();
      current = target = window.scrollY;
      stopTop();
      if (reduceMotion || current <= 1) {
        window.scrollTo({ top: 0, behavior: "instant" });
        return;
      }

      const startY = current;
      const duration = Math.min(
        2_600,
        Math.max(1_200, 1_100 + (startY / Math.max(1, window.innerHeight)) * 170),
      );
      let startedAt = 0;
      const stepTop = (time: number) => {
        const actual = window.scrollY;
        if (topLastWritten >= 0 && Math.abs(actual - topLastWritten) > 2) {
          stopTop(true);
          current = target = actual;
          return;
        }
        if (!startedAt) startedAt = time;
        const progress = clamp01((time - startedAt) / duration);
        const eased = cinematicScrollEase(progress);
        const nextY = progress === 1 ? 0 : startY * (1 - eased);
        window.scrollTo({ top: nextY, behavior: "instant" });
        topLastWritten = window.scrollY;
        current = target = topLastWritten;
        if (progress === 1) {
          stopTop();
          return;
        }
        topFrame = requestAnimationFrame(stepTop);
      };
      topFrame = requestAnimationFrame(stepTop);
    };

    if (!reduceMotion) {
      window.addEventListener("wheel", handleWheel, { passive: false });
    }
    window.addEventListener("darkbloom:scroll-top", handleTopJump);
    return () => {
      stop();
      stopTop();
      window.removeEventListener("wheel", handleWheel);
      window.removeEventListener("darkbloom:scroll-top", handleTopJump);
    };
  }, []);
  const activeStory = stories.find((story) => story.slug === activeStorySlug) ?? stories[FEATURED_STORY_INDEX];
  const activeStoryExpanded = expandedStories.includes(activeStory.slug);
  const activeStoryCopyId = `story-copy-${activeStory.slug}`;
  const activeStorySummary = activeStory.summary;

  return (
    <PageWithFooter className="home">
      <div className="landing-curtain" aria-label="Darkbloom, powered by Eigen Labs">
        <div className="landing-curtain-panel">
          <span className="landing-curtain-logo" aria-hidden="true" />
          <p className="landing-curtain-credit">
            <span>powered by</span>{" "}
            <a href="https://www.eigenlabs.org/" target="_blank" rel="noreferrer">Eigen Labs, Inc.</a>
          </p>
        </div>
      </div>
      <SiteNav />
      <div className="hero-stage" ref={heroStage}>
        <section
          className="hero"
          aria-labelledby="hero-title"
          ref={hero}
        >
          <div className="hero-film" aria-hidden="true">
            <video
              className="hero-film-video"
              autoPlay
              loop
              muted
              playsInline
              preload="auto"
              poster="/media/hero-film-r7-poster.png"
              width={1920}
              height={1080}
            >
              <source src="/media/hero-film-r7.mp4" type="video/mp4" />
            </video>
            <div className="hero-film-blue" />
            <div className="hero-film-grain" />
          </div>
          <div className="hero-copy">
            <h1 id="hero-title">The compute grid<br />powered by people.</h1>
            <p>For the innovators pushing the frontier.</p>
            <a className="text-link" href="https://console.darkbloom.dev/" target="_blank" rel="noreferrer">
              Join the grid ↗
            </a>
          </div>
          <p className="hero-copyright">
            <span>Copyright ©2026</span>
            <a href="https://www.eigenlabs.org/" target="_blank" rel="noreferrer">Eigen Labs, Inc.</a>
          </p>
          <div className="hero-social">
            {socialLinks.map((link) => (
              <a key={link.label} href={link.href} target="_blank" rel="noreferrer">{link.label}</a>
            ))}
          </div>
          <a className="scroll-cue" href="#network" aria-label="Scroll to the live grid">Scroll ↓</a>
        </section>
      </div>

      <section className="network-stage" id="network" aria-labelledby="network-title">
        <div
          className="network-sticky"
          ref={networkSticky}
        >
          <h2 id="network-title" className="sr-only">The Darkbloom live Mac grid</h2>
          <div className="network-live-badge" aria-hidden="true">
            <i className="pulse-dot" />
            <span>Live grid</span>
          </div>
          <div className="network-narrative">
            <p className="network-overview-title">Not a data center.<br />A network of people.</p>
            <div className="network-route-copy">
              <p>Every request,<br />routed to a real machine.</p>
              <button
                type="button"
                className="network-route-cta"
                onClick={() => chat.current?.focus()}
              >
                See it route, right now <span className="route-arrow is-desktop" aria-hidden="true">→</span><span className="route-arrow is-mobile" aria-hidden="true">↓</span>
              </button>
            </div>
          </div>
          <div className="network-stats" aria-live="polite">
            <span className="stat-online">Total Macs: <b>{formatNumber(network.activeMacs)} Units</b></span>
            <span className="stat-tokens">Tokens generated: <b>{formatNumber(network.tokensServedWindow)}</b></span>
            <span className="stat-requests">Total requests: <b>{formatNumber(network.totalRequests)}</b></span>
          </div>
          <div className="grid-world" ref={gridWorld}>
            <div ref={gridMapShell} className="grid-map-shell">
              <GridMap />
            </div>
          </div>
          <div className="story-portal" aria-hidden="true" />

          {/* Predetermined walkthrough data (Figma 286:931). This card
              explains routing; it makes no claim about the live network. */}
          <aside className="route-provider-card" aria-hidden="true">
            <div className="provider-card-topline">
              <div className="provider-status"><i /> <span>Connected</span></div>
              <span className="provider-close-mark">×</span>
            </div>
            <div className="provider-title-block">
              <h3>Mac 213</h3>
              <p>Apple M3 Ultra · Mac15,14</p>
            </div>
            <dl>
              <div>
                <Image src="/icons/tokens.svg" alt="" width={10} height={10} />
                <dt>Token Generated</dt><dd>300</dd>
              </div>
              <div>
                <Image src="/icons/location.svg" alt="" width={8} height={10} />
                <dt>Location</dt><dd>United States</dd>
              </div>
              <div>
                <Image src="/icons/earned.svg" alt="" width={10} height={7} />
                <dt>Provider Earned</dt><dd>$2 USD</dd>
              </div>
            </dl>
          </aside>

          <GridChat ref={chat} />

          {network.available && (
            <p className="sr-only" aria-live="polite">
              {`Live network telemetry${network.degraded ? " using the nearest healthy reporting window" : ""} · updated ${network.generatedAt ? new Date(network.generatedAt).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : "now"}.`}
            </p>
          )}
        </div>
      </section>

      {/* The inside of the Mac you dove into. During entry the section stays
          transparent until the expanding story tile covers the frame. */}
      <section
        className="story-section"
        id="stories"
        aria-labelledby="stories-heading"
        ref={storySection}
      >
        <article className="story-article">
          <h2 className="sr-only" id="stories-heading">Stories from the Darkbloom grid</h2>
          <div
            className="story-gallery"
            ref={storyCarousel}
            onScroll={handleStoryScroll}
            onPointerDown={handleStoryPointerDown}
            onPointerMove={handleStoryPointerMove}
            onPointerUp={(event) => finishStoryDrag(event)}
            onPointerCancel={(event) => finishStoryDrag(event, true)}
            onDragStart={(event) => event.preventDefault()}
            aria-label="Provider stories. Drag left or right to browse."
          >
            <div className="story-gallery-track">
              {LOOPED_STORIES.map((item, index) => (
                <StoryGalleryCard
                  key={`${item.slug}-${index}`}
                  story={item}
                  position={index === activeStoryItemIndex ? "active" : index < activeStoryItemIndex ? "before" : "after"}
                  isClone={index < stories.length || index >= stories.length * 2}
                  playing={index === playingStoryItemIndex}
                  cardRef={(node) => { storyCards.current[index] = node; }}
                  onSelect={() => {
                    if (!suppressStoryClick.current) centerStoryItem(index);
                  }}
                  onPlay={() => setPlayingStoryItemIndex(index)}
                />
              ))}
            </div>
          </div>
          <div className="story-carousel-detail">
            <h2>{activeStory.headline}</h2>
            <div className="story-body">
              <div
                className={`story-body-copy ${activeStoryExpanded ? "is-expanded" : ""}`}
                id={activeStoryCopyId}
              >
                <p>{activeStorySummary}</p>
                {activeStoryExpanded && activeStory.copy.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}
              </div>
              <button
                type="button"
                className="story-readmore"
                onClick={() => setExpandedStories((openStories) =>
                  openStories.includes(activeStory.slug)
                    ? openStories.filter((slug) => slug !== activeStory.slug)
                    : [...openStories, activeStory.slug],
                )}
                aria-expanded={activeStoryExpanded}
                aria-controls={activeStoryCopyId}
              >
                {activeStoryExpanded ? "Read less ↑" : "Read more ↓"}
              </button>
            </div>
          </div>
          <a className="story-scroll" href="#join">Scroll ↓</a>
        </article>
      </section>

      <section
        className="closing"
        id="join"
        aria-labelledby="closing-title"
        ref={closingSection}
      >
        <div className="closing-content">
          <div className="closing-copy">
            <h2 id="closing-title">Your Mac<br />could be part<br />of the grid.</h2>
            <p className="closing-subhead">Join thousands of nodes worldwide. Secure the network, earn rewards, and build the future of decentralized computing.</p>
            <a className="closing-join" href="https://console.darkbloom.dev/" target="_blank" rel="noreferrer">Join the grid ↗</a>
          </div>
          <div className="closing-laptop" aria-hidden="true">
            <video className="closing-laptop-texture" autoPlay loop muted playsInline preload="auto">
              <source src="/media/laptop-texture.mp4" type="video/mp4" />
            </video>
            <Image className="closing-laptop-frame" src="/media/laptop-illustration.svg" alt="" width={813} height={515} priority={false} />
          </div>
        </div>
      </section>
    </PageWithFooter>
  );
}
