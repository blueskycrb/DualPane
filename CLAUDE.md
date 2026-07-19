# DualPane — Theos roothide arm64e tweak for RootHide Bootstrap / iOS 15–16.5.1

## Build
- Requires Theos + iOS SDK on macOS or Linux (`make package FINALPACKAGE=1`)
- `THEOS_PACKAGE_SCHEME=roothide` and `DEB_ARCH=iphoneos-arm64e` are set in the root Makefile
- Output: `packages/com.dualpane.tweak_*_iphoneos-arm64e.deb`

## Layout
- `Sources/` — tweak logic (hooks, floating, split, gestures, picker, scene host)
- `Preferences/` — Settings bundle (PreferenceLoader)
- Filter: SpringBoard only (`DualPane.plist`)

## Runtime notes
- Scene hosting resolves FrontBoard private APIs dynamically; falls back to placeholder UI
- Prefs domain: `com.dualpane.tweak`
- Darwin notify: `com.dualpane.tweak/settings.changed`
- Preferences paths use the official `jbroot()` API; roothide does not use a fixed `/var/jb` root
