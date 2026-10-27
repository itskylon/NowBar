<p align="center">
  <img src="resources/branding/nowbar.png" width="112" alt="NowBar logo">
</p>

# NowBar

**AI 用量，抬眼可见。**

A native macOS menu bar app for AI quotas, token usage, and estimated costs.

NowBar 把 Codex、Claude Code 和 Grok Bot 的额度状态放进 Mac 菜单栏，并从本机日志整理 Token、模型明细与参考费用。轻点即可知道还剩多少额度、何时重置，以及今天的 AI 开发用量。

## 项目背景

同时使用多个 AI 编程工具时，查看额度通常需要反复打开各家的设置页；本机 Token、模型用量和项目开销又分散在不同日志里。NowBar 希望把这些信息集中起来，让查看用量成为一个随手就能完成的动作。

## 功能介绍

- **菜单栏额度**：固定最多两项额度，查看已用、剩余百分比与重置时间；支持手动刷新和自动刷新。
- **今日用量**：展示总 Token、输入、输出、缓存读取、缓存写入和推理明细，按模型查看参考费用。
- **用量与支出**：支持 7 天、30 天、90 天、本月至今及全部历史；可选择统计时区，按提供商、项目、独立聊天或会话查看排行与模型明细。
- **历史趋势**：查看最近七天 Token / 费用趋势，以及完整历史的费用柱状图与期间明细。
- **额度提醒**：可选剩余 20%、10%、耗尽与额度重置通知，默认关闭。
- **原生体验**：额度、历史与设置使用统一的可调整大小窗口；深浅色跟随系统，中英文可切换，语言默认跟随系统；支持可选登录时启动。

未知数据、真实零值、读取失败与过期数据会分别显示。应用不会用示例数据填充真实用量，也不会把未知费用当作免费用量。

## 支持情况

| 服务 | 账户额度 | 本机 Token 与模型明细 | 参考费用与历史 |
| --- | --- | --- | --- |
| Codex | 支持，通过已登录的 Codex CLI 读取 | 支持 | 支持 |
| Claude Code | 支持，需接入 Claude Code 状态栏 | 支持，读取本机会话日志 | 支持 |
| Grok Bot | 支持，复用本机桌面应用的活动登录 | 暂不支持 | 暂不支持 |

Meta Muse 目前尚未接入。Grok Bot 的适配依赖官方桌面客户端所用接口，接口变化可能影响读取。

**账户额度与本机日志是两种数据来源。** 本机用量只覆盖这台 Mac 已保存的日志，不代表其他设备或整个订阅账户；参考费用根据支持模型的 API 单价估算，不是订阅账单或实际扣费。未知模型与不支持的计价条件会标记为未计价。

## 构建与运行

需要 macOS 14 或更新版本、Xcode Command Line Tools（Swift）以及 Python 3。应用本身没有第三方 Swift 库依赖；构建脚本使用 macOS 自带的图标工具。

```sh
git clone https://github.com/itskylon/NowBar.git
cd NowBar
bash scripts/build.sh
open dist/NowBar.app
```

构建脚本按当前 Mac 架构生成应用，产物位于 `dist/NowBar.app`。当前使用本机 ad hoc 签名，尚未提供 Developer ID 签名、公证或自动更新。

运行回归检查：

```sh
bash scripts/test.sh
```

项目同时保留 `Package.swift` 与 XCTest 用例；脚本还包含本机日志解析、去重、计价、桥接配置及界面状态的检查。

## 数据接入与使用

1. **Codex**：安装并登录官方 Codex CLI，NowBar 自动读取账户额度与 `CODEX_HOME`（默认 `~/.codex`）中的会话日志。
2. **Claude Code**：本机 Token 从 `~/.claude/projects/` 读取。在设置的「服务接入」中启用 Claude 额度桥接，然后新开 Claude Code 会话，在收到响应后更新额度。接入会备份原配置并保留原状态栏命令，可在设置中移除。
3. **Grok Bot**：先登录本机 Grok Bot 桌面应用，NowBar 读取活动账户的每周额度。系统可能提示授权读取钥匙串；应用不修改登录或凭据。

点击菜单栏图标打开面板；图表按钮进入「用量与支出」，设置中可调整服务、刷新频率、语言与提醒。额度条旁的眼睛按钮可选择菜单栏常显项目。

全历史首次扫描可能需要时间，页面会显示读取进度。自动模式下约每 5 秒检查新增本机日志，账户额度按设置的刷新周期读取。统计只会在日志写入实际用量后更新。

演示模式使用隔离的示例数据：

```sh
dist/NowBar.app/Contents/MacOS/AgentMeter --demo
```

`AgentMeter` 是保留的内部可执行文件名。为兼容已有设置和缓存，内部模块名、bundle ID 与数据目录也保留原值；应用对外名称统一为 NowBar。

## 隐私

- 没有 NowBar 服务端，不上传本机用量历史，不调用模型生成内容。
- 账户额度使用已登录客户端或本机状态栏快照读取；必要网络请求发往对应服务的用量接口。
- 日志解析用于提取用量与会话元数据，不保存对话正文；项目路径仅用于本机统计分组。
- 设置、用量缓存及 Claude 接入备份保存在本机。数据目录为 `~/Library/Application Support/AgentMeter/`；原配置备份可能包含已有敏感字段，仅保留在本机并限制文件权限。
- 通知与登录时启动默认关闭，启用后才请求相应系统能力。

## 项目结构

```text
Sources/AgentMeter/       菜单栏、设置、额度与历史界面
Sources/AgentMeterCore/   数据接入、日志解析、计价、偏好与本地化
Tests/                   回归检查与测试用例
resources/               应用配置、图标、本地化与 Claude 桥接脚本
scripts/                 构建、图标生成与测试入口
docs/BRANDING.md         品牌与图标说明
```

## 致谢与资源来源

- [Nowdex](https://nowdex.app/zh-hans/)：界面布局参考；`resources/providers/` 的 [Codex](https://nowdex.app/providers/codex.svg)、[Claude](https://nowdex.app/providers/claude.svg)、[Grok](https://nowdex.app/providers/grok.svg) 服务标识以及 `resources/interface/` 图标来自其网站。
- [CodexBar](https://github.com/steipete/CodexBar)：菜单栏额度工具与设置体验参考。
- [Claude Code 状态栏文档](https://code.claude.com/docs/en/statusline)：Claude 额度桥接方式。

NowBar 自身图标与品牌说明见 [品牌文档](docs/BRANDING.md)。相关服务名称与标识归各自权利人所有。
