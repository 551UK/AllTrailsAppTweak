ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AllTrailsAppTweak
AllTrailsAppTweak_FILES = Tweak.x Receiver.xm
AllTrailsAppTweak_FRAMEWORKS = Foundation UIKit
AllTrailsAppTweak_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
