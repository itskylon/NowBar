# NowBar

应用统一使用英文品牌名 **NowBar**，中文和英文界面保持相同拼写。名称呼应菜单栏中随时查看当前 AI 额度与用量，沿用文案“AI 用量，抬眼可见。”。

新版图标采用白色几何 N、右上薄荷绿状态段和深石墨色圆角底。N 对应 NowBar，两根竖笔画呼应菜单栏与用量条；粗笔画与留白优先保证小尺寸辨识。外缘透明，图像尺寸为 1254×1254。

## 交付

- 原始图标：[`resources/branding/nowbar.png`](../resources/branding/nowbar.png)，1254×1254，RGBA。
- `scripts/build-icon.sh` 使用 macOS 自带 sips / iconutil，生成 16–1024px 共十个尺寸并封装 ICNS；`scripts/build.sh` 自动执行并拷入 `dist/NowBar.app`。
- 名称应用于应用包、窗口标题、设置、侧栏、面板标题和无障碍名称。菜单栏的提供商图形与额度文字继续表示当前固定的账户窗口。
- 为读取原有设置、接入和缓存，bundle ID、可执行文件名、通知内部标识、偏好键和 Application Support/AgentMeter 路径保留原值。这些是兼容性标识，不是对外名称。

## 生成方式

使用内置 `image_gen` 生成全新图标，随后用现有 macOS 图标构建流程缩放并打包。完整提示词保存于 [nowbar-prompt.txt](../resources/branding/nowbar-prompt.txt)。

已检查 16px、32px 输出与真实深色侧栏：N 主体清晰，32px 及侧栏可辨薄荷绿状态段；16px 下绿色细节减弱，不影响 N 的识别。未在本轮验证浅色、Dock 或启动台缓存显示。
