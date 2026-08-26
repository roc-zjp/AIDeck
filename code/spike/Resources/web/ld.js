/* 宿主 ↔ 页面的核心契约层：状态→主题映射、帧循环闸门、消息通道。
   HUD 已拆为独立窗口（见 hud.js / hud.html），本文件不再渲染任何 HUD。 */
(function () {
  const PHASES = {
    idle:     { label: '空闲',     bg: [0x0a,0x0e,0x1a], a: [0x1e,0x3a,0x5f], b: [0x14,0x4d,0x54], energy: 0.18, speed: 0.16, pulse: 0.10 },
    waiting:  { label: '等你输入', bg: [0x16,0x10,0x07], a: [0xff,0xb3,0x47], b: [0xff,0x6b,0x35], energy: 0.92, speed: 0.35, pulse: 1.00 },
    thinking: { label: '思考中',   bg: [0x0d,0x0a,0x18], a: [0xa7,0x8b,0xfa], b: [0xf4,0x72,0xb6], energy: 0.72, speed: 0.85, pulse: 0.35 },
    running:  { label: '执行工具', bg: [0x04,0x12,0x0f], a: [0x34,0xd3,0x99], b: [0x22,0xd3,0xee], energy: 0.88, speed: 1.25, pulse: 0.55 },
  };

  const lerp = (x, y, t) => x + (y - x) * t;
  const lerp3 = (x, y, t) => [lerp(x[0],y[0],t), lerp(x[1],y[1],t), lerp(x[2],y[2],t)];
  const css = (c, alpha) => `rgba(${c[0]|0},${c[1]|0},${c[2]|0},${alpha === undefined ? 1 : alpha})`;

  // 目标主题与当前主题分离，每帧向目标逼近 —— 状态切换是"渐变过去"而非硬切
  let target = PHASES.idle, cur = JSON.parse(JSON.stringify(PHASES.idle));
  let state = { phase: 'idle', sessions: [], activeSessions: 0 };
  let running = true, rafId = null, renderFn = null;
  let frames = 0, totalFrames = 0, ticks = 0, fpsClock = performance.now(), t = 0;

  function step() {
    rafId = requestAnimationFrame(step);
    const k = 0.045;
    cur.bg = lerp3(cur.bg, target.bg, k);
    cur.a  = lerp3(cur.a,  target.a,  k);
    cur.b  = lerp3(cur.b,  target.b,  k);
    cur.energy = lerp(cur.energy, target.energy, k);
    cur.speed  = lerp(cur.speed,  target.speed,  k);
    cur.pulse  = lerp(cur.pulse,  target.pulse,  k);
    t += 0.016 * cur.speed;
    if (renderFn) renderFn(t, cur, state);
    frames++; totalFrames++;
  }

  function report(msg) {
    try { window.webkit.messageHandlers.ld.postMessage(msg); } catch (e) {}
  }

  // 用 setInterval 而非 rAF 内计时上报：rAF 被系统节流时仍能如实报出 0
  setInterval(() => {
    ticks++;
    const now = performance.now();
    report({ fps: frames * 1000 / (now - fpsClock) });
    frames = 0; fpsClock = now;
  }, 1000);

  window.__ldDiag = () => ({
    handler: typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ld),
    frames: totalFrames, ticks, running, rafAlive: rafId !== null,
    vis: document.visibilityState, hidden: document.hidden,
    screen: { w: innerWidth, h: innerHeight },
    hudSize: window.__ldHudSize ? window.__ldHudSize() : null
  });

  window.__ld = {
    phases: PHASES,
    setState(s) {
      state = s || state;
      target = PHASES[state.phase] || PHASES.idle;
      // HUD 页面通过这个钩子接收状态；动画页面不注册它
      if (window.__ldOnState) window.__ldOnState(state, PHASES[state.phase] || PHASES.idle);
    },
    setRunning(on) {
      if (on === running) return;
      running = on;
      if (on) { fpsClock = performance.now(); frames = 0; rafId = requestAnimationFrame(step); }
      else { if (rafId) cancelAnimationFrame(rafId); rafId = null; report({ fps: 0 }); }
    },
    loop(fn) {
      renderFn = fn;
      if (running && rafId === null) rafId = requestAnimationFrame(step);
    },
    css, lerp, report,
  };

  const style = document.createElement('style');
  style.textContent = `
    html,body{margin:0;height:100%;overflow:hidden;background:transparent;
      font-family:-apple-system,'SF Pro Text','PingFang SC',sans-serif;
      -webkit-font-smoothing:antialiased;cursor:none;}
    canvas{display:block;width:100vw;height:100vh;}
  `;
  document.head.appendChild(style);
  window.addEventListener('DOMContentLoaded', () => report({ kind: 'ready' }));
})();
