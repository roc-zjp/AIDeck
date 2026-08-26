/* 独立 HUD 窗口的渲染层。挂在桌面图标层之上，永不被图标遮挡。
   窗口尺寸由本文件量出后回报宿主，宿主据此调整窗口大小与位置。 */
(function () {
  const style = document.createElement('style');
  style.textContent = `
    html,body{background:transparent !important;background-color:transparent !important;
      cursor:default;margin:0;padding:0;}
    #hud{display:inline-block;padding:16px 20px 15px;
      border-radius:16px;background:rgba(12,14,20,.52);
      backdrop-filter:blur(26px) saturate(1.5);
      border:1px solid rgba(255,255,255,.14);
      box-shadow:0 10px 44px rgba(0,0,0,.5);min-width:190px;
      transition:box-shadow .2s ease, border-color .2s ease;}
    #hud.editing{border-color:rgba(255,255,255,.30);
      box-shadow:0 18px 58px rgba(0,0,0,.62);
      background:rgba(12,14,20,.62);cursor:grabbing;}
    #hud .row{display:flex;align-items:center;gap:9px;}
    #hud .dot{width:8px;height:8px;border-radius:50%;flex:none;}
    #hud .dot.breathe{animation:ldb 1.6s ease-in-out infinite;}
    @keyframes ldb{0%,100%{transform:scale(1);opacity:1}50%{transform:scale(1.55);opacity:.55}}
    #hud .phase{font-size:14px;font-weight:590;letter-spacing:.02em;white-space:nowrap;}
    #hud .meta{margin-top:7px;font-size:11px;color:rgba(255,255,255,.78);
      letter-spacing:.03em;font-variant-numeric:tabular-nums;
      max-width:300px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}
    #hud .count{margin-top:3px;font-size:10px;color:rgba(255,255,255,.5);letter-spacing:.05em;white-space:nowrap;}
  `;
  document.head.appendChild(style);

  let el;

  function measure() {
    if (!el) return null;
    const r = el.getBoundingClientRect();
    // 阴影会溢出边界，留出余量避免被窗口裁掉
    return { w: Math.ceil(r.width) + 16, h: Math.ceil(r.height) + 16 };
  }
  window.__ldHudSize = measure;

  let lastW = 0, lastH = 0;
  function reportSize() {
    const s = measure();
    if (!s) return;
    if (s.w === lastW && s.h === lastH) return;   // 只在真的变了才报，否则宿主每秒重排一次
    lastW = s.w; lastH = s.h;
    window.__ld.report({ kind: 'hudSize', w: s.w, h: s.h });
  }

  function render(state, phase) {
    if (!el) return;
    const css = window.__ld.css;
    const dot = el.querySelector('.dot');
    dot.style.background = css(phase.a);
    dot.style.boxShadow = `0 0 12px ${css(phase.a, .9)}, 0 0 28px ${css(phase.a, .45)}`;
    dot.classList.toggle('breathe', state.phase === 'waiting');
    const ph = el.querySelector('.phase');
    ph.textContent = phase.label;
    ph.style.color = css(phase.a);
    const meta = [];
    if (state.tool) meta.push(state.tool);
    if (state.project) meta.push(state.project);
    if (state.branch) meta.push(state.branch);
    el.querySelector('.meta').textContent = meta.join(' · ') || '—';
    const n = state.activeSessions || 0;
    el.querySelector('.count').textContent = n ? `${n} 个会话在跑` : '无活跃会话';
    reportSize();
  }

  window.__ldOnState = render;
  window.__ldSetEditing = (on) => {
    if (el) el.classList.toggle('editing', on);
  };

  window.addEventListener('DOMContentLoaded', () => {
    el = document.createElement('div');
    el.id = 'hud';
    el.innerHTML = `<div class="row"><span class="dot"></span><span class="phase">空闲</span></div>
                    <div class="meta">—</div><div class="count">无活跃会话</div>`;
    document.body.appendChild(el);
    if (window.ResizeObserver) new ResizeObserver(reportSize).observe(el);
    render({ phase: 'idle', activeSessions: 0 }, window.__ld.phases.idle);
  });
})();
