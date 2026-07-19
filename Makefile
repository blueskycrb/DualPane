# latest = whatever SDK Theos/Xcode provides; deploy target 15.0 for Bootstrap range
export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DualPane

DualPane_FILES = \
	Sources/Tweak.x \
	Sources/DPSettings.m \
	Sources/DPFloatingWindow.m \
	Sources/DPSplitManager.m \
	Sources/DPWindowManager.m \
	Sources/DPGestureController.m \
	Sources/DPAppPicker.m \
	Sources/DPSceneHost.m \
	Sources/DPOverlayController.m \
	Sources/DPPassthroughWindow.m

DualPane_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
# FrontBoard etc. are resolved at runtime via NSClassFromString — do not link private frameworks
# (they are absent from public SDKs and break CI / clean Theos installs).
DualPane_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
DualPane_LIBRARIES =

SUBPROJECTS += Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
