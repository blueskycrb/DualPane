# DualPane

**Floating window + true split-screen multitasking** for **roothide Bootstrap** on **iOS 15.0 – 16.5.1**, built as an **arm64e** tweak.

中文说明见下方 [中文](#中文).

---

## Features

| Feature | Description |
|---|---|
| **Floating window** | Draggable, resizable, pinch-to-scale overlay hosting a second app. Title-bar close / split / maximize. |
| **True split-screen** | Side-by-side **or** top/bottom layout with a draggable divider (20%–80%). Swap panes, promote secondary to floating. |
| **App picker** | SpringBoard-style grid with search, favorites-first sorting, blacklist support. |
| **Activation gestures** | Edge swipe (L/R), 3-finger swipe up, status-bar double-tap, home-indicator long-press. |
| **Mode chooser** | Optional “Ask every time” prompt: Floating vs Split. |
| **Preference bundle** | Full Settings pane (EN/中文 labels): sizes, opacity, corner radius, haptics, orientation, favorites, blacklist, respring. |
| **roothide Bootstrap** | `THEOS_PACKAGE_SCHEME = roothide`, Debian `iphoneos-arm64e`, native arm64e. |

## Requirements

- Jailbroken device on **iOS 15.0 – 16.5.1**
- **RootHide Bootstrap 2.x** with the target app enabled in Bootstrap's App List
- **PreferenceLoader**
- To **build**: macOS (or Linux) with [Theos](https://theos.dev), Xcode CLT / iOS SDK ≥ 15

> This repository is authored on Windows for convenience; **compilation must happen on a Theos host** (Mac/Linux or a remote build box). The produced `.deb` installs on the phone via Sileo / Zebra / `dpkg`.

## Architecture

```
DualPane/
├── Makefile / control / DualPane.plist
├── Sources/
│   ├── Tweak.x                 # SpringBoard hooks, bootstrap
│   ├── DPSettings.*            # Preferences + Darwin notify
│   ├── DPWindowManager.*       # Coordinator (floating + split)
│   ├── DPFloatingWindow.*      # Chrome: drag / resize / pinch
│   ├── DPSplitManager.*        # Divider layout + toolbar
│   ├── DPSceneHost.*           # FrontBoard scene host (runtime-resolved)
│   ├── DPGestureController.*   # Activation gestures
│   ├── DPAppPicker.*           # App grid sheet
│   └── DPOverlayController.*   # Mode chooser card
└── Preferences/                # Settings bundle
```

### Scene hosting (important)

Live embedding of a second app’s UI into a `UIView` requires **SpringBoard / FrontBoard private APIs** (`SBApplication`, `FBSceneHostManager`, …). DualPane resolves these **dynamically at runtime** so the project still compiles against a public SDK:

1. If private classes exist and a scene for the target bundle is found → live host view is attached.
2. Otherwise → a branded **placeholder** (icon + name + hint) is shown so chrome, gestures, and layout can still be exercised.

On a real Bootstrap device, DualPane launches the target app suspended, waits briefly for its scene, foregrounds that scene without a full-screen transition, and attaches a live layer container.

## Build

### Option A — GitHub Actions (recommended)

Every push to `main` verifies the roothide package build on `macos-14` with `roothide/theos`. Published releases provide the `.deb` directly, without a ZIP artifact:
The packaged tweak and preference bundle are native `arm64e` Mach-O binaries. The Debian package metadata is `iphoneos-arm64e`.

1. Open **Releases**
2. Select the latest version
3. Download `DualPane_<version>_arm64e_roothide.deb`

Manual trigger: Actions → Build DualPane → **Run workflow**.

### Option B — Local Theos

```bash
export THEOS=~/theos
cd DualPane
make package FINALPACKAGE=1
# → packages/com.dualpane.tweak_1.1.1_iphoneos-arm64e.deb
```

Install on device:

```bash
dpkg -i com.dualpane.tweak_1.1.1_iphoneos-arm64e.deb
sbreload   # or respring from Settings → DualPane
```

Or add the deb to Sileo / Zebra.

## Usage

1. Settings → **DualPane** → enable, pick default mode & gestures.
2. Trigger an activation gesture (default: **edge swipe** or **3-finger swipe up**).
3. Choose **Floating** or **Split** (if “Ask”), then pick an app.
4. **Floating**: drag title bar, pinch / corner-resize, tap split icon to expand.
5. **Split**: drag the center divider, use the top pill for close / swap / float.

## Configuration keys

Domain: `com.dualpane.tweak`  
Notify: `com.dualpane.tweak/settings.changed`

| Key | Type | Default | Notes |
|---|---|---|---|
| `enabled` | bool | true | Master switch |
| `defaultMode` | int | 2 | 0=Floating, 1=Split, 2=Ask |
| `splitOrientation` | int | 0 | 0=H, 1=V |
| `defaultSplitRatio` | float | 0.5 | 0.2–0.8 |
| `floatingWidth/Height` | float | 280/500 | |
| `floatingOpacity` | float | 1.0 | |
| `floatingCornerRadius` | float | 16 | |
| `maxFloatingWindows` | int | 2 | 1–4 |
| `enabledGestures` | array | [0,1] | 0 edge, 1 3-finger, 2 status, 3 home |
| `favorites` / `blacklist` | array | [] | bundle IDs |

## Safety / scope

- Hooks **SpringBoard only** (`DualPane.plist` filter).
- Does **not** patch system apps’ own processes.
- Blacklist any banking / DRM apps you don’t want hosted.
- Private-API scene hosting is best-effort; treat 1.0 as a solid chrome + gesture + prefs foundation with a pluggable host layer.

## License

MIT — see [LICENSE](LICENSE).

## Credits

- [Theos](https://theos.dev)
- [Bootstrap (RootHide)](https://github.com/RootHide/Bootstrap)
- Community research on FBScene / roothide packaging

---

## 中文

**DualPane** 是面向 **iOS 15.0–16.5.1**、适配 **RootHide Bootstrap / roothide arm64e** 环境的 SpringBoard 插件，提供：

- **悬浮窗**：可拖动、缩放、捏合，支持关闭 / 转分屏 / 最大化  
- **真分屏**：左右或上下布局，中间分割条可拖，支持交换与转悬浮  
- **应用选择器**：搜索、收藏置顶、黑名单  
- **多种手势**：边缘滑动、三指上滑、状态栏双击、主页指示条长按  
- **完整设置页**：中英双语标签，支持注销与重置  

### 编译与安装

需在 macOS/Linux + Theos 环境编译（本仓库可在 Windows 维护源码）：

```bash
make package FINALPACKAGE=1
# 将 deb 拷到手机后
dpkg -i com.dualpane.tweak_*.deb && sbreload
```

### 关于“第二个 App 的真实画面”

把另一个 App 的界面嵌进悬浮窗/分屏，依赖 SpringBoard 的 **FrontBoard 私有 API**。DualPane 在运行时动态查找这些类：

- 找到且目标 App 已有 scene → 嵌入真实画面  
- 否则显示占位页（仍可完整使用手势、布局、设置）

建议先打开一次目标 App，再触发 DualPane。欢迎针对 16.5.1 实机提交 scene host 相关 PR。

### 使用

1. 设置 → DualPane → 打开开关，配置手势与默认模式  
2. 边缘滑动或三指上滑唤出  
3. 选择悬浮窗或分屏，再选应用  

---

**Repo:** https://github.com/blueskycrb/DualPane  
**Package:** `com.dualpane.tweak`  
**Version:** 1.1.1
