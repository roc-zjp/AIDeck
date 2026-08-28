import Foundation

/// 活跃项目的 git 状态：分支 + 未提交文件数（含未跟踪）。
/// 后台队列刷新、10 秒缓存，tick 只读缓存——不能让慢仓库或大仓库卡住每秒主循环。
final class GitProbe {
    struct Repo { var branch: String; var dirty: Int; var head: String; var committedAt: Double }   // committedAt = 检测到新 commit 的墙钟时刻（0=无）

    private var cache: [String: (repo: Repo?, at: Date)] = [:]
    private var lastHead: [String: String] = [:]      // 每个仓库上次探到的 HEAD sha
    private var commitAt: [String: Double] = [:]      // 每个仓库最近一次 HEAD 变化的时刻
    private var refreshing: Set<String> = []
    private let queue = DispatchQueue(label: "com.zhoujunpeng.livedesktop.gitprobe", qos: .utility)
    private let lock = NSLock()

    /// 返回已有缓存，过期的目录丢到后台刷新（下一拍拿到新值）
    func snapshot(_ cwds: [String]) -> [String: Repo] {
        var out: [String: Repo] = [:]
        let now = Date()
        for cwd in Set(cwds) {
            lock.lock()
            let entry = cache[cwd]
            let needs = (entry == nil || now.timeIntervalSince(entry!.at) > 10) && !refreshing.contains(cwd)
            if needs { refreshing.insert(cwd) }
            if let r = entry?.repo { out[cwd] = r }
            lock.unlock()
            if needs { queue.async { [weak self] in self?.refresh(cwd) } }
        }
        return out
    }

    private func refresh(_ cwd: String) {
        var repo: Repo?
        if let branch = run(["symbolic-ref", "--short", "HEAD"], cwd: cwd) ?? run(["rev-parse", "--short", "HEAD"], cwd: cwd) {
            let dirty = run(["status", "--porcelain"], cwd: cwd)
                .map { $0.isEmpty ? 0 : $0.split(separator: "\n").count } ?? 0
            let head = run(["rev-parse", "HEAD"], cwd: cwd) ?? ""
            lock.lock()
            // HEAD 变了且非首次观测 = 一次新 commit（含 amend / squash，都算一次"落库"）
            if let prev = lastHead[cwd], !head.isEmpty, head != prev { commitAt[cwd] = Date().timeIntervalSince1970 }
            if !head.isEmpty { lastHead[cwd] = head }
            let ca = commitAt[cwd] ?? 0
            lock.unlock()
            repo = Repo(branch: branch, dirty: dirty, head: String(head.prefix(7)), committedAt: ca)
        }
        lock.lock()
        cache[cwd] = (repo, Date())
        refreshing.remove(cwd)
        lock.unlock()
    }

    private func run(_ args: [String], cwd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", cwd, "--no-optional-locks"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) && args.first == "symbolic-ref" ? nil : s
    }
}
