import Foundation
import IOKit

/// 一拍系统资源快照（SYSTEM 小工具的数据源）。
/// 每个数都来自内核 / IORegistry 的真实计数，拿不到的字段留 nil，页面照「宁可留空」不画那一行。
/// 通用机器总量 iStat Menus 早做透了，这里独有的是 **Claude 占比**：按注册表里的会话 pid 连同全部后代进程
/// （Bash 工具起的 shell、构建 / 测试、MCP server）算出 Claude Code 自己吃了多少 CPU 与内存——哪个会话在烧机器一眼可见。
struct SystemSnapshot {
    var cpuPct: Double?           // 全机 CPU 利用率（所有核平均，0–100）；首拍没有差分基线为 nil
    var cpuCores: Int
    var claudeCpuPct: Double?     // Claude 会话进程树占全机的百分比，与 cpuPct 同口径（核数归一）；没有已知 pid 的会话为 nil
    var gpuPct: Double?           // IOAccelerator PerformanceStatistics 的 Device Utilization %（多 GPU 取最大）
    var memUsedBytes: UInt64?     // 活动监视器「已使用内存」口径：App 内存（internal − purgeable）+ 联动 + 已压缩
    var memTotalBytes: UInt64
    var swapUsedBytes: UInt64?
    var memPressure: Int?         // kern.memorystatus_vm_pressure_level：1 正常 / 2 警告 / 4 严重
    var claudeMemBytes: UInt64?   // Claude 会话进程树的 phys_footprint 之和（活动监视器「内存」列的口径）
    var diskUsedBytes: UInt64?    // 启动卷：总量 − 可用（Finder 口径 volumeAvailableCapacityForImportantUsage）
    var diskTotalBytes: UInt64?
    var diskReadBps: Double?      // 所有块设备累计读写做差；首拍 nil
    var diskWriteBps: Double?
    var probeMillis: Double = 0

    var jsonObject: [String: Any] {
        ["cpuPct": cpuPct as Any, "cpuCores": cpuCores, "claudeCpuPct": claudeCpuPct as Any,
         "gpuPct": gpuPct as Any,
         "memUsedBytes": memUsedBytes as Any, "memTotalBytes": memTotalBytes,
         "swapUsedBytes": swapUsedBytes as Any, "memPressure": memPressure as Any,
         "claudeMemBytes": claudeMemBytes as Any,
         "diskUsedBytes": diskUsedBytes as Any, "diskTotalBytes": diskTotalBytes as Any,
         "diskReadBps": diskReadBps as Any, "diskWriteBps": diskWriteBps as Any,
         "probeMillis": probeMillis]
    }
}

/// 每拍采样一次（跟 tick 同频，1s）。差分类指标（CPU / 磁盘吞吐）对最近约 3 秒的窗口做差：
/// 比单拍差分平滑、又仍是真实平均值，不是估算或指数衰减出来的数。
/// 成本实测：IORegistry 两次读 ≈0.3ms，进程树 rusage 每进程几微秒；不渲染时也采（窗口要连续），总量 <1ms/s。
final class SystemProbe {
    private struct Sample {
        var at: TimeInterval           // Date 秒
        var machAt: UInt64             // mach_absolute_time，用来判定进程是不是窗口内新起的
        var busy: UInt64, total: UInt64
        var procCpuNs: [pid_t: Double] // 进程树里每个进程的累计 CPU 时间（ns）
        var diskR: UInt64, diskW: UInt64
    }
    private var history: [Sample] = []
    private let windowSeconds: TimeInterval = 3
    private let hostPort = mach_host_self()   // 缓存：每拍 mach_host_self() 会累积端口引用
    private let cores = ProcessInfo.processInfo.activeProcessorCount
    private let toNs: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private var diskCap: (used: UInt64, total: UInt64, at: TimeInterval)?   // 容量 10s 刷一次就够

    /// 采样并写回 state：`state.system` 整机快照，`state.sessions[i].cpuPct / memBytes` 各会话进程树
    func sample(_ state: inout ClaudeState) {
        let t0 = Date()
        var snap = SystemSnapshot(cpuCores: cores, memTotalBytes: ProcessInfo.processInfo.physicalMemory)

        // ── 进程树：会话 pid + 全部后代 ──
        var trees: [Int: [pid_t]] = [:]            // sessions 下标 → 进程树
        var procCpu: [pid_t: Double] = [:]
        var procMem: [pid_t: UInt64] = [:]
        var procStart: [pid_t: UInt64] = [:]
        for (i, s) in state.sessions.enumerated() where s.pid > 0 {
            let tree = descendants(of: s.pid)
            trees[i] = tree
            for p in tree where procCpu[p] == nil {
                if let ru = rusage(p) { procCpu[p] = ru.cpuNs; procMem[p] = ru.footprint; procStart[p] = ru.startAbs }
            }
        }

        let now = Sample(at: t0.timeIntervalSince1970, machAt: mach_absolute_time(),
                         busy: 0, total: 0, procCpuNs: procCpu, diskR: 0, diskW: 0)
        var cur = now
        (cur.busy, cur.total) = cpuTicks()
        (cur.diskR, cur.diskW) = diskCounters()

        // ── 差分：对窗口内最老的一拍 ──
        if let base = history.first {
            let dt = cur.at - base.at
            if cur.total > base.total {
                snap.cpuPct = Double(cur.busy - base.busy) / Double(cur.total - base.total) * 100
            }
            if dt > 0.2 {
                if cur.diskR >= base.diskR { snap.diskReadBps = Double(cur.diskR - base.diskR) / dt }
                if cur.diskW >= base.diskW { snap.diskWriteBps = Double(cur.diskW - base.diskW) / dt }
                // 进程 CPU：两拍都在的做差；窗口内新起的进程（启动时刻晚于基线拍）累计值全部落在窗口内，整段计入；
                // 早就存在、只是刚进入进程树的（比如新注册的会话）等下一拍有基线再算，宁少不多
                func treePct(_ tree: [pid_t]) -> Double {
                    var ns = 0.0
                    for p in tree {
                        guard let c = procCpu[p] else { continue }
                        if let b = base.procCpuNs[p] { ns += max(0, c - b) }
                        else if let st = procStart[p], st >= base.machAt { ns += c }
                    }
                    return ns / (dt * 1e9) / Double(cores) * 100
                }
                if !trees.isEmpty {
                    var all = Set<pid_t>()
                    for (i, tree) in trees {
                        state.sessions[i].cpuPct = treePct(tree)
                        state.sessions[i].memBytes = tree.reduce(0) { $0 + (procMem[$1] ?? 0) }
                        all.formUnion(tree)
                    }
                    snap.claudeCpuPct = treePct(Array(all))
                    snap.claudeMemBytes = all.reduce(0) { $0 + (procMem[$1] ?? 0) }
                }
            }
        } else if !trees.isEmpty {
            // 首拍：CPU 没基线，内存是瞬时值可以直接给
            var all = Set<pid_t>()
            for (i, tree) in trees {
                state.sessions[i].memBytes = tree.reduce(0) { $0 + (procMem[$1] ?? 0) }
                all.formUnion(tree)
            }
            snap.claudeMemBytes = all.reduce(0) { $0 + (procMem[$1] ?? 0) }
        }
        history.append(cur)
        history.removeAll { cur.at - $0.at > windowSeconds + 0.5 }

        // ── 瞬时值 ──
        snap.gpuPct = gpuUtilization()
        let vm = vmStats()
        snap.memUsedBytes = vm.used; snap.swapUsedBytes = vm.swap; snap.memPressure = vm.pressure
        if diskCap == nil || cur.at - diskCap!.at > 10 {
            if let c = diskCapacity() { diskCap = (c.used, c.total, cur.at) }
        }
        if let c = diskCap { snap.diskUsedBytes = c.used; snap.diskTotalBytes = c.total }

        snap.probeMillis = Date().timeIntervalSince(t0) * 1000
        state.system = snap
    }

    // MARK: - 进程

    private func descendants(of root: pid_t) -> [pid_t] {
        var out = [root], queue = [root], seen: Set<pid_t> = [root]
        while let p = queue.popLast(), out.count < 512 {
            for c in children(of: p) where !seen.contains(c) { seen.insert(c); out.append(c); queue.append(c) }
        }
        return out
    }
    private func children(of pid: pid_t) -> [pid_t] {
        let n = proc_listchildpids(pid, nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 8)
        let got = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return got > 0 ? Array(buf[0..<Int(got)]) : []
    }
    /// rusage_info_v4：CPU 时间（mach 时基，换成 ns）、phys_footprint、进程启动时刻。
    /// 坑：C 声明写的是 `rusage_info_t *`，内核却把这个指针值当 copyout 目的地，必须把结构体地址本身强转传入，
    /// 老实传「指针的地址」会被写穿栈直接 abort（见 docs/issues.md）
    private func rusage(_ pid: pid_t) -> (cpuNs: Double, footprint: UInt64, startAbs: UInt64)? {
        var ri = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        return (Double(ri.ri_user_time + ri.ri_system_time) * toNs, ri.ri_phys_footprint, ri.ri_proc_start_abstime)
    }

    // MARK: - 整机

    private func cpuTicks() -> (busy: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard rc == KERN_SUCCESS else { return (0, 0) }
        let u = UInt64(info.cpu_ticks.0), s = UInt64(info.cpu_ticks.1), i = UInt64(info.cpu_ticks.2), n = UInt64(info.cpu_ticks.3)
        return (u + s + n, u + s + n + i)
    }

    private func vmStats() -> (used: UInt64?, swap: UInt64?, pressure: Int?) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(hostPort, HOST_VM_INFO64, $0, &count) }
        }
        var used: UInt64? = nil
        if rc == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let app = UInt64(vm.internal_page_count) &- UInt64(min(vm.purgeable_count, vm.internal_page_count))
            used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        }
        var sw = xsw_usage(); var swLen = MemoryLayout<xsw_usage>.size
        let swap: UInt64? = sysctlbyname("vm.swapusage", &sw, &swLen, nil, 0) == 0 ? sw.xsu_used : nil
        var level: Int32 = 0; var lLen = MemoryLayout<Int32>.size
        let pressure: Int? = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &lLen, nil, 0) == 0 ? Int(level) : nil
        return (used, swap, pressure)
    }

    private func diskCapacity() -> (used: UInt64, total: UInt64)? {
        guard let rv = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = rv.volumeTotalCapacity, let avail = rv.volumeAvailableCapacityForImportantUsage, total > 0 else { return nil }
        return (UInt64(max(0, Int64(total) - avail)), UInt64(total))
    }

    // MARK: - IORegistry

    private func iterate(_ className: String, _ body: (io_registry_entry_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        var e = IOIteratorNext(it)
        while e != 0 { body(e); IOObjectRelease(e); e = IOIteratorNext(it) }
    }
    private func property(_ e: io_registry_entry_t, _ key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
    }
    /// Apple Silicon（AGXAccelerator）与 Intel（IntelAccelerator）都在 PerformanceStatistics 里给 Device Utilization %
    private func gpuUtilization() -> Double? {
        var out: Double? = nil
        iterate("IOAccelerator") { e in
            if let d = property(e, "PerformanceStatistics"), let v = d["Device Utilization %"] as? NSNumber {
                out = max(out ?? 0, v.doubleValue)
            }
        }
        return out
    }
    private func diskCounters() -> (r: UInt64, w: UInt64) {
        var r: UInt64 = 0, w: UInt64 = 0
        iterate("IOBlockStorageDriver") { e in
            if let d = property(e, "Statistics") {
                r += (d["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w += (d["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
        }
        return (r, w)
    }
}
