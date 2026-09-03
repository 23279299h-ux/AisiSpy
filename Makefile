ARCHS = arm64
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = AisiSpy

AisiSpy_FILES = \
	AisiSpy/main.m \
	AisiSpy/AppDelegate.m \
	AisiSpy/ViewController.m \
	AisiSpy/LogViewController.m

AisiSpy_FRAMEWORKS = UIKit Foundation CoreGraphics
AisiSpy_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -IAisiSpy -fno-modules
AisiSpy_LDFLAGS = -F.

# 资源文件
AisiSpy_RESOURCE_DIRS = Resources

include $(THEOS_MAKE_PATH)/application.mk

# 编译后步骤：编译helper + Tweak，打包进APP
after-stage::
	@echo "=== 编译root helper ==="
	xcrun --sdk iphoneos clang -arch arm64 -isysroot $(THEOS_SDK) \
		-o $(THEOS_STAGING_DIR)/Applications/AisiSpy.app/aisi_helper \
		helper/helper.c -framework Foundation -framework IOKit -O2
	chmod 6755 $(THEOS_STAGING_DIR)/Applications/AisiSpy.app/aisi_helper
	@echo "helper已设置setuid root"

	@echo "=== 编译Tweak.dylib ==="
	$(MAKE) -C Tweak
	cp Tweak/.theos/obj/debug/AisiMonitor.dylib \
		$(THEOS_STAGING_DIR)/Applications/AisiSpy.app/AisiMonitor.dylib
	@echo "Tweak.dylib已打包"

# 打包成IPA
ipa:
	@echo "=== 打包IPA ==="
	rm -rf build/Payload
	mkdir -p build/Payload
	cp -R $(THEOS_STAGING_DIR)/Applications/AisiSpy.app build/Payload/
	# 签名（TrollStore会重新签名，这里用ldid伪签名）
	ldid -SResources/entitlements.plist build/Payload/AisiSpy.app/AisiSpy
	cd build && zip -r ../AisiSpy.ipa Payload/
	@echo "IPA已生成: AisiSpy.ipa"
