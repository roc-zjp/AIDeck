# AIDeck

**让 macOS 桌面变成 Claude Code 的状态感知层。** 不切回终端，也知道哪个会话在跑、哪个在等你、额度还剩多少。

![JARVIS](docs/posts/media/jarvis.gif)

## 为什么做这个

用 Claude Code 的时候经常是这样：派个活出去，切到别的窗口，过一会儿回来，发现它十分钟前就停下来等你回话了。

把自己十四天的会话记录统计了一遍：

- 585 次「它说完了 → 我回来看见」
- 中位数 103 秒，**P90 二十三分钟**
- 光是超过一分钟的等待，累计 **88 小时**

这段时间里 AI 在等你，你在别的窗口，而桌面被窗口盖得严严实实，一个像素也没派上用场。

AIDeck 就是让那块桌面干点活。

## 一条规矩

**屏幕上每个数字都必须绑真实数据源，宁可留空，不许造假。**

滚几行假 log、画几个跳动的百分比很容易，但那样它就只是一张花哨壁纸。所以这里读不到的指标整行不画（比如 GPU 读不到 IORegistry），没有额度数据就整块面板消失，不补零也不估算。

数据来源全部只读：

- `~/.claude/sessions/*.json` — Claude Code 自己的会话注册表，给出 pid、忙闲位、会话名
- `~/.claude/projects/**/*.jsonl` — 会话记录，给出最后一条消息与工具调用流

不碰凭证，不与 Claude Code 争夺任何生命周期。唯一会写入的地方是你**显式执行** `./ld quota on` 之后，往 `~/.claude/settings.json` 的 `statusLine` 装一个透传 wrapper（改前整份备份，`off` 一键恢复）。除此之外一个字节都不动。

## 三层感知

桌面在你专注工作时是看不见的，而最该提醒你的那一刻，恰恰是桌面最看不见的时候。所以感知分三层：

| 层 | 做什么 |
|---|---|
| 桌面主题 | 沉浸感知。回到桌面一眼全局 |
| 菜单栏 + 状态卡 | 常驻感知。状态卡在有会话等你时自动浮到所有窗口之上，回复完自己缩回去 |
| 系统通知 | 长尾兜底。每次等待只发一次，额度跨 80% / 95% 各一次 |

## 12 款主题

四个状态色贯穿所有主题：空闲深蓝青、思考中紫粉、执行工具青绿、**等你输入琥珀橙**。琥珀是唯一需要你「该我了」的颜色。

| | |
|---|---|
| **JARVIS** 反应堆环 + 信息面板，主形态 | **Radar** 会话是回波点，离心距离 = 多久没输出 |
| **Matrix** 雨里三成是真实工具名 / 分支名 | **Globe** 每个会话一条绕球轨道 |
| **Circuit** 电子沿走线流动，工具调用炸出白热电子 | **Warp** 星场航速随状态，切换即跃迁 |
| **Hologram** 3D 投影台，可换成你自己的模型 | **Basketball** 数字人练干拔，commit 时庆祝 |
| **Bounce** 每次工具调用多一颗零重力弹球 | **Aurora / Neural / Pulse** 纯氛围，Pulse 最省电 |

<details>
<summary>展开看动图（12 款）</summary>

Radar

![Radar](docs/posts/media/radar.gif)

Basketball — 普通跳投 = 一个回合完成，庆祝动作 = 一次 git commit，记分牌上的 SCORE 是本次运行的真实 commit 数

![Basketball](docs/posts/media/basketball.gif)

Matrix

![Matrix](docs/posts/media/matrix.gif)

Hologram

![Hologram](docs/posts/media/hologram.gif)

Globe

![Globe](docs/posts/media/globe.gif)

Circuit

![Circuit](docs/posts/media/circuit.gif)

Warp

![Warp](docs/posts/media/warp.gif)

Bounce

![Bounce](docs/posts/media/bounce.gif)

Aurora

![Aurora](docs/posts/media/aurora.gif)

Neural

![Neural](docs/posts/media/neural.gif)

Pulse

![Pulse](docs/posts/media/pulse.gif)

</details>

> 动图录自演示沙箱，画面里的会话名、项目名、分支名都是演示数据。

## 功耗

被窗口盖住时 WebKit 会停掉 `requestAnimationFrame`，这之上还加了一道几何覆盖率兜底。实测：桌面露出满帧 60fps，被盖住 0fps，屏保 / 息屏 / 锁屏期间 0fps，解锁即回 60fps。连续 76 小时的运行数据里，动画实际在渲染的时间占 **4.9%**。

## 安装

需要 macOS 与 Xcode 命令行工具（Swift 6+），没有 Xcode 工程，纯 SPM：

```bash
git clone <repo> && cd live-desktop/code/spike
./build.sh          # 编译 + 组 .app + ad-hoc 签名
./ld start
```

`./package.sh` 可以打出 universal DMG。**目前只有 ad-hoc 签名**，首次打开需要在「系统设置 → 隐私与安全性」里放行。

## 常用命令

```bash
./ld start | stop | status | next     # 启停、切主题
./ld settings                         # 设置窗口（左侧是真实渲染的实时预览）
./ld quota on | off | status          # 额度数据源接入 / 恢复（会改 statusLine 一键，改前备份）
./ld hooks on | off                   # 精细态：卡在确认框 / MCP 表单时显示「等你确认」
./ld widget <id> <slot>               # 小工具槽位（3×3 九宫格）
./ld skin <id> <值>                   # 当前主题自己声明的设置项
./ld autostart on                     # 开机自启 + 崩溃保活
./ld report                           # 自用验证报告
```

菜单栏在刘海屏上可能被系统挤掉，**右键状态卡**是永远可用的设置入口。

## 自己写一款主题

一款主题就是一个自包含的 HTML，丢进 `~/.config/live-desktop/skins/` 即可（设置页能一键从模板新建）。

宿主给页面的只有三个方法：`setState` 推每秒一拍的真实状态，`setConfig` 推用户偏好，`setRunning` 是渲染闸门。页面回报宿主的只有 `ready` / `fps` / `prefs` / `hudSize`。

主题还能**自己声明设置项**——加载时调一次 `__ld.declarePrefs([...])`，宿主就按 schema 渲染出复选框、滑杆、下拉框，值按主题名分开保存并推回页面：

```js
__ld.declarePrefs([
  { id: 'gravity',  name: '重力',     type: 'bool',   default: false },
  { id: 'maxBalls', name: '球数上限', type: 'number', default: 12, min: 1, max: 30 },
  { id: 'avatar',   name: '数字人',   type: 'model',  default: 'station' },
]);
```

这条边界守得比较死：**宿主永远不为某一款主题写一行 Swift**。一旦开了口子，宿主里就会长出 `if skin == "basketball"`，然后再也拆不干净。

安装时会在皮肤目录生成一份契约 README，写法参考内置的 `pulse.html`（最短的那个模板）。

## 项目状态

**这仍是个自用验证中的工具，不是成熟产品。**

技术上跑通了：12 款主题、三层感知、零侵入状态引擎、额度接入、开机自启、崩溃自愈。差的是正式签名与公证（需要 Developer ID），所以还没有开箱即用的分发包。

作者给自己定了条判据写在 spec 里：如果「等你输入」的平均持续时长随使用天数没有明显下降，说明这东西是个好看的摆设，**判据不达标就砍**。

## 文档

| 找什么 | 看哪里 |
|---|---|
| 产品定义、里程碑、验证判据 | [`docs/spec.md`](docs/spec.md) |
| 踩过的坑（多数是静默失败型） | [`docs/issues.md`](docs/issues.md) |
| 已拍板的产品决策（12 条） | [`docs/decisions/`](docs/decisions/) |
| 技术栈、文件职责、命令 | [`CLAUDE.md`](CLAUDE.md) |
| 完整介绍文章 | [`docs/posts/vibe-coding-which-vibe.md`](docs/posts/vibe-coding-which-vibe.md) |

## License

MIT，见 [LICENSE](LICENSE)。

随仓库分发的 Three.js 与 Draco 解码器按其各自的许可证提供，见 [`code/spike/Resources/web/THIRD-PARTY.md`](code/spike/Resources/web/THIRD-PARTY.md)。
