ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = netdisk_iPhone

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BDNadBlock
BDNadBlock_FILES = Tweak.xm
BDNadBlock_CFLAGS = -fobjc-arc
BDNadBlock_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk