TARGET := iphone:clang:latest:15.0
ARCHS := arm64
THEOS_PACKAGE_SCHEME := rootless

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME := NFCPrank
NFCPrank_FILES := main.m AppDelegate.m NFCViewController.m
NFCPrank_FRAMEWORKS := UIKit CoreNFC
NFCPrank_CFLAGS := -fobjc-arc -Wall -Wextra
NFCPrank_CODESIGN_FLAGS := -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

# Refresh SpringBoard's application cache after installing the deb.
after-install::
	install.exec "uicache -a" || true
