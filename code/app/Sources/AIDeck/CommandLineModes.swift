import Foundation

/// 不启动 UI 的命令行模式。必须在 NSApplication 建起来之前跑完（命中即 exit），所以由 main.swift 顶层第一个调用。
enum CommandLineModes {
    static func runIfRequested() {
        let args = CommandLine.arguments

        // 接入 / 卸载 / 查看额度数据源（./ld quota on|off|status）
        if let i = args.firstIndex(of: "--quota") {
            exit(QuotaInstaller.run(Array(args[(i + 1)...])))
        }

        // 接入 / 卸载 / 查看 Notification hook 精细态数据源（./ld hooks on|off|status）
        if let i = args.firstIndex(of: "--hooks") {
            exit(HooksInstaller.run(Array(args[(i + 1)...])))
        }

        // 开机自启（./ld autostart on|off）。plist 只由 Autostart 一处生成，与设置页的开关同一份内容
        if let i = args.firstIndex(of: "--autostart") {
            let arg = i + 1 < args.count ? args[i + 1] : "status"
            do {
                switch arg {
                case "on":  try Autostart.enable();  print("已写入 \(Autostart.plistURL.path)")
                case "off": try Autostart.disable(); print("已取消开机自启")
                default:    print(Autostart.isEnabled ? "已开启：\(Autostart.plistURL.path)" : "未开启")
                }
                exit(0)
            } catch {
                FileHandle.standardError.write("失败：\(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }

        // bundle id 去掉 .spike 后的一次性迁移（在一切 UserDefaults 读取之前；AppDelegate 的属性初始化就在读）
        Prefs.migrateFromSpikeDomain()
        Autostart.migrateFromSpikeLabel()

        // 探测一次并打印 JSON。配 CLAUDE_CONFIG_DIR 可指向沙箱目录，测注册表缺失的回退路径
        if args.contains("--probe-once") {
            var st = ClaudeStateProbe().probe()
            // 系统资源采两拍（隔 1s）：CPU / 磁盘吞吐是差分量，单拍只有 null
            let sys = SystemProbe(); sys.sample(&st); Thread.sleep(forTimeInterval: 1); sys.sample(&st)
            let obj = st.jsonObject
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                FileHandle.standardError.write("状态序列化失败：某个数值字段是 NaN / Inf（键：\(obj.keys.sorted().joined(separator: ",")))\n".data(using: .utf8)!)
                exit(1)
            }
            print(text)
            exit(0)
        }
    }
}
