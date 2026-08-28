import Foundation
import WebKit

/// `ld-model://` scheme：把用户模型目录里的 .glb 供给皮肤页面。
///
/// 皮肤是 file:// 页面，读不到别的本地文件（WebKit 的 fetch 对 file: 一律拒绝，XHR 也只放行 allowingReadAccessTo 那一个目录）。
/// 自定义 scheme 走 `WKURLSchemeHandler`——公开 API；响应带 `Access-Control-Allow-Origin: *` 后，
/// file:// 页面对它的 fetch / XHR 都能成功（最小样例已验证，见 docs/decisions/008）。
///   ld-model://list          → JSON 数组：目录里的 *.glb / *.gltf / *.fbx 文件名
///   ld-model://file/<name>   → 模型文件字节（只认纯文件名，拒绝路径穿越；.gltf 的外挂 .bin / 贴图也从这里按相对名取）
///   ld-model://lib/<path>    → 内置 web 目录里的运行时资产（Draco 解码器 wasm 等；页面是 file://，fetch 不到自己目录里的文件）
final class ModelServer: NSObject, WKURLSchemeHandler {
    static let scheme = "ld-model"
    static let userModelsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/live-desktop/models", isDirectory: true)
    /// 内置程序化模型（与 ld-3d.js 的 builtin 表一致，顺序即设置页显示顺序）
    static let builtinModels: [(id: String, name: String)] = [
        ("reactor", "反应堆"), ("station", "空间站"), ("satellite", "卫星"), ("drone", "无人机"), ("helix", "双螺旋"),
    ]
    static let userPrefix = "user/"
    static let modelExts: Set<String> = ["glb", "gltf", "fbx"]
    private static let mime: [String: String] = [
        "glb": "model/gltf-binary", "gltf": "model/gltf+json", "fbx": "application/octet-stream", "bin": "application/octet-stream",
        "wasm": "application/wasm", "js": "text/javascript", "json": "application/json",
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp",
    ]
    private static func mimeType(_ path: String) -> String { mime[(path as NSString).pathExtension.lowercased()] ?? "application/octet-stream" }

    static var userModelFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: userModelsDir.path))?
            .filter { f in !f.hasPrefix(".") && Self.modelExts.contains((f as NSString).pathExtension.lowercased()) }.sorted() ?? []
    }
    /// 全部可选模型 id：内置名 + user/<文件名>
    static var availableModels: [String] { builtinModels.map { $0.id } + userModelFiles.map { userPrefix + $0 } }

    static func ensureUserModelsDir() {
        let fm = FileManager.default
        try? fm.createDirectory(at: userModelsDir, withIntermediateDirectories: true)
        let readme = userModelsDir.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            try? """
            # AIDeck 自定义 3D 模型

            把 `.glb` / `.gltf` / `.fbx` 放在这个目录，它就会出现在设置页「3D 模型」的列表里（名字前缀 `user/`），
            也可以 `./ld model user/<文件名>` 选中。hologram 皮肤会把它作为全息投影台上的主体。

            **带骨骼动画的角色会动**：动作片段按 Claude 状态挑（多段时按名字关键词：idle / wave / dance…，单段就一直放），
            播放速度随活跃度——待机慢放、执行工具全速。想要会跳舞的角色：去 mixamo.com 挑一个角色 + 一段动作，
            导出 **FBX Binary（With Skin）**，把文件直接放进来即可。Mixamo 资产是给你自己用的，不要随 AIDeck 一起分发。

            渲染是全息风格：单色、菲涅尔边缘光、扫描线、线框——材质与贴图会被忽略，只用几何与骨骼。
            模型会自动居中缩放、脚底落在投影台上，不用在建模软件里调尺寸。

            支持：glTF 2.0（含 Draco 压缩、外挂 .bin）、FBX（Three.js FBXLoader 支持的版本，Mixamo 导出的没问题）、蒙皮与关键帧动画。
            不支持：形变动画（morph targets 有但不驱动）、贴图（忽略）。
            体积建议 ≤ 30MB、三角形 ≤ 30 万；再大也能显示，只是费电。
            """.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    // 已停止的任务不能再喂数据（会抛 ObjC 异常），按对象身份记账
    private var live = Set<ObjectIdentifier>()

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        live.insert(ObjectIdentifier(task))
        let host = url.host ?? ""
        if host == "list" {
            let names = Self.userModelFiles
            let data = (try? JSONSerialization.data(withJSONObject: names)) ?? Data("[]".utf8)
            respond(task, url: url, data: data, type: "application/json")
            return
        }
        var name = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        if name.contains("%"), let d = name.removingPercentEncoding { name = d }
        let file: URL
        switch host {
        case "file":   // 用户模型目录里的单个文件
            guard !name.isEmpty, !name.contains("/"), name != "..", !name.hasPrefix(".") else {
                respond(task, url: url, data: Data("{\"error\":\"bad name\"}".utf8), type: "application/json", status: 400); return
            }
            file = Self.userModelsDir.appendingPathComponent(name)
        case "lib":    // 内置 web 目录（可带子目录，如 draco/draco_decoder.wasm），禁止 ..
            guard !name.isEmpty, !name.split(separator: "/").contains(".."), !name.hasPrefix("/") else {
                respond(task, url: url, data: Data("{\"error\":\"bad path\"}".utf8), type: "application/json", status: 400); return
            }
            file = AnimationHost.bundledWebDirectory.appendingPathComponent(name)
        default:
            respond(task, url: url, data: Data("{\"error\":\"not found\"}".utf8), type: "application/json", status: 404); return
        }
        let type = Self.mimeType(name)
        // 读文件放后台：GLB 可能几十 MB，不卡主线程；回主线程前确认任务还活着
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: file)
            DispatchQueue.main.async {
                guard let self, self.live.contains(ObjectIdentifier(task)) else { return }
                if let data { self.respond(task, url: url, data: data, type: type) }
                else { self.respond(task, url: url, data: Data("{\"error\":\"not found\"}".utf8), type: "application/json", status: 404) }
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, data: Data, type: String, status: Int = 200) {
        guard live.contains(ObjectIdentifier(task)) else { return }
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": type, "Content-Length": "\(data.count)",
                                                  "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
        live.remove(ObjectIdentifier(task))
    }
}
