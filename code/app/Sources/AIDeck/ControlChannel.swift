import Foundation

/// 外部控制的一条命令。菜单栏在刘海屏上可能被挤掉，命令行必须能全权控制（`./ld`），所以这里是与菜单 / 设置页并列的第三个入口
enum ControlCommand: Equatable {
    enum Hud: Equatable {
        case visible(Bool), edit, clickThrough(Bool), float(Bool), autoFloat(Bool), anchor(String)
    }
    case hud(Hud)
    case celebrate, nextSkin, togglePause, settings, quit
    case widget(id: String, slot: String)
    case reaction(id: String, on: Bool)
    case model(String)
    case skinSet(id: String, value: SkinValue)
    case skinReset

    /// 命令行给的皮肤设置值（Prefs.parseSkinValue 的结果），包一层以便 Equatable、可测
    enum SkinValue: Equatable {
        case bool(Bool), number(Double), text(String)
        init(_ raw: String) {
            switch Prefs.parseSkinValue(raw) {
            case let b as Bool:   self = .bool(b)
            case let d as Double: self = .number(d)
            default:              self = .text(raw)
            }
        }
        var any: Any {
            switch self { case .bool(let b): return b; case .number(let d): return d; case .text(let s): return s }
        }
    }

    /// 解析一行 `./ld` 写入的命令（纯函数）。认不出的返回 nil；参数是否合法（槽位、模型名）由执行方的 Prefs 校验
    static func parse(_ line: String) -> ControlCommand? {
        let parts = line.split(separator: " ").map(String.init)
        guard let head = parts.first else { return nil }
        let rest = parts.dropFirst().joined(separator: " ")   // 模型文件名 / 皮肤取值可含空格
        switch head {
        case "hud":
            let arg = parts.count > 1 ? parts[1] : "br"
            switch arg {
            case "on":      return .hud(.visible(true))
            case "off":     return .hud(.visible(false))
            case "edit":    return .hud(.edit)
            case "through": return .hud(.clickThrough(true))
            case "drag":    return .hud(.clickThrough(false))
            case "float":   return .hud(.float(true))
            case "desktop": return .hud(.float(false))
            case "auto":    return parts.count > 2 ? .hud(.autoFloat(parts[2] == "on")) : nil
            default:        return .hud(.anchor(arg))
            }
        case "celebrate": return .celebrate
        case "next":      return .nextSkin
        case "pause":     return .togglePause
        case "settings":  return .settings
        case "widget":    return parts.count > 2 ? .widget(id: parts[1], slot: parts[2]) : nil
        case "fx":        return parts.count > 2 ? .reaction(id: parts[1], on: parts[2] == "on") : nil
        case "model":     return rest.isEmpty ? nil : .model(rest)
        case "skin":
            if parts.count == 2, parts[1] == "reset" { return .skinReset }
            guard parts.count > 2 else { return nil }
            return .skinSet(id: parts[1], value: SkinValue(parts.dropFirst(2).joined(separator: " ")))
        default: return nil
        }
    }
}

/// 两路外部输入统一成 ControlCommand 交给宿主执行：
///   · `./ld` 命令队列目录（宿主每拍 drainQueue）
///   · 信号：SIGUSR1 暂停 / 恢复（自动化测量用），SIGUSR2 换下一个皮肤，SIGTERM 温和退出
final class ControlChannel {
    /// 命令队列目录：`./ld` 每条命令先写临时文件（点开头）再 mv 成 `*.cmd`，mv 原子，这里看到的永远是完整文件。
    /// 以前是往 ~/.live-desktop.cmd 追加、这边「读 → 删」，两步之间追加的那行会被一起删掉、命令静默丢失
    static let cmdDir = QuotaProbe.dir.appendingPathComponent("cmd", isDirectory: true)

    private let handler: (ControlCommand) -> Void
    private var signalSources: [DispatchSourceSignal] = []

    init(handler: @escaping (ControlCommand) -> Void) { self.handler = handler }

    func start() {
        try? FileManager.default.createDirectory(at: Self.cmdDir, withIntermediateDirectories: true)
        // SIGTERM（./ld stop 的 pkill 默认信号）走温和退出：exit 0，launchd 的「异常才拉起」不会缠着重启
        for (sig, cmd) in [(SIGUSR1, ControlCommand.togglePause), (SIGUSR2, .nextSkin), (SIGTERM, .quit)] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.handler(cmd) }
            src.resume()
            signalSources.append(src)
        }
    }

    /// 取走并执行队列里的全部命令
    func drainQueue() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.cmdDir.path) else { return }
        // 文件名是 `./ld` 写入时的定宽微秒时间戳，字典序即先后序
        for name in names.sorted() where name.hasSuffix(".cmd") && !name.hasPrefix(".") {
            let path = Self.cmdDir.appendingPathComponent(name).path
            let txt = try? String(contentsOfFile: path, encoding: .utf8)
            try? fm.removeItem(atPath: path)
            for line in (txt ?? "").split(separator: "\n") {
                if let cmd = ControlCommand.parse(String(line)) { handler(cmd) }
                else { FileHandle.standardError.write("[cmd] 认不出的命令：\(line)\n".data(using: .utf8)!) }
            }
        }
    }
}
