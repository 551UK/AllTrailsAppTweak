ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AllTrailsAppTweak
AllTrailsAppTweak_FILES = Tweak.x
AllTrailsAppTweak_FRAMEWORKS = Foundation UIKit
AllTrailsAppTweak_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
