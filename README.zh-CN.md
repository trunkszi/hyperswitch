# HyperSwitch

[English](README.md) | **简体中文**

面向键盘的 macOS 应用 / 窗口切换器。按住快捷键浏览正在运行的应用或窗口（可带实时缩略图），松手即可切换。为当前 macOS 原生重写。

HyperSwitch 是菜单栏代理（agent）应用：默认不占用 Dock，后台运行，通过菜单栏图标打开设置。

| | |
|---|---|
| **版本** | 1.0.0 |
| **平台** | macOS 26.0+，Apple Silicon（`arm64`） |
| **Bundle ID** | `com.hyperswitch.HyperSwitch` |
| **界面语言** | 英语、简体中文 |
| **许可证** | [MIT](LICENSE) |

---

## 功能

### 应用与窗口切换
- 全局快捷键打开应用切换器或窗口切换器
- 实时缩略图（需屏幕录制）与可选全尺寸预览
- 搜索、方向键导航、Return 激活、Escape 取消
- 非当前桌面（Space）窗口的指示
- 可配置延迟、缩略图尺寸、外观与交互

### 设置
- **通用** — 登录启动、语言、菜单栏 / 前台表现
- **应用切换器** — 快捷键、延迟校准、包含范围
- **交互** — 切换器打开时的键盘与指针行为
- **外观** — 主题、颜色、布局
- **关于** — 版本与权限状态

---

## 系统要求

- **macOS 26.0** 或更高
- **Apple Silicon** Mac
- 从源码构建需要 **Xcode** 命令行工具
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**（本机可用 `brew install xcodegen`）

### 权限

| 权限 | 是否必须 | 用途 |
|---|---|---|
| **辅助功能（Accessibility）** | 必须 | 事件监听、激活窗口、驱动切换器 |
| **屏幕录制（Screen Recording）** | 可选 | 实时缩略图与窗口标题 |

请在 **系统设置 → 隐私与安全性** 中授权。没有辅助功能时 HyperSwitch 无法工作。

---

## 安装（源码构建）

```bash
# 可选但强烈建议：本地稳定签名，避免每次重建丢权限
./scripts/setup-signing.sh

# Debug 构建 → /Applications/HyperSwitch.app
./scripts/build.sh

# Release 构建
CONFIG=Release ./scripts/build.sh

# 务必通过 Launch Services 启动
open /Applications/HyperSwitch.app
```

> **重要：** 不要从 shell 直接运行二进制。那会继承*终端*的 TCC 授权，权限会看起来已开启、实际并未授予应用。

### 发布包（DMG）

```bash
./scripts/release.sh
```

生成 `dist/HyperSwitch.dmg`。若有 **Developer ID Application** 证书及公证凭据（`HyperSwitchNotary`），脚本会额外签名并公证；否则保留本地 / ad-hoc 签名。

推送到 `main` 时 GitHub Actions 会构建并把 DMG 发布到 [Releases](../../releases)。CI 产物通常为 **ad-hoc 签名**。从浏览器或 AirDrop 下载后若被 Gatekeeper 拦截，可先清除隔离标记：

```bash
xattr -d com.apple.quarantine /path/to/HyperSwitch.dmg
```

然后打开磁盘映像，将 HyperSwitch 拖入「应用程序」。

### 应用图标

```bash
swift scripts/make-icon.swift /tmp
# 将 PNG 放入 Sources/HyperSwitch/Resources/Assets.xcassets/AppIcon.appiconset/
```

---

## 使用

1. 安装并打开 HyperSwitch。
2. 授予**辅助功能**（以及可选的**屏幕录制**）。
3. 使用配置的快捷键打开切换器；导航后松手（或按 Return）完成切换。
4. 从菜单栏图标打开设置。

---

## 项目结构

```
hyperswitch/
├── project.yml                 # XcodeGen 工程定义
├── scripts/
│   ├── build.sh                # 生成工程、构建、安装、签名
│   ├── release.sh              # Release 构建 + DMG（可选公证）
│   ├── setup-signing.sh        # 本地自签名，稳定 TCC
│   ├── make-icon.swift         # 生成 iconset
│   ├── extract-strings.py      # 检查缺失 / 过期本地化键
│   └── write-translations.py   # 根据表重写 Localizable.xcstrings
├── Sources/HyperSwitch/
│   ├── App/                    # 入口、状态栏、前台策略
│   ├── Core/                   # 偏好、权限、本地化
│   ├── Settings/               # 设置面板
│   ├── Switcher/               # 切换器 UI、快捷键、模型
│   ├── System/                 # AX、CGS、键码
│   ├── Thumbnails/             # ScreenCaptureKit 缩略图
│   ├── Windows/                # 窗口索引与操作
│   └── Resources/              # Info.plist、entitlements、资源、字符串
└── Tests/HyperSwitchTests/
```

`HyperSwitch.xcodeproj/`、`.build/`、`dist/` 为生成物，已 gitignore。

---

## 开发

```bash
xcodegen generate
./scripts/build.sh
open HyperSwitch.xcodeproj
```

### 说明

- **App Sandbox 必须关闭**，否则无法对其他应用使用 Accessibility。
- **签名：** `build.sh` 优先使用 `setup-signing.sh` 的 “HyperSwitch Local Signing”，否则 ad-hoc。
- **Swift 6**，默认 Actor 隔离 `MainActor`，严格并发。
- 界面语言可跟随系统，或强制英语 / 简体中文。

### 本地化辅助

```bash
scripts/extract-strings.py          # 缺失 / 过期键
scripts/write-translations.py       # 按表重写 Localizable.xcstrings
```

---

## 卸载

1. 从菜单栏图标退出 HyperSwitch。
2. `rm -rf /Applications/HyperSwitch.app`
3. 可选：`defaults delete com.hyperswitch.HyperSwitch 2>/dev/null || true`

---

## 许可证

本项目采用 [MIT License](LICENSE) 开源许可。
