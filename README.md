# AIDeck

常驻 macOS 的 **AI agent 桌面**（首个接入的 agent 是 Claude Code）：桌面是贾维斯式全息工作台，菜单栏是常驻哨兵，通知是长尾兜底。
不切回终端也知道哪个会话在跑、哪个在等你、额度还剩多少。

> 产品名 **AIDeck**（定位：AI agent 桌面）｜ JARVIS 仅作全息主形态内部代号｜ 阶段：自用验证中

- **接手先读 [`HANDOFF.md`](HANDOFF.md)**，再读 [`docs/spec.md`](docs/spec.md)
- 动手前必读 [`docs/issues.md`](docs/issues.md)（5 条静默失败型的坑）

## 快速开始

```bash
cd code/spike && ./build.sh && ./ld start
./ld report     # 自用验证报告
```

## 设计原则

**屏幕上每个数字都必须是真的。** 贾维斯风格最大的诱惑是堆装饰性假数据，那样就退化成花哨壁纸。
ACTIVITY LOG 滚的是从会话记录提取的真实工具调用流，宁可留空，不许造假。
