ARCHS = arm64
TARGET = iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = smoba

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = GameDump
GameDump_FILES = Tweak.xm
GameDump_CFLAGS = -fobjc-arc -Wno-error
GameDump_LDFLAGS = -framework Foundation -framework CoreFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
