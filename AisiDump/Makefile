TARGET := iphone:clang:latest:15.0
INSTALL_TARGET_PROCESSES = rn.notes.best

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AisiDump

AisiDump_FILES = Tweak.xm
AisiDump_CFLAGS = -fobjc-arc
AisiDump_FRAMEWORKS = Foundation UIKit CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
