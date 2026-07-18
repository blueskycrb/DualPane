export TARGET = iphone:clang:16.5:15.0
export ARCHS = arm64 arm64e
export THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = DualPanePrefs

DualPanePrefs_FILES = DPRootListController.m DPAppListController.m
DualPanePrefs_FRAMEWORKS = UIKit
DualPanePrefs_PRIVATE_FRAMEWORKS = Preferences
DualPanePrefs_INSTALL_PATH = /Library/PreferenceBundles
DualPanePrefs_CFLAGS = -fobjc-arc
DualPanePrefs_LIBRARIES =

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/DualPane.plist$(ECHO_END)
