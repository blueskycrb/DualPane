export TARGET = iphone:clang:16.5:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

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
	Sources/DPOverlayController.m

DualPane_CFLAGS = -fobjc-arc -Wno-unused-variable -Wno-deprecated-declarations
DualPane_FRAMEWORKS = UIKit Foundation CoreGraphics QuartzCore
DualPane_PRIVATE_FRAMEWORKS = SpringBoardServices FrontBoard FrontBoardServices
DualPane_LIBRARIES =

SUBPROJECTS += Preferences

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/aggregate.mk

after-install::
	install.exec "killall -9 SpringBoard || true"
