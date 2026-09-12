ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:13.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SmartFinalUpdateBypass
SmartFinalUpdateBypass_FILES = Tweak.xm
SmartFinalUpdateBypass_CFLAGS = -fobjc-arc
SmartFinalUpdateBypass_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
