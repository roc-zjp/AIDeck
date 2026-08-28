import CoreServices
import Foundation

/// Claude 当前所处阶段。顺序即优先级（越靠后越"活跃"）。
enum ClaudePhase: String {
    case idle       // 没有活跃会话
    case waiting    // 已回答完，正在等你输入 —— 桌面最该突出的状态
    case thinking   // 收到输入/工具结果，正在推理
    case running    // 正在执行工具
}

struct SessionState {
    var id = ""               // 注册表 sessionId：AlertEngine 用它做「每次等待只通知一次」的身份
    var pid: Int32 = 0        // 会话进程：通知点击沿祖先链找终端 App
    var project: String       // 项目名 = 会话启动目录末段（来自注册表 cwd，不随会话里的 cd 漂移）
    var name: String?         // 会话名（注册表 name：/rename 起的，或系统派生的）
    var nameIsUserSet: Bool   // 派生名只是项目名加后缀，没信息量；用户起的名才值得显示
    var kind: String          // interactive / bg
    var branch: String?
    var phase: ClaudePhase
    var tool: String?         // running 时的工具名
    var idleSeconds: Int      // 等你输入：距 Claude 说完（注册表 statusUpdatedAt）；工作中：距 jsonl 最后一次写入
    var stalled = false       // 注册表说 busy，但太久没有任何输出：思考中 ≥10 分钟 / 执行工具 ≥30 分钟
    var parked = false        // 把作业转入了后台（parkedJobId 对应一个活着的 bg 会话）：本体不算停滞也不算在跑，
                              // 活儿由那个 bg 会话代表。实测"busy 挂 8.6 小时"的会话就是这种，不是僵尸
    var contextPct: Double?   // 上下文占用百分比：Claude Code 自己算的（statusline 的 context_window，经 ld-statusline 按会话记录）
    var cpuPct: Double?       // 会话进程树（会话进程 + 全部后代）占全机 CPU 的百分比（SystemProbe 每拍写入；没有 pid 为 nil）
    var memBytes: UInt64?     // 会话进程树的 phys_footprint 之和（活动监视器「内存」列口径）
}

/// 一个活跃项目的 git 状态
struct RepoState {
    var project: String
    var branch: String
    var dirty: Int            // 未提交文件数（含未跟踪）
    var committedAt: Double   // 最近一次检测到新 commit 的墙钟时刻（0=无），页面据此触发庆祝
}

/// 一次真实的工具调用。贾维斯式界面的"数据流"用它填充，不造假数据。
struct ToolEvent {
    var tool: String
    var project: String
    var agoSeconds: Int
}

struct ClaudeState {
    var phase: ClaudePhase = .idle
    var tool: String?
    var project: String?
    var name: String?                   // 最活跃会话的用户自定义名（没有则 nil，用 project）
    var branch: String?
    var sessions: [SessionState] = []
    var repos: [RepoState] = []         // 活跃项目的 git 状态（GitProbe 后台刷新）
    var recentTools: [ToolEvent] = []   // 跨会话合并、按时间倒序
    var quota: QuotaSnapshot?           // 五小时 / 七天额度（来自 statusline 记录，可能为空）
    var system: SystemSnapshot?         // 整机 CPU / GPU / 内存 / 磁盘 + Claude 进程树占比（SystemProbe 每拍写入）
    var probeMillis: Double = 0   // 本轮探测耗时，用于评估轮询开销

    var jsonObject: [String: Any] {
        [
            "phase": phase.rawValue,
            "tool": tool as Any,
            "project": project as Any,
            "name": name as Any,
            "branch": branch as Any,
            "activeSessions": sessions.count,
            "recentTools": recentTools.map {
                ["tool": $0.tool, "project": $0.project, "ago": $0.agoSeconds]
            },
            "sessions": sessions.map {
                ["project": $0.project, "name": $0.name as Any, "nameUserSet": $0.nameIsUserSet,
                 "kind": $0.kind, "branch": $0.branch as Any,
                 "phase": $0.phase.rawValue, "tool": $0.tool as Any,
                 "idleSeconds": $0.idleSeconds, "stalled": $0.stalled, "parked": $0.parked,
                 "contextPct": $0.contextPct as Any,
                 "cpuPct": $0.cpuPct as Any, "memBytes": $0.memBytes as Any]
            },
            "repos": repos.map { ["project": $0.project, "branch": $0.branch, "dirty": $0.dirty, "committedAt": $0.committedAt] },
            "quota": quota?.jsonObject as Any,
            "system": system?.jsonObject as Any,
            "probeMillis": probeMillis
        ]
    }
}

/// 零侵入探测：只读 ~/.claude 下的文件，不改用户任何配置。
///
/// 会话枚举以 Claude Code **自己维护的注册表** `~/.claude/sessions/<pid>.json` 为准——
/// 它直接给出进程 pid（可判活）、busy / idle、会话名、启动目录。jsonl 只用来看"最后一条是谁说的"与工具调用流。
/// 早先只靠 jsonl 反推，得用 90 秒新鲜度猜会话死活：一条跑几分钟的工具、一次长推理都会被误判成死会话而消失，
/// 反应堆就落到别的"等你输入"上。见 decisions/007。
final class ClaudeStateProbe {
    /// 与 Claude Code / QuotaInstaller 一致：尊重 CLAUDE_CONFIG_DIR（也便于用沙箱目录测试回退路径）
    private let claudeDir: URL = {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }()
    private var projectsDir: URL { claudeDir.appendingPathComponent("projects", isDirectory: true) }
    private var sessionsDir: URL { claudeDir.appendingPathComponent("sessions", isDirectory: true) }
    private let tailBytes = 96 * 1024
    private var transcriptCache: [String: URL] = [:]   // sessionId → jsonl
    private let git = GitProbe()
    private var ctxDir: URL { QuotaProbe.dir.appendingPathComponent("ctx", isDirectory: true) }

    // 事件驱动（2026-08-27）：贵的部分是每会话每秒读 96KB jsonl 尾 + JSON 解析（全量扫 22–28ms 且随活跃度波动），
    // 改为 FSEvents 报哪个文件变了才重读哪个，平时每拍纯内存组装。时间驱动的字段（idleSeconds / 停滞判定 /
    // pid 判活）不依赖文件事件：判活每拍 kill() 现算——进程死了不会产生任何文件事件。
    // 三道保险：watcher 创建失败（目录缺失等）回退每拍全量；每 30s 用 mtime 对账自愈；ctx 搭会话重读的车刷新
    private var watcher: FSWatcher?
    private var registryAvailable = false                  // 注册表目录存在（新版 Claude Code）；否则回退 jsonl 反推
    private var fallbackCandidates: [String: URL] = [:]    // 回退模式的发现集：sessionId → jsonl
    private var regCache: [Registered] = []
    private var regDirty = true
    private var dirtyTranscripts: Set<String> = []
    private var tailCache: [String: CachedTranscript] = [:]
    private var ctxCache: [String: Double] = [:]
    private var tickCount = 0
    private var healRequested = false

    /// 让下一拍走全量对账（系统唤醒后 FSEvents 可能丢了一段事件，不等 30s 周期）
    func requestHeal() { healRequested = true }

    init() {
        registryAvailable = FileManager.default.fileExists(atPath: sessionsDir.path)
        startWatcher()
    }

    /// 有哪个目录就看哪个：注册表目录缺失（旧版 Claude Code）时只看 projects、回退 jsonl 反推；
    /// 连 projects 都没有则无 watcher（heal 恒真，每拍全量，行为与最早版本一致）
    private func startWatcher() {
        let fm = FileManager.default
        let paths = [sessionsDir.path, projectsDir.path].filter { fm.fileExists(atPath: $0) }
        guard !paths.isEmpty else { watcher = nil; return }
        watcher = FSWatcher(paths: paths) { [weak self] changed in
            guard let self else { return }
            for p in changed {
                if p.hasPrefix(self.sessionsDir.path) {
                    self.regDirty = true
                } else if p.hasSuffix(".jsonl") {
                    let u = URL(fileURLWithPath: p)
                    self.dirtyTranscripts.insert(u.deletingPathExtension().lastPathComponent)
                    // 回退模式：只认 projects/<项目>/<会话>.jsonl 顶层主会话文件（子目录是 subagent/workflow），事件即发现
                    if !self.registryAvailable,
                       u.deletingLastPathComponent().deletingLastPathComponent().path == self.projectsDir.path {
                        self.fallbackCandidates[u.deletingPathExtension().lastPathComponent] = u
                    }
                }
            }
        }
    }

    /// 注册表里一条会话记录
    private struct Registered {
        var pid: Int32
        var sessionId: String
        var cwd: String
        var status: String            // busy / idle
        var statusUpdatedAt: Date?    // 状态翻转时刻（毫秒 epoch）
        var name: String?
        var nameSource: String?       // derived = 系统派生；其他 = 用户起的
        var kind: String              // interactive / bg
        var jobId: String?            // bg 会话：自己的作业 id
        var parkedJobId: String?      // interactive 会话：转入后台的作业 id（与某个 bg 会话的 jobId 对应）
    }

    func probe() -> ClaudeState {
        let t0 = Date()
        var state = ClaudeState()
        let now = Date()
        tickCount += 1

        // 自愈对账：FSEvents 可能丢事件、ctx 目录可能后建。没有 watcher 时每拍都走这条路，行为与旧版一致
        let heal = watcher == nil || tickCount % 30 == 0 || healRequested
        healRequested = false

        // 注册表目录可能后建（旧版升级 / 新装后的首个会话）：对账拍复查，出现即切回注册表模式
        if heal, !registryAvailable, FileManager.default.fileExists(atPath: sessionsDir.path) {
            registryAvailable = true
            regDirty = true
            fallbackCandidates.removeAll()
            startWatcher()      // 重建 stream，把 sessions 目录也看上
        }
        let dirty = dirtyTranscripts
        dirtyTranscripts.removeAll()

        let liveIds: Set<String>
        let cwds: [String]
        if registryAvailable {
            (liveIds, cwds) = assembleFromRegistry(into: &state, now: now, heal: heal, dirty: dirty)
        } else {
            (liveIds, cwds) = assembleFromTranscripts(into: &state, now: now, heal: heal, dirty: dirty)
        }
        // 会话没了（注册表移除 / 进程死了 / 超窗）就清缓存
        tailCache = tailCache.filter { liveIds.contains($0.key) }
        ctxCache = ctxCache.filter { liveIds.contains($0.key) }
        transcriptCache = transcriptCache.filter { liveIds.contains($0.key) }   // 以前漏了它：每个见过的会话永久留一条

        // 活跃项目的 git 状态：按会话启动目录去重，GitProbe 后台刷新缓存
        let repos = git.snapshot(cwds)
        state.repos = cwds.compactMap { cwd in
            repos[cwd].map { RepoState(project: URL(fileURLWithPath: cwd).lastPathComponent, branch: $0.branch, dirty: $0.dirty, committedAt: $0.committedAt) }
        }.sorted { $0.project < $1.project }

        // 全局态取最活跃的一个：running > thinking > waiting；同级取最近有动静的。
        // 停滞的不参与（不能让僵尸会话把反应堆霸占成"推理中"）；转后台的也不参与（活儿由 bg 会话代表）
        let rank: [ClaudePhase: Int] = [.idle: 0, .waiting: 1, .thinking: 2, .running: 3]
        if let top = state.sessions.filter({ !$0.stalled && !$0.parked })
            .max(by: { (rank[$0.phase] ?? 0, -$0.idleSeconds) < (rank[$1.phase] ?? 0, -$1.idleSeconds) }) {
            state.phase = top.phase
            state.tool = top.tool
            state.project = top.project
            state.name = top.nameIsUserSet ? top.name : nil
            state.branch = top.branch
        }
        // 工具流：缓存里存的是绝对时间，组装时换算 ago
        state.recentTools = Array(
            liveIds.compactMap { tailCache[$0] }
                .flatMap { $0.tools }
                .map { ToolEvent(tool: $0.tool, project: $0.project,
                                 agoSeconds: max(0, Int(now.timeIntervalSince($0.date)))) }
                .sorted { $0.agoSeconds < $1.agoSeconds }
                .prefix(14))
        state.probeMillis = Date().timeIntervalSince(t0) * 1000
        return state
    }

    /// 注册表模式（决策 007）：pid 判活、busy/idle、会话名都来自 Claude Code 自己的注册表
    private func assembleFromRegistry(into state: inout ClaudeState, now: Date, heal: Bool,
                                      dirty: Set<String>) -> (Set<String>, [String]) {
        if regDirty || heal { regCache = readRegistry(); regDirty = false }
        let regs = regCache.filter { kill($0.pid, 0) == 0 || errno == EPERM }   // 判活每拍现算：进程死了没有文件事件
        let liveBgJobs = Set(regs.filter { $0.kind == "bg" }.compactMap { $0.jobId })
        var liveIds: Set<String> = []
        for reg in regs {
            guard let url = transcriptURL(for: reg) else { continue }
            liveIds.insert(reg.sessionId)
            let project = URL(fileURLWithPath: reg.cwd).lastPathComponent
            guard let entry = refreshTranscript(id: reg.sessionId, url: url, project: project,
                                                heal: heal, dirty: dirty) else { continue }
            let mtime = entry.mtime
            let tail = entry.tail

            let busy = reg.status == "busy"
            let phase: ClaudePhase
            var tool: String?
            switch (busy, tail.last) {
            case (true, .toolUse(let name)?): phase = .running; tool = name
            case (true, _):                   phase = .thinking
            case (false, .assistantText?),
                 (false, .toolUse?):          phase = .waiting     // 说完了 / 工具中途被你打断后停下：球都在你这边
            case (false, .user?):             phase = .thinking    // 你刚发出去，注册表还没翻成 busy
            case (false, nil):                continue             // 还没开口的空会话，不列
            }
            if reg.kind == "bg" && phase == .waiting { continue }   // 后台任务收尾不是在等你

            // 等你输入：从 Claude 说完那一刻算（Claude Code 自己记的时刻）；工作中：距最后一次写入，用来如实标出长时间无输出
            let since = phase == .waiting ? (reg.statusUpdatedAt ?? mtime) : mtime
            let idle = max(0, Int(now.timeIntervalSince(since)))
            // 转后台：parkedJobId 对应一个活着的 bg 会话——本体沉默是正常的，不算停滞，活儿由 bg 会话代表
            let parked = reg.parkedJobId.map { liveBgJobs.contains($0) } ?? false
            // 停滞判定：busy 但太久没有任何输出（含 subagent 侧链）。模型回复几分钟内必有落盘，
            // 工具（构建等）可以更久；超过阈值就不再冒充"在工作"
            let stalled = !parked && busy && idle >= (phase == .running ? 1800 : 600)
            state.sessions.append(SessionState(
                id: reg.sessionId, pid: reg.pid,
                project: project, name: reg.name,
                nameIsUserSet: reg.nameSource != nil && reg.nameSource != "derived",
                kind: reg.kind, branch: tail.branch, phase: phase, tool: tool,
                idleSeconds: idle, stalled: stalled, parked: parked,
                contextPct: ctxCache[reg.sessionId]))
        }
        return (liveIds, Array(Set(regs.map { $0.cwd })))
    }

    /// 回退模式（注册表目录不存在的旧版 Claude Code）：纯 jsonl 反推，沿用决策 007 之前验证过的启发式。
    /// 已知短板照旧、如实呈现：没有 pid（通知点击唤不起终端）、没有 busy 位（分不清「工具在跑」和「你打断了工具」，
    /// 一律按 running 算）、没有会话名；跑超过 90 秒不落盘的长工具/长推理会被误判为死会话而消失
    private func assembleFromTranscripts(into state: inout ClaudeState, now: Date, heal: Bool,
                                         dirty: Set<String>) -> (Set<String>, [String]) {
        // 发现：对账拍全量枚举 projects/<项目>/ 顶层 jsonl（子目录是 subagent/workflow，跳过）；
        // 平时靠 FSEvents——.jsonl 一有写入就是活的，事件即发现
        if heal || fallbackCandidates.isEmpty {
            fallbackCandidates.removeAll()
            if let dirs = try? FileManager.default.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) {
                for dir in dirs {
                    guard let files = try? FileManager.default.contentsOfDirectory(
                        at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                    for f in files where f.pathExtension == "jsonl" {
                        let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        if now.timeIntervalSince(m) < Self.fallbackWaitingWindow {
                            fallbackCandidates[f.deletingPathExtension().lastPathComponent] = f
                        }
                    }
                }
            }
        }
        var rows: [(SessionState, Date)] = []
        var liveIds: Set<String> = []
        var cwds: Set<String> = []
        for (sid, url) in fallbackCandidates {
            guard let entry = refreshTranscript(id: sid, url: url, project: nil, heal: heal, dirty: dirty)
            else { continue }
            let age = now.timeIntervalSince(entry.mtime)
            if age >= Self.fallbackWaitingWindow { continue }       // 超过等待窗口视为结束（对账拍会剔出候选）
            let phase: ClaudePhase
            var tool: String?
            switch entry.tail.last {
            case .toolUse(let name)?: phase = .running; tool = name
            case .assistantText?:     phase = .waiting
            case .user?:              phase = .thinking
            case nil:                 continue
            }
            if phase != .waiting && age > Self.fallbackActiveWindow { continue }   // 没有 pid，只能拿新鲜度猜死活
            let project = entry.tail.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
            if let c = entry.tail.cwd { cwds.insert(c) }
            liveIds.insert(sid)
            rows.append((SessionState(
                id: sid, pid: 0,
                project: project, name: nil, nameIsUserSet: false,
                kind: "interactive", branch: entry.tail.branch, phase: phase, tool: tool,
                idleSeconds: max(0, Int(age)),
                contextPct: ctxCache[sid]), entry.mtime))
        }
        rows.sort { $0.1 > $1.1 }
        state.sessions = rows.prefix(6).map { $0.0 }    // 最活跃的前 6 个，旧实现同款上限
        return (liveIds, Array(cwds))
    }

    /// 回退模式的新鲜度窗口（决策 007 之前的原值）：非 waiting 超 90s 没写入判死；waiting 最长展示 30 分钟
    private static let fallbackActiveWindow: TimeInterval = 90
    private static let fallbackWaitingWindow: TimeInterval = 30 * 60

    /// 事件/对账驱动的缓存刷新：只有该会话的 jsonl 真变更才重读（project 传 nil = 从 jsonl 的 cwd 字段推）
    private func refreshTranscript(id: String, url: URL, project: String?, heal: Bool,
                                   dirty: Set<String>) -> CachedTranscript? {
        var cached = tailCache[id]
        var needParse = cached == nil || cached!.url != url || dirty.contains(id)
        if !needParse, heal, let c = cached {   // 对账：mtime 变了才真的重读
            let m = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            needParse = m != c.mtime
        }
        if needParse {
            cached = parseTranscript(url, project: project)
            tailCache[id] = cached
            ctxCache[id] = readContextPct(id)   // ctx 跟会话活跃度同步变，搭车刷新
        } else if heal {
            ctxCache[id] = readContextPct(id)
        }
        return cached
    }

    /// 本会话的上下文占用（ld-statusline 按会话记录；只在会话活跃时变化，活跃时恰好会刷新，不会过期）
    private func readContextPct(_ sessionId: String) -> Double? {
        guard let d = try? Data(contentsOf: ctxDir.appendingPathComponent(sessionId + ".json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["usedPercentage"] as? Double
    }

    // MARK: - 注册表

    /// 只读不判活：判活（kill(pid,0)，进程死了不会有文件事件）由 probe() 每拍对缓存做
    private func readRegistry() -> [Registered] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [Registered] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value,
                  let sid = o["sessionId"] as? String,
                  let cwd = o["cwd"] as? String else { continue }
            let statusAt = (o["statusUpdatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            out.append(Registered(pid: pid, sessionId: sid, cwd: cwd,
                                  status: o["status"] as? String ?? "",
                                  statusUpdatedAt: statusAt,
                                  name: o["name"] as? String, nameSource: o["nameSource"] as? String,
                                  kind: o["kind"] as? String ?? "interactive",
                                  jobId: o["jobId"] as? String, parkedJobId: o["parkedJobId"] as? String))
        }
        return out
    }

    /// 会话的 jsonl：~/.claude/projects/<slug(cwd)>/<sessionId>.jsonl；slug 规则对不上时全目录搜一次并缓存
    private func transcriptURL(for reg: Registered) -> URL? {
        let fm = FileManager.default
        if let u = transcriptCache[reg.sessionId], fm.fileExists(atPath: u.path) { return u }
        let guess = projectsDir.appendingPathComponent(Self.slug(reg.cwd)).appendingPathComponent(reg.sessionId + ".jsonl")
        if fm.fileExists(atPath: guess.path) { transcriptCache[reg.sessionId] = guess; return guess }
        guard let dirs = try? fm.contentsOfDirectory(at: projectsDir, includingPropertiesForKeys: nil) else { return nil }
        for d in dirs {
            let c = d.appendingPathComponent(reg.sessionId + ".jsonl")
            if fm.fileExists(atPath: c.path) { transcriptCache[reg.sessionId] = c; return c }
        }
        return nil
    }

    /// Claude Code 的项目目录名：路径里非字母数字的字符全部换成 -
    static func slug(_ path: String) -> String {
        String(path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
    }

    // MARK: - jsonl 尾部

    private struct Tail {
        enum Last { case assistantText, toolUse(String), user }
        var last: Last?
        var branch: String?
        var cwd: String?      // 回退模式用它推项目名（注册表模式用 reg.cwd，不受会话内 cd 影响）
    }

    /// 一次真实工具调用，缓存用绝对时间（ago 是相对量，组装时再算）
    private struct ToolHit {
        var tool: String
        var project: String
        var date: Date
    }

    /// 一个会话 jsonl 的解析结果缓存：文件不变就不再碰磁盘
    private struct CachedTranscript {
        var url: URL
        var mtime: Date
        var tail: Tail
        var tools: [ToolHit]
    }

    /// 只读文件尾部，避免大会话（本机实测有 14000+ 行）被整体载入
    private func parseTranscript(_ url: URL, project: String?) -> CachedTranscript {
        let now = Date()
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? now
        var entry = CachedTranscript(url: url, mtime: mtime, tail: Tail(), tools: [])
        parse(url, project: project ?? "?", now: now, into: &entry)
        if project == nil, let cwd = entry.tail.cwd {   // 回退模式：项目名解析完才知道，回填工具流
            let p = URL(fileURLWithPath: cwd).lastPathComponent
            for i in entry.tools.indices { entry.tools[i].project = p }
        }
        return entry
    }

    private func parse(_ url: URL, project: String, now: Date, into entry: inout CachedTranscript) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd() else { return }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0 && !lines.isEmpty { lines.removeFirst() }  // 首行可能被截断

        var collected = 0
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for line in lines.reversed() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            if entry.tail.branch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { entry.tail.branch = b }
            if entry.tail.cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty { entry.tail.cwd = c }

            let type = obj["type"] as? String ?? ""
            guard type == "assistant" || type == "user" else { continue }
            // 顺路收集真实的工具调用流（含 sidechain，subagent 的活动也是活动）
            if type == "assistant", collected < 14,
               let m = obj["message"] as? [String: Any],
               let blocks = m["content"] as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "tool_use" {
                    guard let name = b["name"] as? String else { continue }
                    let date = (obj["timestamp"] as? String).flatMap { iso.date(from: $0) } ?? now
                    entry.tools.append(ToolHit(tool: name, project: project, date: date))
                    collected += 1
                }
            }
            // 侧链（subagent）事件不代表主会话"最后一条是谁说的"
            if obj["isSidechain"] as? Bool == true { continue }
            if entry.tail.last == nil, let msg = obj["message"] as? [String: Any] {
                let blocks: [[String: Any]]
                if let arr = msg["content"] as? [[String: Any]] { blocks = arr }
                else if msg["content"] is String { blocks = [["type": "text"]] }
                else { continue }
                let kinds = blocks.compactMap { $0["type"] as? String }
                if type == "assistant" {
                    if let tu = blocks.first(where: { $0["type"] as? String == "tool_use" }),
                       let name = tu["name"] as? String { entry.tail.last = .toolUse(name) }
                    else if kinds.contains("text") { entry.tail.last = .assistantText }
                    else { continue }   // 纯 thinking 块等，继续往前找
                } else {
                    entry.tail.last = .user   // 你的输入或工具结果回灌，两者都意味着 Claude 要开始想了
                }
            }
            if collected >= 14, entry.tail.last != nil { break }
        }
    }
}

/// 极简 FSEvents 封装：文件级事件、0.3s 合并、回调投主队列；创建失败返回 nil（调用方自行回退轮询）
final class FSWatcher {
    private let onChange: ([String]) -> Void
    private var stream: FSEventStreamRef?

    init?(paths: [String], onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            if let arr = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] {
                me.onChange(arr)
            }
        }
        guard let s = FSEventStreamCreate(
            nil, cb, &ctx, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                   | kFSEventStreamCreateFlagUseCFTypes
                                   | kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        FSEventStreamSetDispatchQueue(s, .main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return nil
        }
        stream = s
    }

    deinit {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }
    }
}
