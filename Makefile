TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := MusorDropTrollTweak
MusorDropTrollTweak_FILES := Tweak.xm
MusorDropTrollTweak_CFLAGS := -fobjc-arc
MusorDropTrollTweak_FRAMEWORKS := UIKit AVFoundation
MusorDropTrollTweak_INSTALL_PATH := /Library/MobileSubstrate/DynamicLibraries

BUNDLE_NAME := MusorDropTrollTweakPrefs
MusorDropTrollTweakPrefs_CLASS_NAME := MDRootListController
MusorDropTrollTweakPrefs_FILES := Prefs/MDRootListController.m
MusorDropTrollTweakPrefs_CFLAGS := -fobjc-arc
MusorDropTrollTweakPrefs_FRAMEWORKS := UIKit
MusorDropTrollTweakPrefs_PRIVATE_FRAMEWORKS := Preferences
MusorDropTrollTweakPrefs_LDFLAGS := -undefined dynamic_lookup
MusorDropTrollTweakPrefs_RESOURCE_DIRS := Prefs/Resources
MusorDropTrollTweakPrefs_INSTALL_PATH := /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk
