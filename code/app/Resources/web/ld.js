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
  // 小工具槽位与事件反应的偏好：宿主经 setConfig 推送；没有宿主（浏览器里调试）就用默认
  const DEFAULT_CONFIG = {
    // 只在没有宿主时生效（浏览器里直接开页面调试）；有宿主时被 setConfig 推来的真实偏好整体覆盖。
    // **必须与 Prefs.swift 的 defaultWidgets 保持同一组键**——少一个键，无宿主调试时该小工具的槽位就是 undefined。
    // task 已删（与 SESSIONS/状态卡完全重复）；clock / system 默认关（菜单栏有时钟；机器总量不是核心感知，想看的自己开）
    widgets:   { sessions: 'tl', context: 'tr', activity: 'bl', repos: 'br', power: 'bc', clock: 'off', system: 'off' },
    reactions: { toolPulse: true, phaseRipple: true, rechargeBurst: true, lowPowerFlicker: true, satellites: true },
    model: 'station',   // hologram 皮肤的 3D 模型：内置名或 user/<文件名>（ld-3d.js 负责加载）
    skin: {},           // 皮肤自声明设置项的值（见 declarePrefs）
  };
  let config = JSON.parse(JSON.stringify(DEFAULT_CONFIG));
  // 皮肤自声明的设置项：schema 由皮肤在加载时 declarePrefs 给出，值由宿主经 setConfig({skin:{...}}) 推回（只存用户改过的）
  let skinSchema = [], skinSaved = {};
  function skinValues() {
    const out = {};
    for (const p of skinSchema) {
      let v = (p.id in skinSaved) ? skinSaved[p.id] : p.default;
      if (p.type === 'bool') v = !!v;
      else if (p.type === 'number') { v = Number(v); if (!isFinite(v)) v = p.default; if (p.min != null) v = Math.max(p.min, v); if (p.max != null) v = Math.min(p.max, v); }
      else if (p.type === 'choice') { if (!(p.options || []).some(o => o.id === v)) v = p.default; }
      // model 的可选项由宿主掌握（模型目录随时可变），页面侧只收口成非空字符串
      else if (p.type === 'model') { if (typeof v !== 'string' || !v) v = p.default; }
      out[p.id] = v;
    }
    return out;
  }
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
    vis: document.visibilityState, hidden: document.hidden, config,
    screen: { w: innerWidth, h: innerHeight },
    hudSize: window.__ldHudSize ? window.__ldHudSize() : null,
    skin: window.__ldSkinDiag ? window.__ldSkinDiag() : null,  // 皮肤自报（如 hologram 的当前模型 / 加载错误）
    mouse, pendingClicks: clicks.length
  });

  window.__ld = {
    phases: PHASES,
    setState(s) {
      state = s || state;
      target = PHASES[state.phase] || PHASES.idle;
      // HUD 页面通过这个钩子接收状态；动画页面不注册它
      if (window.__ldOnState) window.__ldOnState(state, PHASES[state.phase] || PHASES.idle);
    },
    get config() { return config; },
    // 第四个契约口子：宿主推送偏好（哪个小工具在哪个槽、哪些事件反应开）。缺省项一律回落默认
    setConfig(c) {
      config = {
        widgets:   Object.assign({}, DEFAULT_CONFIG.widgets,   (c && c.widgets)   || {}),
        reactions: Object.assign({}, DEFAULT_CONFIG.reactions, (c && c.reactions) || {}),
        model: (c && typeof c.model === 'string' && c.model) ? c.model : DEFAULT_CONFIG.model,
      };
      skinSaved = (c && c.skin && typeof c.skin === 'object') ? c.skin : {};
      config.skin = skinValues();
      if (window.__ldOnConfig) window.__ldOnConfig(config);
    },
    /* 皮肤自声明设置项（皮肤加载时调一次）。schema 元素：
         { id, name, type: 'bool',   default }
         { id, name, type: 'number', default, min, max, step }
         { id, name, type: 'choice', default, options: [{ id, name }] }
         { id, name, type: 'model',  default }   ← 选一个 3D 模型；选项由宿主填（内置模型 + 用户模型目录）
       宿主据此在设置页渲染控件、按皮肤名存值、经 setConfig 推回；皮肤每帧读 __ld.config.skin.<id> 即可。皮肤作者不需要改宿主。
       'model' 是唯一一个选项由宿主提供的类型：模型文件归宿主管（ld-model:// + 模型目录），
       但"这款皮肤要不要模型、叫什么名字"由皮肤自己说——宿主不认识任何皮肤名。 */
    declarePrefs(schema) {
      const T = { bool: 1, number: 1, choice: 1, model: 1 };
      skinSchema = (Array.isArray(schema) ? schema : []).filter(p => p && typeof p.id === 'string' && T[p.type]).map(p => ({
        id: p.id, name: String(p.name || p.id), type: p.type, default: p.default,
        min: p.min, max: p.max, step: p.step, options: Array.isArray(p.options) ? p.options.map(o => ({ id: String(o.id), name: String(o.name || o.id) })) : undefined,
      }));
      config.skin = skinValues();
      report({ kind: 'prefs', schema: JSON.parse(JSON.stringify(skinSchema)) });
      if (window.__ldOnConfig) window.__ldOnConfig(config);
      return config.skin;
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
    /* 事件探测（皮肤共用）：每帧调一次，只报真实事件，且尊重用户的事件反应开关。
       tool      新的真实工具调用（按事件绝对时刻判定：宿主推送时刻 − ago，允许 ±1s 取整抖动；
                 不用页面时钟——两次推送之间 ago 不变、页面时间在走，会算出假事件）
       phase     全局状态切换
       recharge  五小时窗口重置（充能完成）
       lowPower  五小时剩余 < 20%（持续为真，皮肤自己决定怎么闪）
       pw 传 __ldWidgets.computePower(st.quota) 的结果，可为 null */
    events(st, pw) {
      const on = config.reactions || {}, e = evState;
      const out = { tool: false, phase: false, recharge: false, lowPower: false };
      const newest = (st.recentTools || [])[0];
      if (newest) {
        const base = st.host && st.host.pushedAt ? st.host.pushedAt : Date.now() / 1000;
        const ts = Math.round(base - newest.ago);
        if (e.lastToolTs === null) e.lastToolTs = ts;
        else if (ts > e.lastToolTs + 1) { e.lastToolTs = ts; out.tool = !!on.toolPulse; }
      }
      if (e.lastPhase === null) e.lastPhase = st.phase;
      else if (st.phase !== e.lastPhase) { e.lastPhase = st.phase; out.phase = !!on.phaseRipple; }
      if (pw) {
        const reset = (pw.recharged && e.lastRemain !== null && e.lastRemain < 100) ||
                      (e.lastResetsAt !== null && pw.resetsAt !== e.lastResetsAt && pw.remain > e.lastRemain + 20);
        out.recharge = reset && !!on.rechargeBurst;
        e.lastRemain = pw.remain; e.lastResetsAt = pw.resetsAt;
        out.lowPower = !!on.lowPowerFlicker && pw.remain < 20;
      }
      return out;
    },
    /* 被动输入感知（宿主不拦截任何事件）：
       __ld.mouse        {x, y, t}，光标在本屏时的页面坐标；不在本屏 / 未知为 null
       __ld.takeClicks() 取走并清空自上次以来旁听到的左键点击 [{x, y, t}]
       宿主经 setMouse(x, y, down) 喂；没有宿主（浏览器里调试）时回落到 DOM 的 mousemove / mousedown */
    get mouse() { return mouse; },
    takeClicks() { const c = clicks; clicks = []; return c; },
    setMouse(x, y, down) {
      if (x == null) { mouse = null; return; }
      const t = performance.now();
      mouse = { x, y, t };
      if (down) { clicks.push({ x, y, t }); if (clicks.length > 32) clicks.shift(); }
    },
    // 低电量闪烁的确定性随机：同一帧内多次调用结果一致；remain<5 时更频繁
    flicker(t, remain) {
      const rate = remain < 5 ? 0.35 : 0.12;
      const h = Math.abs(Math.sin(Math.floor(t * 9) * 12.9898) * 43758.5453) % 1;
      return h < rate;
    },
    css, lerp, report,
  };
  const evState = { lastToolTs: null, lastPhase: null, lastRemain: null, lastResetsAt: null };
  let mouse = null, clicks = [];
  const hasHost = !!(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ld);
  if (!hasHost) {   // 浏览器调试：用 DOM 事件模拟宿主的喂法，皮肤代码不用分支
    addEventListener('mousemove', e => window.__ld.setMouse(e.clientX, e.clientY, false));
    addEventListener('mousedown', e => { if (e.button === 0) window.__ld.setMouse(e.clientX, e.clientY, true); });
    addEventListener('mouseleave', () => window.__ld.setMouse(null));
  }

  const style = document.createElement('style');
  style.textContent = `
    html,body{margin:0;height:100%;overflow:hidden;background:transparent;
      font-family:-apple-system,'SF Pro Text','PingFang SC',sans-serif;
      -webkit-font-smoothing:antialiased;}
    canvas{display:block;width:100vw;height:100vh;}
  `;
  document.head.appendChild(style);
  window.addEventListener('DOMContentLoaded', () => report({ kind: 'ready' }));
})();
