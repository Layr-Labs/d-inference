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
  var finePointer = window.matchMedia && window.matchMedia('(pointer: fine)').matches;

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

  /* ---------- Text splitting helpers ---------- */
  function splitChars(node) {
    var spans = [];
    var nodes = Array.prototype.slice.call(node.childNodes);
    nodes.forEach(function (child) {
      if (child.nodeType !== Node.TEXT_NODE) return;
      var frag = document.createDocumentFragment();
      child.textContent.split(/(\s+)/).forEach(function (part) {
        if (!part) return;
        if (/^\s+$/.test(part)) {
          frag.appendChild(document.createTextNode(' '));
          return;
        }
        var word = document.createElement('span');
        word.className = 'split-w';
        part.split('').forEach(function (ch) {
          var s = document.createElement('span');
          s.className = 'split-char';
          s.textContent = ch;
          word.appendChild(s);
          spans.push(s);
        });
        frag.appendChild(word);
      });
      node.replaceChild(frag, child);
    });
    return spans;
  }

  function splitWords(node) {
    var spans = [];
    var nodes = Array.prototype.slice.call(node.childNodes);
    nodes.forEach(function (child) {
      if (child.nodeType !== Node.TEXT_NODE) return;
      var frag = document.createDocumentFragment();
      child.textContent.split(/(\s+)/).forEach(function (part) {
        if (!part) return;
        if (/^\s+$/.test(part)) {
          frag.appendChild(document.createTextNode(part));
          return;
        }
        var mask = document.createElement('span');
        mask.className = 'split-mask';
        var s = document.createElement('span');
        s.className = 'split-word';
        s.textContent = part;
        mask.appendChild(s);
        frag.appendChild(mask);
        spans.push(s);
      });
      node.replaceChild(frag, child);
    });
    return spans;
  }

  /* ---------- Hero entrance: per-letter headline cascade ---------- */
  function heroEntrance() {
    var h1 = document.querySelector('.hero h1');
    var chars = [];
    if (h1) {
      h1.setAttribute('aria-label', h1.textContent.trim());
      chars = splitChars(h1);
      var rotor = h1.querySelector('.word-rotor');
      if (rotor) chars = chars.concat(splitChars(rotor));
      chars.forEach(function (c) {
        c.setAttribute('aria-hidden', 'true');
        c.style.opacity = '0';
      });
    }

    var tl = anime.timeline({ easing: EASE });
    if (chars.length) {
      tl.add({
        targets: chars,
        opacity: [0, 1],
        translateY: ['0.55em', 0],
        rotateZ: [3, 0],
        duration: 850,
        delay: anime.stagger(18, { start: 100 })
      }, 0);
    }
    tl.add({
      targets: '.hero .lead',
      opacity: [0, 1],
      translateY: [18, 0],
      duration: 700
    }, 550)
      .add({
        targets: '.hero .ctas .btn',
        opacity: [0, 1],
        translateY: [16, 0],
        duration: 600,
        delay: anime.stagger(90)
      }, 720)
      .add({
        targets: '.hero-illustration',
        opacity: [0, 1],
        translateY: [24, 0],
        scale: [0.96, 1],
        duration: 900
      }, 700);
  }

  /* ---------- Rotating keyword in the headline ---------- */
  function wordRotor() {
    var rotor = document.querySelector('.word-rotor');
    if (!rotor || !rotor.getAttribute('data-words')) return;
    var words = rotor.getAttribute('data-words').split(',');
    if (words.length < 2) return;
    var idx = 0;
    var running = true;
    var timer = null;

    document.addEventListener('visibilitychange', function () {
      running = !document.hidden;
      if (running) schedule();
    });

    function setWord(word) {
      rotor.textContent = '';
      var spans = word.split('').map(function (ch) {
        var s = document.createElement('span');
        s.className = 'rotor-char';
        s.setAttribute('aria-hidden', 'true');
        s.textContent = ch;
        s.style.opacity = '0';
        rotor.appendChild(s);
        return s;
      });
      return spans;
    }

    function cycle() {
      if (!running) return;
      var current = rotor.querySelectorAll('.rotor-char');
      anime({
        targets: current,
        opacity: [1, 0],
        translateY: [0, '-0.6em'],
        easing: 'easeInQuad',
        duration: 300,
        delay: anime.stagger(22),
        complete: function () {
          idx = (idx + 1) % words.length;
          var next = setWord(words[idx]);
          anime({
            targets: next,
            opacity: [0, 1],
            translateY: ['0.6em', 0],
            easing: EASE,
            duration: 500,
            delay: anime.stagger(28),
            complete: schedule
          });
        }
      });
    }

    function schedule() {
      if (timer) clearTimeout(timer);
      timer = setTimeout(function () {
        timer = null;
        if (running) cycle();
      }, 2600);
    }

    setTimeout(function () {
      var spans = setWord(words[0]);
      spans.forEach(function (s) { s.style.opacity = '1'; });
      schedule();
    }, 2200);
  }

  /* ---------- Hero SVG: draw routes, loop pulses, float nodes ---------- */
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
      delay: anime.stagger(250, { start: 1300 }),
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
      ['#hero-node-app', '#hero-node-core', '#hero-node-stack'].forEach(function (sel, i) {
        if (!document.querySelector(sel)) return;
        loops.push(anime({
          targets: sel,
          translateY: [0, i % 2 ? 4 : -4],
          easing: 'easeInOutSine',
          duration: 2400 + i * 300,
          direction: 'alternate',
          loop: true
        }));
      });
      if (!loops.length) return;
      document.addEventListener('visibilitychange', function () {
        loops.forEach(function (loop) {
          if (document.hidden) { loop.pause(); } else { loop.play(); }
        });
      });
    }
  }

  /* ---------- Pointer-follow tilt on the hero illustration ---------- */
  function heroTilt() {
    if (!finePointer) return;
    var hero = document.querySelector('.hero');
    var ill = document.querySelector('.hero-illustration');
    if (!hero || !ill) return;
    var raf = null;
    var rx = 0, ry = 0;
    var armed = false;
    setTimeout(function () { armed = true; }, 1900);

    hero.addEventListener('mousemove', function (e) {
      if (!armed) return;
      var r = hero.getBoundingClientRect();
      ry = ((e.clientX - r.left) / r.width - 0.5) * 8;
      rx = (0.5 - (e.clientY - r.top) / r.height) * 6;
      if (!raf) raf = requestAnimationFrame(apply);
    });
    hero.addEventListener('mouseleave', function () {
      if (!armed) return;
      anime.remove(ill);
      anime({
        targets: ill,
        rotateX: 0,
        rotateY: 0,
        easing: 'spring(1, 80, 12, 0)'
      });
    });

    function apply() {
      raf = null;
      ill.style.transform = 'rotateX(' + rx + 'deg) rotateY(' + ry + 'deg)';
    }
  }

  /* ---------- Magnetic CTA buttons ---------- */
  function magneticButtons() {
    if (!finePointer) return;
    document.querySelectorAll('.hero .ctas .btn').forEach(function (btn) {
      btn.addEventListener('mousemove', function (e) {
        var r = btn.getBoundingClientRect();
        var x = (e.clientX - r.left - r.width / 2) * 0.25;
        var y = (e.clientY - r.top - r.height / 2) * 0.35;
        anime.remove(btn);
        anime({
          targets: btn,
          translateX: x,
          translateY: y,
          easing: 'easeOutQuad',
          duration: 200
        });
      });
      btn.addEventListener('mouseleave', function () {
        anime.remove(btn);
        anime({
          targets: btn,
          translateX: 0,
          translateY: 0,
          easing: 'spring(1, 70, 11, 0)'
        });
      });
    });
  }

  /* ---------- Scroll progress bar ---------- */
  function scrollProgress() {
    var bar = document.createElement('div');
    bar.className = 'scroll-progress';
    document.body.appendChild(bar);
    var raf = null;

    function update() {
      raf = null;
      var max = document.documentElement.scrollHeight - window.innerHeight;
      var p = max > 0 ? window.scrollY / max : 0;
      bar.style.transform = 'scaleX(' + Math.min(Math.max(p, 0), 1) + ')';
    }
    window.addEventListener('scroll', function () {
      if (!raf) raf = requestAnimationFrame(update);
    }, { passive: true });
    update();
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

  /* ---------- Section headlines: per-word rise on reveal ---------- */
  function headlineReveals() {
    var entries = [];
    document.querySelectorAll('main section h2').forEach(function (h2) {
      var words = splitWords(h2);
      if (!words.length) return;
      words.forEach(function (w) { w.style.transform = 'translateY(110%)'; });
      entries.push({ el: h2, words: words });
    });
    if (!entries.length) return;

    var observer = new IntersectionObserver(function (obs) {
      obs.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        observer.unobserve(entry.target);
        var item = entries.filter(function (e) { return e.el === entry.target; })[0];
        if (!item) return;
        anime({
          targets: item.words,
          translateY: ['110%', '0%'],
          easing: EASE,
          duration: 800,
          delay: anime.stagger(70)
        });
      });
    }, { threshold: 0.4 });

    entries.forEach(function (e) { observer.observe(e.el); });
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
          translateY: [22, 0],
          scale: [0.97, 1],
          easing: EASE,
          duration: 700,
          delay: anime.stagger(90, { from: 'first' })
        });
        el.querySelectorAll('.stat-num').forEach(countUp);
        anime({ targets: el, opacity: [0, 1], easing: 'linear', duration: 200 });
        return;
      }

      var rows = el.querySelectorAll(':scope table tbody tr');
      if (rows.length) {
        rows.forEach(function (r) { r.style.opacity = '0'; });
        anime({ targets: el, opacity: [0, 1], easing: 'linear', duration: 200 });
        anime({
          targets: rows,
          opacity: [0, 1],
          translateX: [-14, 0],
          easing: EASE,
          duration: 550,
          delay: anime.stagger(70)
        });
        return;
      }

      anime({
        targets: el,
        opacity: [0, 1],
        translateY: [20, 0],
        easing: EASE,
        duration: 750
      });
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
    heroEntrance();
    wordRotor();
    heroRoutes();
    heroTilt();
    magneticButtons();
    scrollProgress();
    headlineReveals();
    scrollReveals();
    privacyLayers();
    logoPop();
  });
})();
