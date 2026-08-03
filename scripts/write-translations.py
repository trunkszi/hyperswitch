#!/usr/bin/env python3
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOGUE = ROOT / "Sources" / "HyperSwitch" / "Resources" / "Localizable.xcstrings"

EXTRA_KEYS = [
    "Control", "Option", "Command", "Shift", "Function", "None",
    "Press Space to keep the switcher open · Release the modifier to switch",
    "Type to search · Arrow keys navigate · Return opens · Escape cancels",
    "Type to search · Delete edits · Escape clears or cancels · Return opens",
    "Background color",
    "windows",
    "Pinned",
    "Restore all HyperSwitch settings to their defaults?",
]

IGNORED_KEYS = {"keyboard"}

KEY_FOR_SOURCE = {
    r"Version \(version)": "Version %@",
    r"Desktop \(number)": "Desktop %lld",
    r"\(app.windowCount) windows": "%lld windows",
    r"\(Int(preferences.thumbnailSize)) px": "%lld px",
    r"Could not change the login item: \(failure)": "Could not change the login item: %@",
    r"Desktop \(space)": "Desktop %lld",
    r"Recommended: \(recommendation) ms": "Recommended: %lld ms",
    r"Samples: \(session.calibration.samples.count) of \(session.calibration.requiredSamples)":
        "Samples: %lld of %lld",
}

TRANSLATIONS: dict[str, str] = {
    "Control": "Control",
    "Option": "Option",
    "Command": "Command",
    "Shift": "Shift",
    "Function": "Fn",
    "None": "无",
    "windows": "个窗口",

    "General": "通用",
    "App Switcher": "应用切换器",
    "Appearance": "外观",
    "About": "关于",
    "HyperSwitch": "HyperSwitch",

    "Run HyperSwitch in the background": "在后台运行 HyperSwitch",
    "If enabled, HyperSwitch keeps running in the background and is automatically started when you log in.":
        "开启后 HyperSwitch 会常驻后台运行，并在你登录时自动启动。",
    "Activate the window switcher for": "窗口切换器的触发方式",
    "All windows": "全部窗口",
    "Current app's windows": "当前应用的窗口",
    "+ ⇥ (Tab)": "+ ⇥ (Tab)",
    "Delay activation for": "延迟激活",
    "ms": "毫秒",
    "Show on Screen": "显示在屏幕",
    "Active Screen": "活动屏幕",
    "Screen with Mouse": "指针所在屏幕",
    "Main Screen": "主屏幕",
    "Releasing the modifier before the delay elapses switches straight away, without showing the switcher.":
        "在延迟结束前松开修饰键会直接切换，不显示切换器。",
    "Include windows from other spaces": "包含其他桌面上的窗口",
    "Include windows from other screens": "包含其他屏幕上的窗口",
    "Include minimized windows": "包含已最小化的窗口",
    "Show full size previews on hover": "指针悬停时显示全尺寸预览",
    "Full size preview delay": "全尺寸预览延迟",
    "Could not change the login item: %@": "无法修改登录项：%@",
    "Use shift to cycle backwards": "用 Shift 反向循环",

    "Show window previews on the app switcher (⌘ + Tab)": "在应用切换器上显示窗口预览（⌘ + Tab）",
    "Use the arrow keys to move between the app row and its windows.":
        "用方向键在应用行与其窗口之间移动。",
    "ms on first activation": "毫秒（首次激活）",
    "ms on subsequent activations": "毫秒（后续激活）",
    "The application row appears at once. Only the window previews wait, so a quick ⌘Tab stays quick.":
        "应用行会立即出现，等待的只是窗口预览，所以快速按 ⌘Tab 依然很快。",
    "When activating an app without windows, try to open the default window":
        "激活没有窗口的应用时，尝试打开其默认窗口",
    "Automatically activate the current app after": "自动激活当前选中的应用，延迟",
    "Both apply only while HyperSwitch is drawing the ⌘Tab switcher. With previews off the system's own switcher takes over and neither has any effect.":
        "这两项仅在 HyperSwitch 自绘 ⌘Tab 切换器时生效。关闭预览后由系统自带的切换器接管，两项都不起作用。",

    "System Default": "跟随系统",
    "Light": "浅色",
    "Dark": "深色",
    "Blur window background": "模糊窗口背景",
    "Lower the background colour's opacity to blur what is behind the switcher.":
        "把背景颜色的不透明度调低，才能模糊切换器背后的内容。",
    "Reduce Transparency is on, so the switcher already uses an opaque background.":
        "系统已开启「降低透明度」，切换器现在用的是不透明背景。",
    "Reduce Motion is on, so the switcher always disappears instantly.":
        "系统已开启「减弱动态效果」，切换器总是立即消失。",
    "Thumbnail size": "缩略图尺寸",
    "%lld px": "%lld 像素",
    "Quality": "画质",
    "Low": "低",
    "Medium": "中",
    "High": "高",
    "Show app icons": "显示应用图标",
    "Small": "小",
    "Large": "大",
    "Hide animation": "隐藏动画",
    "Fade out": "淡出",
    "Scale down": "缩小",
    "No animation": "无动画",
    "Show HyperSwitch in": "在以下位置显示 HyperSwitch",
    "the Dock": "程序坞",
    "the menu bar": "菜单栏",
    "With both off HyperSwitch keeps running, but has no visible way in. Opening it again from the Applications folder brings the menu bar icon back.":
        "两项都关闭后 HyperSwitch 仍在运行，但没有任何可见入口。从「应用程序」文件夹再次打开它即可恢复菜单栏图标。",
    "The Dock icon returns to its setting once this window closes.":
        "Dock 图标会在本窗口关闭后按设置生效。",

    "Version %@": "版本 %@",
    "Hold a modifier and press Tab to see every open window as a preview — including windows on other desktops and ones you have minimized — then release on the one you want.":
        "按住修饰键并按 Tab，即可看到所有已打开窗口的预览——包括其他桌面上的窗口和已最小化的窗口——在想要的那个上松手即可切过去。",
    "Language": "语言",
    "Interface language": "界面语言",
    "Match System": "跟随系统",
    "Takes effect immediately — no restart needed.": "立即生效，无需重启。",
    "Permissions": "权限",
    "Accessibility": "辅助功能",
    "Screen Recording": "屏幕录制",
    "Granted": "已授权",
    "Not granted": "未授权",
    "Open Settings": "打开设置",
    "Accessibility lets HyperSwitch see the hotkeys and raise, close and minimize windows — without it nothing here works. Screen Recording adds the window thumbnails and the real window titles.":
        "辅助功能让 HyperSwitch 能接收快捷键并抬升、关闭、最小化窗口——没有它这里的一切都无法工作。屏幕录制则提供窗口缩略图和真实的窗口标题。",
    "Open Console": "打开控制台",
    "Reveal in Finder": "在访达中显示",
    "Restore Defaults": "恢复默认值",
    "Restore all settings to their defaults?": "要把所有设置恢复为默认值吗？",
    "Every preference returns to the value HyperSwitch ships with, and it stops opening at login. This cannot be undone.":
        "每一项设置都会回到 HyperSwitch 出厂时的值，并且不再随登录启动。此操作无法撤销。",
    "Cancel": "取消",
    "OK": "好",

    "No Windows": "没有窗口",
    "Minimized": "已最小化",
    "Desktop %lld": "桌面 %lld",
    "%lld windows": "%lld 个窗口",

    "About HyperSwitch": "关于 HyperSwitch",
    "Hide HyperSwitch": "隐藏 HyperSwitch",
    "Hide Others": "隐藏其他",
    "Show All": "全部显示",
    "Edit": "编辑",
    "Cut": "剪切",
    "Copy": "拷贝",
    "Paste": "粘贴",
    "Select All": "全选",
    "Window": "窗口",
    "Minimize": "最小化",
    "Zoom": "缩放",
    "Close": "关闭",

    "Window Switcher On": "窗口切换器：开",
    "Window Switcher Off": "窗口切换器：关",
    "Hide Menu Bar Icon": "隐藏菜单栏图标",
    "Hide the menu bar icon?": "要隐藏菜单栏图标吗？",
    "Hide Icon": "隐藏图标",
    "The Dock icon is already off, so this removes the last way in. HyperSwitch keeps running and its keyboard shortcuts still work. To bring the icon back, open HyperSwitch again from your Applications folder.":
        "程序坞图标已经关闭，隐藏后就没有任何入口了。HyperSwitch 仍在运行，快捷键照常有效。想让图标回来，从「应用程序」文件夹再次打开 HyperSwitch 即可。",
    "Permissions needed": "需要授予权限",
    "Settings…": "设置…",
    "Quit HyperSwitch": "退出 HyperSwitch",

    "HyperSwitch is now hidden": "HyperSwitch 已隐藏",
    "It keeps running and its keyboard shortcuts still work. To bring the menu bar icon back, open HyperSwitch again from your Applications folder.":
        "它仍在运行，快捷键照常有效。想让菜单栏图标回来，从「应用程序」文件夹再次打开 HyperSwitch 即可。",

    "Type to search windows": "输入以搜索窗口",
    "Window search": "窗口搜索",
    "Window position": "窗口位置",
    "No matching windows": "没有匹配的窗口",
    "Loading searchable windows…": "正在载入可搜索的窗口…",
    "Press Space to keep the switcher open · Release the modifier to switch":
        "按空格键可让切换器保持打开 · 松开修饰键即切换",
    "Type to search · Arrow keys navigate · Return opens · Escape cancels":
        "输入即可搜索 · 方向键移动 · 回车键打开 · Esc 键取消",
    "Type to search · Delete edits · Escape clears or cancels · Return opens":
        "输入即可搜索 · 删除键修改 · Esc 键清空或取消 · 回车键打开",

    "Hands and keyboard": "手感与键盘",
    "Allow Space to keep the switcher open": "允许用空格键让切换器保持打开",
    "Show keyboard hints after a short pause": "短暂停顿后显示键盘提示",
    "Keep the selection in the central visual band": "让选中项保持在视觉中央区域",
    "Require Q twice before quitting an app": "退出应用前需要按两次 Q",
    "The second Q must target the same app within 0.9 seconds. Moving the selection cancels the confirmation.":
        "第二次 Q 必须在 0.9 秒内指向同一个应用。移动选中项即取消确认。",
    "Long lists": "长列表",
    "Group long lists by app and Desktop": "长列表按应用和桌面分组",
    "HyperSwitch draws only the nearby 5–7 cards. All results remain reachable, while layout and thumbnail work stay bounded.":
        "HyperSwitch 只绘制附近的 5–7 张卡片。所有结果依然可以走到，而布局和缩略图的开销保持有界。",

    "Calibrate activation delay": "校准激活延迟",
    "Apply recommendation": "应用推荐值",
    "Start over": "重新开始",

    "Background color": "背景颜色",

    "Interaction": "操作体验",
    "Comfort display: larger labels and targets": "舒适显示：更大的文字与点按目标",
    "Comfort display shows at most five nearby windows with stronger selection outlines and larger text.":
        "舒适显示最多呈现附近五个窗口，选中描边更明显，文字更大。",
    "Press Q again to quit the selected app": "再按一次 Q 退出选中的应用",
    "Pinned mode lets you release the modifier, browse with the arrow keys, type to search, press Return to open, or Escape to cancel.":
        "固定模式下可以松开修饰键，用方向键浏览、输入搜索、回车键打开、Esc 键取消。",
    "Enable search and grouping at": "启用搜索与分组的阈值",
    "Safety": "安全",

    "Shortcut conflicts": "快捷键冲突",
    "No shortcut conflicts detected": "未检测到快捷键冲突",
    "Use recommended shortcuts": "使用推荐的快捷键",
    "Checks HyperSwitch bindings and enabled macOS symbolic shortcuts. macOS does not provide a reliable list of shortcuts owned privately by other apps.":
        "检查 HyperSwitch 的按键绑定与已启用的 macOS 系统快捷键。macOS 不提供其他应用私有快捷键的可靠列表。",

    "Calibrate delay…": "校准延迟…",
    "Waiting for shortcut": "等待快捷键",
    "Sampling complete": "采样完成",
    "Press and release your All Windows shortcut at a comfortable quick-switch pace. HyperSwitch records only the timing and will not open the switcher during these samples.":
        "以你平时快速切换的节奏按下并松开「所有窗口」快捷键。HyperSwitch 只记录时间，采样期间不会打开切换器。",
    "Samples: %lld of %lld": "已采样 %1$lld / %2$lld",
    "Recommended: %lld ms": "推荐值：%lld 毫秒",
    "%@ conflicts with %@": "%1$@ 与 %2$@ 冲突",
    "macOS shortcut %@": "macOS 快捷键 %@",
    "Pinned": "已锁定",
    "Restore all HyperSwitch settings to their defaults?":
        "要将 HyperSwitch 的全部设置恢复为默认值吗？",
}

def source_keys() -> list[str]:
    result = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "extract-strings.py"), "--list"],
        capture_output=True, text=True, check=True,
    )
    return [line for line in result.stdout.splitlines() if line.strip()]

def main() -> int:
    raw = (set(source_keys()) | set(EXTRA_KEYS)) - IGNORED_KEYS
    keys = sorted(KEY_FOR_SOURCE.get(key, key) for key in raw)

    missing = [k for k in keys if k not in TRANSLATIONS]
    if missing:
        print("No translation for:")
        for key in missing:
            print(f"  {key!r}")
        return 1

    unused = [k for k in TRANSLATIONS if k not in keys]
    if unused:
        print("In the table but not in the sources (harmless, but probably stale):")
        for key in unused:
            print(f"  {key!r}")

    catalogue = {
        "sourceLanguage": "en",
        "strings": {
            key: {
                "extractionState": "manual",
                "localizations": {
                    "zh-Hans": {
                        "stringUnit": {"state": "translated", "value": TRANSLATIONS[key]}
                    }
                },
            }
            for key in keys
        },
        "version": "1.0",
    }
    CATALOGUE.write_text(
        json.dumps(catalogue, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"wrote {len(keys)} keys to {CATALOGUE.relative_to(ROOT)}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
