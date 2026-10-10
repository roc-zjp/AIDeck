import Foundation

/// 皮肤自声明设置项的 schema 登记（决策 006）。schema 来自页面运行时上报（桌面窗口或设置预览都可能先报），按皮肤名登记。
/// 只认 type，不认识任何皮肤名——别人写的皮肤同样适用
final class SkinSchemaRegistry {
    private var schemas: [String: [[String: Any]]] = [:]

    /// 登记一份 schema。返回 true = 顺手给模型参数填了初值，调用方要把偏好重新推给页面。
    /// 3D 模型 2026-09-18 起是每个皮肤自己的参数；老用户选过的全局模型不能丢：
    /// 某皮肤第一次报出 model 类型的设置项、而它还没存过值时，用旧的全局值填进去（Prefs.legacyGlobalModel）
    @discardableResult
    func register(_ skin: String, _ schema: [[String: Any]]) -> Bool {
        schemas[skin] = schema
        let saved = Prefs.skinValues(skin)
        var seeded = false
        for p in schema where (p["type"] as? String) == "model" {
            guard let id = p["id"] as? String, saved[id] == nil else { continue }
            Prefs.setSkinValue(skin, id: id, value: Prefs.legacyGlobalModel)
            seeded = true
        }
        return seeded
    }

    func schema(for skin: String) -> [[String: Any]] { schemas[skin] ?? [] }

    /// 该皮肤声明的 model 类型设置项 id（`./ld model` 要知道该写哪个键）；nil = 这款皮肤不用模型，或 schema 还没报上来
    func modelPrefID(for skin: String) -> String? {
        schemas[skin]?.first { ($0["type"] as? String) == "model" }?["id"] as? String
    }
}
