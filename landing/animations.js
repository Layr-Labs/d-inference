/* Darkbloom landing animations — powered by anime.js (v3).
   Progressive enhancement: if anime.js fails to load or the user prefers
   reduced motion, the page falls back to the original CSS reveals. */
(function () {
  'use strict';

  var reducedMotion = window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  if (typeof window.anime !== 'function' || reducedMotion) return;

  document.documentElement.classList.add('anime-on');

  var EASE = 'cubicBezier(0.22, 1, 0.36, 1)';

  var PULSES = [
    { dot: '#hero-pulse-1', route: '#hero-route-1' },
    { dot: '#hero-pulse-2', route: '#hero-route-2' }
  ];

  function onReady(fn) {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', fn);
    } else {
      fn();
    }
  }

  /* ---------- Hero entrance timeline ---------- */
  function heroTimeline() {
    var tl = anime.timeline({ easing: EASE, duration: 700 });
    tl.add({ targets: '.hero h1', opacity: [0, 1], translateY: [24, 0] }, 150)
      .add({ targets: '.hero .lead', opacity: [0, 1], translateY: [18, 0] }, 320)
      .add({
        targets: '.hero .ctas .btn',
        opacity: [0, 1],
        translateY: [14, 0],
        delay: anime.stagger(90)
      }, 460)
      .add({
        targets: '.hero-illustration',
        opacity: [0, 1],
        translateY: [20, 0],
        scale: [0.97, 1],
        duration: 900
      }, 520);
  }

  /* ---------- Hero SVG: draw routes, then loop pulse dots ---------- */
  function heroRoutes() {
    var routes = ['#hero-route-1', '#hero-route-2'].filter(function (sel) {
      return document.querySelector(sel);
    });
    if (!routes.length) return;

    routes.forEach(function (sel) {
      var el = document.querySelector(sel);
      var len = el.getTotalLength();
      el.setAttribute('stroke-dasharray', len);
      el.setAttribute('stroke-dashoffset', len);
    });

    anime({
      targets: routes.join(','),
      strokeDashoffset: [anime.setDashoffset, 0],
      easing: 'easeInOutSine',
      duration: 800,
      delay: anime.stagger(250, { start: 1100 }),
      complete: startPulses
    });

    function startPulse(pulse, i) {
      if (!document.querySelector(pulse.dot) || !document.querySelector(pulse.route)) return null;
      var path = anime.path(pulse.route);
      return anime({
        targets: pulse.dot,
        translateX: path('x'),
        translateY: path('y'),
        opacity: [
          { value: 0.9, duration: 150 },
          { value: 0.9, duration: 1100 },
          { value: 0, duration: 250 }
        ],
        easing: 'easeInOutSine',
        duration: 1500,
        loop: true,
        delay: i * 750,
        endDelay: 600
      });
    }

    function startPulses() {
      var loops = PULSES.map(startPulse).filter(Boolean);
      if (!loops.length) return;
      document.addEventListener('visibilitychange', function () {
        loops.forEach(function (loop) {
          if (document.hidden) { loop.pause(); } else { loop.play(); }
        });
      });
    }
  }

  /* ---------- Stat number count-ups (e.g. "100M+", "50%", "18hrs") ---------- */
  function countUp(el) {
    var raw = el.textContent.trim();
    var match = raw.match(/^([\d.]+)(.*)$/);
    if (!match) return;
    var target = parseFloat(match[1]);
    var suffix = match[2] || '';
    var state = { n: 0 };
    anime({
      targets: state,
      n: target,
      round: 1,
      easing: 'easeOutExpo',
      duration: 1400,
      update: function () {
        el.textContent = state.n + suffix;
      },
      complete: function () {
        el.textContent = raw;
      }
    });
  }

  /* ---------- Scroll-triggered reveals ---------- */
  function scrollReveals() {
    var revealed = new WeakSet();

    function revealGroup(el) {
      var children = el.querySelectorAll(
        ':scope > .card, :scope > .stat-cell, :scope > .feat-item'
      );
      if (children.length) {
        anime({
          targets: children,
          opacity: [0, 1],
          translateY: [18, 0],
          easing: EASE,
          duration: 650,
          delay: anime.stagger(90)
        });
        el.querySelectorAll('.stat-num').forEach(countUp);
        anime({ targets: el, opacity: [0, 1], easing: 'linear', duration: 200 });
      } else {
        anime({
          targets: el,
          opacity: [0, 1],
          translateY: [20, 0],
          easing: EASE,
          duration: 750
        });
      }
    }

    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting || revealed.has(entry.target)) return;
        revealed.add(entry.target);
        observer.unobserve(entry.target);
        revealGroup(entry.target);
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -30px 0px' });

    document.querySelectorAll('.rv').forEach(function (el) {
      el.style.opacity = '0';
      observer.observe(el);
    });
  }

  /* ---------- Privacy architecture diagram: layers cascade inward ---------- */
  function privacyLayers() {
    var svg = document.querySelector('#security svg');
    if (!svg) return;
    var layers = svg.querySelectorAll('rect');
    if (!layers.length) return;
    layers.forEach(function (r) { r.style.opacity = '0'; });

    var fired = false;
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting || fired) return;
        fired = true;
        observer.disconnect();
        anime({
          targets: layers,
          opacity: [0, 1],
          scale: [0.985, 1],
          transformOrigin: ['50% 50%', '50% 50%'],
          easing: EASE,
          duration: 600,
          delay: anime.stagger(160)
        });
      });
    }, { threshold: 0.3 });
    observer.observe(svg);
  }

  /* ---------- Header logo: gentle pop on load ---------- */
  function logoPop() {
    anime({
      targets: '.logo-symbol',
      scale: [0.6, 1],
      rotate: ['-8deg', '0deg'],
      opacity: [0, 1],
      easing: 'spring(1, 80, 12, 0)',
      duration: 900
    });
  }

  onReady(function () {
    heroTimeline();
    heroRoutes();
    scrollReveals();
    privacyLayers();
    logoPop();
  });
})();
