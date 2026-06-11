/* Darkbloom hero shader background — "silk ribbons" generative effect.
   Self-contained WebGL fragment shader, no dependencies. Progressive
   enhancement: if WebGL is unavailable the hero keeps its CSS gradient.
   Honors prefers-reduced-motion by rendering a single static frame. */
(function () {
  'use strict';

  var canvas = document.querySelector('.hero-shader');
  if (!canvas) return;

  var gl = canvas.getContext('webgl', {
    alpha: true,
    antialias: false,
    powerPreference: 'low-power'
  });
  if (!gl) return;

  var reducedMotion = window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  var VERT = [
    'attribute vec2 p;',
    'void main() { gl_Position = vec4(p, 0.0, 1.0); }'
  ].join('\n');

  /* Layered sine-warped ribbons drifting horizontally, lit with a soft
     specular highlight. Palette: deep indigo -> Darkbloom blue -> ice. */
  var FRAG = [
    'precision mediump float;',
    'uniform vec2 u_res;',
    'uniform float u_time;',
    'uniform vec2 u_mouse;',
    '',
    'float hash(float n) { return fract(sin(n) * 43758.5453123); }',
    '',
    'float noise(vec2 x) {',
    '  vec2 i = floor(x);',
    '  vec2 f = fract(x);',
    '  f = f * f * (3.0 - 2.0 * f);',
    '  float n = i.x + i.y * 57.0;',
    '  return mix(mix(hash(n), hash(n + 1.0), f.x),',
    '             mix(hash(n + 57.0), hash(n + 58.0), f.x), f.y);',
    '}',
    '',
    'float fbm(vec2 p) {',
    '  float v = 0.0;',
    '  float a = 0.5;',
    '  for (int i = 0; i < 4; i++) {',
    '    v += a * noise(p);',
    '    p = p * 2.03 + vec2(11.3, 7.7);',
    '    a *= 0.5;',
    '  }',
    '  return v;',
    '}',
    '',
    'void main() {',
    '  vec2 uv = gl_FragCoord.xy / u_res;',
    '  vec2 q = uv;',
    '  q.x *= u_res.x / u_res.y;',
    '  float t = u_time * 0.08;',
    '',
    '  float warp = fbm(q * 1.6 + vec2(t, -t * 0.6));',
    '  float drift = fbm(q * 0.8 - vec2(t * 0.5, 0.0));',
    '  float my = (u_mouse.y - 0.5) * 0.25;',
    '  float mx = (u_mouse.x - 0.5) * 0.18;',
    '',
    '  float y = uv.y + warp * 0.32 + drift * 0.22 + my * (1.0 - uv.y) + mx * uv.x * 0.4;',
    '  float bands = sin(y * 34.0 + warp * 6.0 + t * 4.0);',
    '  float ribbon = smoothstep(0.18, 0.98, bands);',
    '  float sheen = pow(max(bands, 0.0), 6.0);',
    '',
    '  vec3 deep = vec3(0.035, 0.022, 0.10);',
    '  vec3 indigo = vec3(0.10, 0.05, 0.43);',
    '  vec3 blue = vec3(0.34, 0.50, 0.95);',
    '  vec3 ice = vec3(0.72, 0.84, 1.0);',
    '',
    '  vec3 col = deep;',
    '  col = mix(col, indigo, ribbon * 0.6);',
    '  col = mix(col, blue, sheen * (0.2 + 0.25 * warp));',
    '  col += ice * pow(sheen, 4.0) * 0.25;',
    '',
    '  float vign = smoothstep(1.35, 0.35, length(uv - vec2(0.42, 0.55)));',
    '  col *= 0.45 + 0.4 * vign;',
    '',
    '  float fadeTop = smoothstep(1.0, 0.82, uv.y);',
    '  float fadeBottom = smoothstep(0.0, 0.14, uv.y);',
    '  gl_FragColor = vec4(col, 0.9 * fadeTop * fadeBottom + 0.1);',
    '}'
  ].join('\n');

  function compile(type, src) {
    var s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) return null;
    return s;
  }

  var vs = compile(gl.VERTEX_SHADER, VERT);
  var fs = compile(gl.FRAGMENT_SHADER, FRAG);
  if (!vs || !fs) return;

  var prog = gl.createProgram();
  gl.attachShader(prog, vs);
  gl.attachShader(prog, fs);
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return;
  gl.useProgram(prog);

  var buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER,
    new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  var loc = gl.getAttribLocation(prog, 'p');
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

  var uRes = gl.getUniformLocation(prog, 'u_res');
  var uTime = gl.getUniformLocation(prog, 'u_time');
  var uMouse = gl.getUniformLocation(prog, 'u_mouse');

  var mouse = { x: 0.5, y: 0.5 };
  var target = { x: 0.5, y: 0.5 };
  var dpr = Math.min(window.devicePixelRatio || 1, 1.5);
  var visible = true;
  var raf = null;
  var start = performance.now();

  function resize() {
    var w = canvas.clientWidth;
    var h = canvas.clientHeight;
    if (!w || !h) return;
    var pw = Math.round(w * dpr);
    var ph = Math.round(h * dpr);
    if (canvas.width !== pw || canvas.height !== ph) {
      canvas.width = pw;
      canvas.height = ph;
      gl.viewport(0, 0, pw, ph);
    }
  }

  function draw(now) {
    resize();
    mouse.x += (target.x - mouse.x) * 0.04;
    mouse.y += (target.y - mouse.y) * 0.04;
    gl.uniform2f(uRes, canvas.width, canvas.height);
    gl.uniform1f(uTime, (now - start) / 1000);
    gl.uniform2f(uMouse, mouse.x, mouse.y);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  function loop(now) {
    raf = null;
    draw(now);
    if (visible && !document.hidden) raf = requestAnimationFrame(loop);
  }

  function play() {
    if (!raf && visible && !document.hidden) raf = requestAnimationFrame(loop);
  }

  if (reducedMotion) {
    requestAnimationFrame(function (now) { draw(now); });
    window.addEventListener('resize', function () {
      requestAnimationFrame(function (now) { draw(now); });
    });
    return;
  }

  var hero = canvas.closest('.hero') || canvas.parentElement;
  hero.addEventListener('mousemove', function (e) {
    var r = hero.getBoundingClientRect();
    target.x = (e.clientX - r.left) / r.width;
    target.y = 1 - (e.clientY - r.top) / r.height;
  });

  var io = new IntersectionObserver(function (entries) {
    visible = entries[0].isIntersecting;
    if (visible) { play(); }
  }, { threshold: 0 });
  io.observe(canvas);

  document.addEventListener('visibilitychange', play);
  play();
})();
