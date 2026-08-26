#!/usr/bin/env python3
"""分进程累计 CPU 时间差测量（app + 其 WebKit 子进程）。
系统上的其他负载不会污染读数。用 --force-* 参数固定渲染状态，保证各组可比。
GPU 能耗需要 sudo powermetrics，本脚本不覆盖。"""
import subprocess, time, os, sys

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "build/LiveDesktopSpike.app/Contents/MacOS/LiveDesktopSpike")
SECS = int(sys.argv[1]) if len(sys.argv) > 1 else 20

def webkit_pids():
    out = subprocess.run(['pgrep','-f','com.apple.WebKit'], capture_output=True, text=True).stdout
    return {int(x) for x in out.split()}

def cputime(pids):
    total = 0.0
    for pid in pids:
        out = subprocess.run(['ps','-o','cputime=','-p',str(pid)],
                             capture_output=True, text=True).stdout.strip()
        if not out: continue
        parts = out.replace('-', ':').split(':')
        try:
            if len(parts) == 2:   total += float(parts[0])*60 + float(parts[1])
            elif len(parts) == 3: total += float(parts[0])*3600 + float(parts[1])*60 + float(parts[2])
        except ValueError: pass
    return total

def stop():
    subprocess.run(['pkill','-f','MacOS/LiveDesktopSpike'], capture_output=True)
    time.sleep(2)

def scenario(label, args):
    stop()
    before = webkit_pids()
    p = subprocess.Popen([BIN]+args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(5)
    pids = {p.pid} | (webkit_pids() - before)
    t0, c0 = time.time(), cputime(pids)
    time.sleep(SECS)
    dt, dc = time.time()-t0, cputime(pids)-c0
    pct = dc/dt*100
    print(f"{label:34s} {pct:6.2f}% CPU   ({dc:.2f}s / {dt:.0f}s)", flush=True)
    stop()
    return pct

if __name__ == '__main__':
    print(f"=== 纯渲染开销（关闭状态探测，排除其噪声；每组 {SECS}s）===\n", flush=True)
    base = scenario("① 常驻不渲染（闸门关闭态）",     ['--force-pause','--no-probe','--animation','pulse.html'])
    anims = {}
    for a in ['pulse.html','neural.html','aurora.html']:
        anims[a] = scenario(f"② {a:<12} 全速渲染", ['--force-render','--no-probe','--animation',a])
    print(f"\n{'—'*64}")
    print(f"常驻底噪（进程挂着、闸门已停渲染）  {base:6.2f}%")
    for a,v in anims.items():
        print(f"{a:<14} 渲染净开销  +{v-base:6.2f}%   → 闸门可省 {(1-base/v)*100:4.1f}%")
