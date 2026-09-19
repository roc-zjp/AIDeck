#!/usr/bin/env python3
"""自用验证报告：从 diag.csv（当前）+ diag-YYYY-MM-DD.csv（按日归档）统计这个产品的核心假设是否成立。

两条判据（spec §7）：
  1. 桌面真正露出占比 < 5%  → 桌面层的产品前提不成立
  2. 「等你输入」平均时长随自用天数下降 → 感知确实缩短了响应时间；无变化 → 好看的摆设
判据 2 需要按天看趋势，且要把过夜 / 离机的长段（> LONG_WAIT 秒）单列——它们不是"没看见提醒"，是人不在。
"""
import csv, glob, os, sys, statistics
from collections import Counter, defaultdict
from datetime import datetime, timezone

LONG_WAIT = 3600          # 超过 1 小时的「等你输入」视为过夜 / 离机，不参与判据 2 的平均

here = os.path.dirname(os.path.abspath(__file__))
files = sorted(glob.glob(os.path.join(here, 'diag-*.csv'))) + [os.path.join(here, 'diag.csv')]
files = [f for f in files if os.path.exists(f)]
if not files:
    print("还没有数据，先让它跑一段时间（./ld start 默认带 --log）")
    sys.exit()

rows = []
for f in files:
    with open(f, newline='') as fh:
        # 崩溃 / 断电可能留下半行（ts 为空或被截断），跳过
        rows.extend(r for r in csv.DictReader(fh) if r.get('phase') and len(r.get('ts') or '') >= 13)
if not rows:
    print("还没有数据")
    sys.exit()

# ts 是 UTC（2026-08-28T10:23:25Z），按本地日期分组。逐行 strptime 太慢，按"小时"缓存换算结果
LOCAL_TZ = datetime.now().astimezone().tzinfo
_day_cache = {}
def local_day(ts):
    k = ts[:13]
    d = _day_cache.get(k)
    if d is None:
        try:
            d = datetime.strptime(k, '%Y-%m-%dT%H').replace(tzinfo=timezone.utc).astimezone(LOCAL_TZ).strftime('%Y-%m-%d')
        except ValueError:
            d = ts[:10]
        _day_cache[k] = d
    return d

def rj(s, width):
    """按显示宽度右对齐：中文占两格，str.rjust 只按字符数会把表头挤歪"""
    w = sum(2 if ord(c) > 0x2E80 else 1 for c in s)
    return ' ' * max(0, width - w) + s

def dur(sec):
    sec = int(round(sec))
    if sec >= 3600:
        return f"{sec // 3600}h{sec % 3600 // 60:02d}m"
    return f"{sec // 60}m{sec % 60:02d}s"

n = len(rows)
pct = lambda k, total=n: 100.0 * k / total if total else 0.0
vis = sum(1 for r in rows if r.get('vis') == 'visible')
rend = sum(1 for r in rows if r.get('rendering') == '1')
ph = Counter(r['phase'] for r in rows)

# 「等你输入」的段：连续 waiting 行为一段，时长 = 行数（每行一秒；app 没跑的时间不算），归到段开始那天
segs, cur, cur_day = [], 0, None
for r in rows:
    if r['phase'] == 'waiting':
        if cur == 0:
            cur_day = local_day(r['ts'])
        cur += 1
    elif cur:
        segs.append((cur_day, cur)); cur = 0
if cur:
    segs.append((cur_day, cur))

print(f"样本 {n} 秒（约 {n / 3600:.1f} 小时，{len(files)} 个文件）")
print()
print(f"桌面真正露出        {pct(vis):5.1f}%    <- 低于 5% 则产品前提不成立")
print(f"动画实际在渲染      {pct(rend):5.1f}%    <- 功耗代理指标")
print()
print("状态时长分布：")
for k, name in [('running', '执行工具'), ('thinking', '思考中'), ('waiting', '等你输入'), ('idle', '空闲')]:
    if ph.get(k):
        print(f"  {name:6s} {pct(ph[k]):5.1f}%")

short = [s for _, s in segs if s <= LONG_WAIT]
long_ = [s for _, s in segs if s > LONG_WAIT]
if segs:
    print()
    print(f"「等你输入」共 {len(segs)} 段：")
    if short:
        print(f"  ≤{LONG_WAIT // 60} 分钟的 {len(short)} 段：平均 {dur(statistics.mean(short))}，中位数 {dur(statistics.median(short))}，"
              f"P90 {dur(sorted(short)[int(len(short) * 0.9) - 1 if len(short) > 1 else 0])}")
    if long_:
        print(f"  >{LONG_WAIT // 60} 分钟的 {len(long_)} 段（过夜 / 离机，单列不计入判据）：最长 {dur(max(long_))}")

# 按日：判据 2 看「平均」那一列是否随日期下降
by_day = defaultdict(lambda: {'n': 0, 'vis': 0, 'rend': 0})
for r in rows:
    d = by_day[local_day(r['ts'])]
    d['n'] += 1
    d['vis'] += r.get('vis') == 'visible'
    d['rend'] += r.get('rendering') == '1'
seg_by_day = defaultdict(list)
for day, s in segs:
    seg_by_day[day].append(s)

print()
print(f"按日（本地日期）——判据 2 看「平均」是否逐日下降；不足一整天的首尾日参考意义有限：")
print("  " + "日期      " + rj('样本', 7) + "  " + rj('桌面露出', 7) + "  " + rj('渲染', 6) + "  "
      + rj('等待段', 6) + "  " + rj('平均', 8) + "  " + rj('中位数', 8) + "  " + rj('>60m', 5))
for day in sorted(by_day):
    d = by_day[day]
    ss = [s for s in seg_by_day.get(day, []) if s <= LONG_WAIT]
    ls = [s for s in seg_by_day.get(day, []) if s > LONG_WAIT]
    avg = dur(statistics.mean(ss)) if ss else '-'
    med = dur(statistics.median(ss)) if ss else '-'
    print(f"  {day:<10}{d['n'] / 3600:6.1f}h  {pct(d['vis'], d['n']):6.1f}%  {pct(d['rend'], d['n']):5.1f}%  "
          f"{len(ss):6d}  {avg:>8}  {med:>8}  {len(ls):5d}")
