# DualPane — Theos rootful arm64e tweak for Bootstrap / iOS 15–16.5.1

## Build
- Requires Theos + iOS SDK on macOS or Linux (`make package FINALPACKAGE=1`)
- The root Makefile leaves `THEOS_PACKAGE_SCHEME` unset, so Theos uses its default rootful package layout
- Output: `packages/com.dualpane.tweak_*_iphoneos-arm64.deb`

## Layout
- `Sources/` — tweak logic (hooks, floating, split, gestures, picker, scene host)
- `Preferences/` — Settings bundle (PreferenceLoader)
- Filter: SpringBoard only (`DualPane.plist`)

## Runtime notes
- Scene hosting resolves FrontBoard private APIs dynamically; falls back to placeholder UI
- Prefs domain: `com.dualpane.tweak`
- Darwin notify: `com.dualpane.tweak/settings.changed`
- Rootful prefs path: `/var/mobile/Library/Preferences/com.dualpane.tweak.plist`
