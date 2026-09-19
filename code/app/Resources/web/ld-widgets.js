/* 皮肤共用的小工具层：SESSIONS / CONTEXT / ACTIVITY LOG / REPOS / POWER / SYSTEM TIME / SYSTEM（资源 + Claude 占比）。
   画在自己的透明叠加 canvas 上，任何皮肤每帧只需调一次 __ldWidgets.draw(st, theme, opts)。
   槽位由 __ld.config.widgets 决定（tl tr tc bl br bc，off 关闭），宿主经 setConfig 推送；
   中央永远留给皮肤的英雄件。
   所有数字都来自真实状态；没有数据的小工具只显示 NO ... 占位或整块不画，不编数。 */
(function () {
  const MONO = "'SF Mono','Menlo','Consolas',monospace";
  let cv = null, ctx = null, W = 0, H = 0, S = 1;

  function ensureCanvas() {
    if (cv) return;
    cv = document.createElement('canvas'); cv.id = 'ld-widgets';
    cv.style.cssText = 'position:fixed;left:0;top:0;width:100vw;height:100vh;pointer-events:none;background:transparent;';
    document.body.appendChild(cv);
    ctx = cv.getContext('2d');
    resize(); addEventListener('resize', resize);
  }
  function resize() { W = cv.width = innerWidth; H = cv.height = innerHeight; S = Math.min(W, H) / 900; }

  const rgba = (c, a) => `rgba(${c[0]|0},${c[1]|0},${c[2]|0},${a})`;
  // 文字色至少要亮：暗色皮肤把 hi 提到可读
  function lift(c) {
    const m = Math.max(c[0], c[1], c[2]);
    if (m >= 0xa0) return c;
    const k = m > 0 ? 0xd8 / m : 1;
    return c.map(v => Math.min(255, v * k + 40));
  }
  const pad = n => String(n).padStart(2, '0');
  const agoStr = s => `-${pad(Math.floor(s / 60))}:${pad(s % 60)}`;
  const hms = s => { s = Math.max(0, Math.floor(s)); return `${pad(Math.floor(s / 3600))}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`; };
  const dhm = s => { s = Math.max(0, Math.floor(s)); const d = Math.floor(s / 86400), h = Math.floor(s / 3600) % 24, m = Math.floor(s / 60) % 60; return d ? `${d}d ${pad(h)}h` : `${pad(h)}h ${pad(m)}m`; };
  const clock = e => { const d = new Date(e * 1000); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
  // 等待 / 沉默时长：不到一小时 MM:SS，超过则 Hh MMm（等你输入不设上限，可能是好几个小时）
  const dur = s => { s = Math.max(0, Math.floor(s)); return s < 3600 ? `${pad(Math.floor(s / 60))}:${pad(s % 60)}` : `${Math.floor(s / 3600)}h ${pad(Math.floor(s / 60) % 60)}m`; };
  // 会话名可能含中文（/rename 起的），等宽排版按显示宽度算：CJK 占两列
  const cols = ch => (ch.codePointAt(0) > 0x2e7f ? 2 : 1);
  function fitCols(s, w) {
    let out = '', n = 0;
    for (const ch of s) { const c = cols(ch); if (n + c > w) break; out += ch; n += c; }
    return out + ' '.repeat(w - n);
  }
  const PHASE_LABEL = { idle: 'STANDBY', thinking: 'PROCESSING', running: 'EXECUTING', waiting: 'AWAITING' };
  const bar = (pct, n) => { const f = Math.round(pct / 100 * n); return '▓'.repeat(Math.min(n, f)) + '░'.repeat(Math.max(0, n - f)); };

  let theme = { key: [0x2e, 0x7d, 0x99], hi: [0x5a, 0xc8, 0xe8] };

  function text(str, x, y, size, alpha, align, weight) {
    ctx.font = `${weight || 400} ${size * S}px ${MONO}`;
    ctx.textAlign = align; ctx.textBaseline = 'alphabetic';
    ctx.fillStyle = rgba(theme.hi, alpha);
    // 叠画两遍：深色光晕加倍，亮底皮肤（极光警报态整屏亮橙）上像字幕描边一样把字托出来
    ctx.fillText(str, x, y);
    ctx.fillText(str, x, y);
  }

  // 面板：短横线 + 标题 + 行；align 决定锚点在左 / 右 / 中
  function panel(x, y, align, title, rows) {
    const w = 46 * S;
    ctx.strokeStyle = rgba(theme.key, 0.45); ctx.lineWidth = 1; ctx.beginPath();
    if (align === 'left')       { ctx.moveTo(x, y - 13 * S);     ctx.lineTo(x + w, y - 13 * S); }
    else if (align === 'right') { ctx.moveTo(x - w, y - 13 * S); ctx.lineTo(x, y - 13 * S); }
    else                        { ctx.moveTo(x - w / 2, y - 13 * S); ctx.lineTo(x + w / 2, y - 13 * S); }
    ctx.stroke();
    text(title, x, y, 10, 0.55, align, 600);
    rows.forEach((r, i) => text(r, x, y + (17 + i * 15) * S, 11, i === 0 ? 0.92 : 0.62, align));
  }

  // 槽位锚点：3×3 九点位（左中右 × 上中下），对所有皮肤一视同仁、不给英雄件开特例（用户拍板）。
  // 顶排顶对齐、底排底边对齐（标题位置由行数倒推，下缘齐平）、中排垂直居中
  function anchor(slot) {
    const m = 52 * S, top = 62 * S;
    switch (slot) {
      case 'tl': return { x: m,     y: top, align: 'left' };
      case 'tc': return { x: W / 2, y: top, align: 'center' };
      case 'tr': return { x: W - m, y: top, align: 'right' };
      case 'ml': return { x: m,     align: 'left',   middleAligned: true };
      case 'mc': return { x: W / 2, align: 'center', middleAligned: true };
      case 'mr': return { x: W - m, align: 'right',  middleAligned: true };
      case 'bl': return { x: m,     align: 'left',   bottomAligned: true };
      case 'bc': return { x: W / 2, align: 'center', bottomAligned: true };
      case 'br': return { x: W - m, align: 'right',  bottomAligned: true };
      default:   return null;
    }
  }

  /* 额度换算：五小时剩余 = 100 − 已用；窗口已过即满电（从 resets_at 推出的事实）。
     皮肤的英雄件也用它来画能量环，保证两处读数一致。 */
  function computePower(q) {
    if (!q || !q.fiveHour || typeof q.fiveHour.usedPercentage !== 'number') return null;
    const now = Date.now() / 1000, resetsAt = q.fiveHour.resetsAt || 0;
    const recharged = resetsAt > 0 && now >= resetsAt;
    const remain = recharged ? 100 : Math.max(0, Math.min(100, 100 - q.fiveHour.usedPercentage));
    const sd = q.sevenDay;
    return {
      now, resetsAt, recharged, remain,
      reserve: sd && typeof sd.usedPercentage === 'number' ? Math.max(0, Math.min(100, 100 - sd.usedPercentage)) : null,
      reserveResetsAt: sd && sd.resetsAt ? sd.resetsAt : 0,
      recordedAt: q.recordedAt || 0,
      stale: !!q.recordedAt && now - q.recordedAt > 600,   // 十分钟没刷新就得说明数字真到几点
    };
  }

  // ── 各小工具只产出 {title, rows[, ring]}，布局统一交给 panel ──
  const WIDGETS = {
    sessions(st) {
      const rows = (st.sessions || []).map(s => {
        // 时长列：等你输入 = 距 Claude 说完多久；工作中但 ≥2 分钟没写文件 = 沉默多久（括号标出，如实反映"在跑但没输出"）
        let t = '';
        if (s.idleSeconds != null) {
          if (s.phase === 'waiting') t = dur(s.idleSeconds);
          else if (s.idleSeconds >= 120) t = `(${dur(s.idleSeconds)})`;
        }
        // 用户起的会话名最好认，派生名没信息量就用项目名；后台任务标 ~
        const label = (s.nameUserSet && s.name ? s.name : (s.project || '?')) + (s.kind === 'bg' ? ' ~' : '');
        const phase = s.parked ? 'PARKED' : s.stalled ? 'STALLED' : s.attention === 'permission' ? 'CONFIRM?' : s.attention === 'elicitation' ? 'FORM?' : (PHASE_LABEL[s.phase] || 'STANDBY');
        // 每列都补齐到定宽（含末列）：右对齐 / 居中的槽位靠整行等长才能对齐；名字截满时也要留出列间空格
        return `${fitCols(label.toUpperCase(), 16)} ${phase.padEnd(11)}${t.padEnd(9)}`;
      });
      return { title: `SESSIONS  ${st.activeSessions || 0}`, rows: rows.length ? rows : ['NO ACTIVE SESSION'] };
    },
    clock(st) {
      const d = new Date();
      const rows = [
        `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`,
        `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`,
      ];
      if (st.host && st.host.bootTime) {   // 只在宿主给了真实开机时刻时显示 UPTIME
        const up = Math.max(0, Math.floor(Date.now() / 1000 - st.host.bootTime)), days = Math.floor(up / 86400);
        rows.push(`UPTIME ${days ? days + 'd ' : ''}${pad(Math.floor(up / 3600) % 24)}:${pad(Math.floor(up / 60) % 60)}:${pad(up % 60)}`);
      }
      return { title: 'SYSTEM TIME', rows };
    },
    activity(st) {
      const rows = (st.recentTools || []).slice(0, 9).map(e =>
        `${agoStr(Math.min(e.ago, 3599)).padEnd(8)}${e.tool.slice(0, 14).toUpperCase().padEnd(15)}${(e.project || '').slice(0, 12).padEnd(12)}`);
      return { title: 'ACTIVITY LOG', rows: rows.length ? rows : ['NO RECENT ACTIVITY'] };
    },
    // 每个会话的上下文占用：Claude Code 自己算的（statusline），快满 = 即将压缩 / 该收尾。没有数据整块不画
    context(st) {
      const rows = (st.sessions || []).filter(s => typeof s.contextPct === 'number')
        .sort((a, b) => b.contextPct - a.contextPct)
        .map(s => {
          const label = s.nameUserSet && s.name ? s.name : (s.project || '?');
          const pct = Math.max(0, Math.min(100, s.contextPct));
          return `${fitCols(label.toUpperCase(), 16)} ${bar(pct, 6)} ${String(Math.round(pct)).padStart(3)}%`;
        });
      return rows.length ? { title: 'CONTEXT', rows } : null;
    },
    // 活跃项目的 git 状态：分支 + 未提交文件数——"干的活还没落库"是真事实。没有仓库整块不画
    repos(st) {
      const rows = (st.repos || []).map(r =>
        `${fitCols((r.project || '?').toUpperCase(), 16)} ${fitCols((r.branch || '—').toUpperCase(), 10)} ${r.dirty > 0 ? (String(r.dirty).padStart(3) + ' DIRTY') : '  CLEAN'}`);
      return rows.length ? { title: 'REPOS', rows } : null;
    },
    power(st, opts) {
      const p = computePower(st.quota);
      if (!p) return null;                              // 没有额度数据：整块不画，宁可留空
      let head = `${Math.round(p.remain)}%`;
      if (p.resetsAt > 0 && !p.recharged) head += `   RECHARGE ${hms(p.resetsAt - p.now)}`;
      const rows = [head];
      if (p.reserve != null) rows.push(`RESERVE ${Math.round(p.reserve)}%${p.reserveResetsAt ? '  ·  ' + dhm(p.reserveResetsAt - p.now) : ''}`);
      if (p.stale) rows.push(`AS OF ${clock(p.recordedAt)}`);
      // 英雄件自己画了大环的皮肤（jarvis）不再重复画小环
      return { title: 'POWER', rows, ring: opts.heroShowsPower ? null : p.remain };
    },
    /* 系统资源：整机 CPU / GPU / 内存 / 磁盘 + Claude 占比（SystemProbe，决策 006）。
       每行 = 标签 + 十格条 + 主读数 + 附注，四列定宽，右对齐 / 居中槽位也整齐。
       CLAUDE 列是注册表里各会话进程树（会话进程 + 子进程）的真实占用，只在有已知 pid 的会话时出现；
       拿不到的指标整行不画（如 GPU 读不到 IORegistry），不补零不估算 */
    system(st) {
      const s = st.system;
      if (!s) return null;
      const num = v => typeof v === 'number' && isFinite(v);
      const pct = v => String(Math.round(Math.max(0, Math.min(100, v)))).padStart(3) + '%';
      const gib = b => (b / 1073741824).toFixed(1) + 'G';               // 内存：GiB（活动监视器口径）
      const gb  = b => Math.round(b / 1e9) + 'G';                        // 磁盘：十进制 GB（Finder 口径）
      const rate = b => b >= 1e9 ? (b / 1e9).toFixed(1) + 'G/s' : b >= 1e6 ? (b / 1e6).toFixed(1) + 'M/s' : Math.round(b / 1e3) + 'K/s';
      // 四列定宽：标签 5 + 条 10 + 空格 + 主读数 13 + 附注 20 = 49 列；没有条的行用空格占住条的位置，右对齐时才不错位
      const row = (label, fill, main, extra) => `${label.padEnd(5)}${fill == null ? ' '.repeat(10) : bar(fill, 10)} ${main.padEnd(13)}${(extra || '').padEnd(20)}`;
      const rows = [];
      if (num(s.cpuPct)) rows.push(row('CPU', s.cpuPct, pct(s.cpuPct), num(s.claudeCpuPct) ? `CLAUDE ${pct(s.claudeCpuPct).trim()}` : ''));
      if (num(s.gpuPct)) rows.push(row('GPU', s.gpuPct, pct(s.gpuPct), ''));
      if (num(s.memUsedBytes) && s.memTotalBytes > 0) {
        rows.push(row('MEM', s.memUsedBytes / s.memTotalBytes * 100, `${gib(s.memUsedBytes)}/${gib(s.memTotalBytes)}`,
                      num(s.claudeMemBytes) ? `CLAUDE ${gib(s.claudeMemBytes)}` : ''));
        // 交换与内存压力只在真的有事时占一行：压力等级 2 = 警告、4 = 严重（kern.memorystatus_vm_pressure_level）
        const pressure = s.memPressure >= 4 ? 'PRESSURE CRITICAL' : s.memPressure >= 2 ? 'PRESSURE WARNING' : '';
        if ((num(s.swapUsedBytes) && s.swapUsedBytes > 0) || pressure)
          rows.push(row('SWAP', null, num(s.swapUsedBytes) ? gib(s.swapUsedBytes) : '—', pressure));
      }
      if (num(s.diskUsedBytes) && num(s.diskTotalBytes) && s.diskTotalBytes > 0) {
        const io = num(s.diskReadBps) && num(s.diskWriteBps) ? `R ${rate(s.diskReadBps).padEnd(8)}W ${rate(s.diskWriteBps)}` : '';
        rows.push(row('DISK', s.diskUsedBytes / s.diskTotalBytes * 100, `${gb(s.diskUsedBytes)}/${gb(s.diskTotalBytes)}`, io));
      }
      return rows.length ? { title: 'SYSTEM', rows } : null;
    },
  };

  function drawRing(x, y, r, remain) {
    ctx.save(); ctx.lineCap = 'round'; ctx.lineWidth = 2.5 * S;
    ctx.strokeStyle = rgba(theme.key, 0.25);
    ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.stroke();
    if (remain > 0) {
      ctx.shadowColor = rgba(theme.hi, 0.9); ctx.shadowBlur = 8 * S; ctx.strokeStyle = rgba(theme.hi, 0.9);
      ctx.beginPath(); ctx.arc(x, y, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * remain / 100); ctx.stroke();
    }
    ctx.restore();
  }

  function draw(st, th, opts) {
    ensureCanvas();
    theme = { key: (th && th.key) || theme.key, hi: lift((th && th.hi) || theme.hi) };
    ctx.clearRect(0, 0, W, H);
    // 深色文字光晕：暗底皮肤上不可见，亮底皮肤（极光的橙色警报态）上把文字托出来
    ctx.shadowColor = 'rgba(0,0,0,0.85)';
    ctx.shadowBlur = 5 * S;
    const cfg = (window.__ld && __ld.config && __ld.config.widgets) || {};
    const used = {};   // 同一槽位放了多个小工具时顺向叠放（顶部往下、底部往上），不互相覆盖
    for (const id of Object.keys(WIDGETS)) {
      const slot = cfg[id];
      if (!slot || slot === 'off') continue;
      const a = anchor(slot); if (!a) continue;
      const w = WIDGETS[id](st || {}, opts || {}); if (!w) continue;
      // 标题基线到最后一行基线的高度；底对齐由它倒推标题位置（最后一行落统一底线），中排按块高垂直居中
      const blockH = (17 + (w.rows.length - 1) * 15) * S;
      const y = a.bottomAligned ? H - 53 * S - blockH - (used[slot] || 0)
              : a.middleAligned ? H / 2 - blockH / 2 + (used[slot] || 0)
              : a.y + (used[slot] || 0);
      let extra = 0;
      if (w.ring != null) {   // 紧凑能量环：左右槽位画在面板旁；居中槽位画在标题上方——
        const r = 14 * S;     // 但顶排居中的上方是菜单栏 / 刘海（会被挡），改画在文字下方，块顶边与左上 / 右上的标题齐平
        if (a.align !== 'center') drawRing(a.align === 'left' ? a.x + 200 * S : a.x - 200 * S, y + 14 * S, r, w.ring);
        else if (slot === 'tc') { drawRing(a.x, y + blockH + 30 * S, r, w.ring); extra = 2 * r + 18 * S; }
        else drawRing(a.x, y - 36 * S, r, w.ring);
      }
      panel(a.x, y, a.align, w.title, w.rows);
      used[slot] = (used[slot] || 0) + blockH + 41 * S + extra;   // 本块高度 + 标题区与块间距（+ 画在下方的环）
    }
  }

  window.__ldWidgets = { draw, computePower, hms, dhm, clock, pad };
})();
