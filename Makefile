ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AllTrailsAppTweak
AllTrailsAppTweak_FILES = NativeLinks.m
AllTrailsAppTweak_LIBRARIES = substrate
AllTrailsAppTweak_FRAMEWORKS = Foundation UIKit
AllTrailsAppTweak_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

