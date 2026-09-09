ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:16.0
THEOS_PACKAGE_SCHEME = rootless
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AllTrailsLinkFix
AllTrailsLinkFix_FILES = NativeLinks.m
AllTrailsLinkFix_LIBRARIES = substrate
AllTrailsLinkFix_FRAMEWORKS = Foundation UIKit
AllTrailsLinkFix_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk

