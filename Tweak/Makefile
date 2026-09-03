ARCHS = arm64
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

LIBRARY_NAME = AisiMonitor
AisiMonitor_FILES = Tweak.xm
AisiMonitor_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
AisiMonitor_LDFLAGS = -lsubstrate
AisiMonitor_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics
AisiMonitor_INSTALL_PATH = /usr/lib

include $(THEOS_MAKE_PATH)/library.mk
