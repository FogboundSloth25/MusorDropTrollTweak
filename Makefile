TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := MusorDropTrollTweak
MusorDropTrollTweak_FILES := Tweak.xm
MusorDropTrollTweak_CFLAGS := -fobjc-arc
MusorDropTrollTweak_FRAMEWORKS := UIKit AVFoundation
MusorDropTrollTweak_INSTALL_PATH := /Library/MobileSubstrate/DynamicLibraries

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += Prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
