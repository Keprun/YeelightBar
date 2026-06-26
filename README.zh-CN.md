# YeelightBar

[English](README.md) · [Русский](README.ru.md) · **中文** · [فارسی](README.fa.md) · [Español](README.es.md) · [العربية](README.ar.md)

一款用于控制 **Yeelight** 局域网设备的原生 macOS 应用 —— 专为 **Yeelight 螢幕挂灯 Pro**（`YLTD003`）打造，但同样能驱动普通的 RGB 灯带和灯泡。官方软件仅支持 Windows；本项目则是一个简洁、快速的 SwiftUI 替代方案，带有屏幕同步氛围光（ambilight）、音乐律动以及多灯组联动控制。

> 无云端、无账号。一切都在你的局域网内完成。

## 功能特性

- **完整控制** —— 开关、前置白光（亮度 + 色温）、氛围 RGB，以及预设场景。
- **灯组 / "混合" 控制** —— 选中多盏灯一起调控；每盏灯使用各自的协议方言（挂灯有独立的氛围 `bg` 通道，灯带则没有）。
- **屏幕同步氛围光** —— 由 ScreenCaptureKit 采样屏幕画面，并通过 UDP 会话以约 20 Hz 的频率将颜色推送到灯的氛围通道。
  - **按灯独立选择显示器 + 区域**：在多显示器环境下，每盏灯都可以采样*不同*的显示器以及其中*不同*的区域（顶部 / 底部 / 左侧 / 右侧 / 全屏）—— 例如让挂灯采样主屏幕的顶部，而桌下灯带采样另一块屏幕的底部。
  - 分辨率无关的采集（在 16:9、4K、竖屏以及 32:9 超宽屏上都同样适用）。
  - 实时预览：每块显示器都有一个屏幕形状的面板，以实时颜色精确呈现每盏灯所采样的区域。
- **音乐律动** —— 捕获*系统*音频（无需麦克风），用 IIR 滤波器将其拆分为低音 / 中音 / 高音。
  - **节拍（Beat）**模式随鼓点起伏调节亮度；**频谱（Spectrum）**模式将低音→红 / 中音→绿 / 高音→蓝。
- **两种界面** —— 用于快速调节的紧凑菜单栏面板，以及用于设置的可调整大小的完整窗口（`NavigationSplitView`）。
- **在真实网络中稳健可靠** —— 自动发现（SSDP + 主动子网扫描）、DHCP IP 变化后自动重连，以及串行化控制，确保灯在并发连接下绝不丢失任何指令。

## 系统要求

- macOS 13（Ventura）或更高版本，Apple Silicon 或 Intel。
- 已启用 **局域网控制（LAN Control）** 的 Yeelight 设备（Yeelight 应用 → 设备 → *LAN Control*）。
- **屏幕录制（Screen Recording）** 权限（系统设置 → 隐私与安全性），用于屏幕同步与音乐模式。

## 构建与运行

### Xcode
打开 `YeelightBar.xcodeproj` 并运行 **YeelightBar** scheme（⌘R）。该项目由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 从 `project.yml` 生成；修改规格文件后请运行 `xcodegen generate`。

### Swift Package Manager（无需 Xcode）
```sh
swift build
./scripts/bundle.sh          # 组装 + 签名生成 build/YeelightBar.app
open build/YeelightBar.app
```
`scripts/setup-signing.sh` 会创建一个稳定的自签名代码签名身份，使屏幕录制授权在重新构建后依然有效（临时（ad-hoc）签名每次构建都会变化，从而再次触发权限提示）。

## `yeectl` —— 命令行工具

一个用于测试和脚本化操作协议的小型 CLI：

```sh
swift run yeectl discover                 # SSDP
swift run yeectl auto                      # SSDP，失败时回退到主动子网扫描
swift run yeectl state   <ip>
swift run yeectl on|off  <ip>
swift run yeectl bright  <ip> <0-100>
swift run yeectl ct      <ip> <1700-6500>
swift run yeectl rgb     <ip> <hex e.g. FF8800>   # 氛围 / bg 通道
swift run yeectl rainbow <ip> [seconds]           # UDP 20 Hz 流式传输测试
```

## 架构

```
Sources/
  YeelightKit/            # 纯传输层库，不含 UI
    Yeelight.swift        # TCP 55443 JSON 控制 + UDP 55444 流式会话
    Discovery.swift       # SSDP 组播发现
    Scan.swift            # 主动子网扫描 + 手动 IP 校验
  yeectl/                 # CLI
  YeelightBarApp/         # SwiftUI 应用
    LampController.swift   # @MainActor 存储：发现、灯组控制、同步编排
    ScreenSyncEngine.swift # 多显示器采集 → 按（显示器，区域）取色 → UDP 分发
    MusicSyncEngine.swift  # 系统音频捕获 → 节拍 / 频谱 → UDP 分发
    FullView.swift / MenuPanelView.swift
```

Yeelight 局域网协议（TCP 控制、UDP 流式握手，以及挂灯那套古怪的 `main_power`/`bg_power` 通道）记录在 [`PROTOCOL.md`](PROTOCOL.md) 中。

## 关于 Screen Light Bar Pro 的说明

这盏灯有两个独立通道 —— 前置白光（`set_power` / `main_power`）和氛围 RGB（`bg_set_power` / `bg_set_rgb`）—— 因此你可以只运行 "仅氛围光"。它的 `power` 属性并不可靠（即便前置灯已熄灭也仍停留在 `on`）；应用改为读取 `main_power`。普通灯带只有单一通道，并会拒绝挂灯专属的 `dev_toggle`，因此控制指令会按设备类型分别分发。

## 许可证

[MIT](LICENSE) —— 与 Yeelight / Xiaomi 无任何关联，也未获其背书。
