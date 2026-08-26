#!/usr/bin/env python3
"""自用验证报告：从 diag.csv 统计这个产品的核心假设是否成立。"""
import csv, os, sys
from collections import Counter

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'diag.csv')
if not os.path.exists(path):
    print("还没有数据，先让它跑一段时间")
    sys.exit()

rows = [r for r in csv.DictReader(open(path)) if r.get('phase')]
if not rows:
    print("还没有数据")
    sys.exit()

n = len(rows)
pct = lambda k: 100.0 * k / n
vis = sum(1 for r in rows if r.get('vis') == 'visible')
rend = sum(1 for r in rows if r.get('rendering') == '1')
ph = Counter(r['phase'] for r in rows)

segs, cur = [], 0
for r in rows:
    if r['phase'] == 'waiting':
        cur += 1
    elif cur:
        segs.append(cur); cur = 0
if cur:
    segs.append(cur)

print(f"样本 {n} 秒（约 {n/3600:.1f} 小时）")
print()
print(f"桌面真正露出        {pct(vis):5.1f}%    <- 低于 5% 则产品前提不成立")
print(f"动画实际在渲染      {pct(rend):5.1f}%    <- 功耗代理指标")
print()
print("状态时长分布：")
for k, name in [('running','执行工具'), ('thinking','思考中'), ('waiting','等你输入'), ('idle','空闲')]:
    if ph.get(k):
        print(f"  {name:6s} {pct(ph[k]):5.1f}%")
if segs:
    print()
    print(f"「等你输入」出现 {len(segs)} 次，平均持续 {sum(segs)/len(segs):.0f} 秒，最长 {max(segs)} 秒")
    print("  <- 若平均时长随自用天数下降，说明桌面提示确实让你更快回到会话")
