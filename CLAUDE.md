# DualPane — Theos rootless tweak for Bootstrap / iOS 15–16.5.1

## Build
- Requires Theos + iOS SDK on macOS or Linux (`make package FINALPACKAGE=1`)
- `THEOS_PACKAGE_SCHEME=rootless` is set in the root Makefile
- Output: `packages/com.dualpane.tweak_*_iphoneos-arm64.deb`

## Layout
- `Sources/` — tweak logic (hooks, floating, split, gestures, picker, scene host)
- `Preferences/` — Settings bundle (PreferenceLoader)
- Filter: SpringBoard only (`DualPane.plist`)

## Runtime notes
- Scene hosting resolves FrontBoard private APIs dynamically; falls back to placeholder UI
- Prefs domain: `com.dualpane.tweak`
- Darwin notify: `com.dualpane.tweak/settings.changed`
- Rootless prefs path: `/var/jb/var/mobile/Library/Preferences/com.dualpane.tweak.plist`
