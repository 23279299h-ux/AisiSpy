#!/bin/bash
# AisiSpy 一键编译打包脚本
# 生成 TrollStore 可安装的 IPA
# 需要: theos + iOS SDK + ldid (Mac或Linux)

set -e

echo "============================================"
echo "  AisiSpy - TrollStore IPA 编译打包工具"
echo "============================================"

# 检查theos
if [ -z "$THEOS" ]; then
    export THEOS=~/theos
fi
if [ ! -d "$THEOS" ]; then
    echo "[错误] 未找到theos，请先安装:"
    echo "  bash -c \"$(curl -fsSL https://raw.githubusercontent.com/theos/theos/master/bin/install-theos)\""
    exit 1
fi

SDK=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "$THEOS/sdks/iPhoneOS16.5.sdk")
echo "[信息] SDK: $SDK"
echo ""

# ========== 1. 编译Tweak.dylib ==========
echo "[1/4] 编译 Tweak.dylib (注入用)..."
cd Tweak
make clean package FINALPACKAGE=1 2>&1 | tail -3
if [ ! -f .theos/obj/debug/AisiMonitor.dylib ]; then
    echo "[错误] Tweak.dylib编译失败"
    exit 1
fi
echo "  -> Tweak.dylib 编译成功 ($(du -h .theos/obj/debug/AisiMonitor.dylib | cut -f1))"
cd ..

# ========== 2. 编译root helper ==========
echo "[2/4] 编译 root helper..."
clang -arch arm64 -isysroot "$SDK" \
    -o helper/aisi_helper \
    helper/helper.c \
    -framework Foundation -framework IOKit \
    -O2 -Wno-deprecated-declarations
chmod 6755 helper/aisi_helper
echo "  -> aisi_helper 编译成功 (setuid root)"

# ========== 3. 编译App ==========
echo "[3/4] 编译 AisiSpy App..."
make clean package FINALPACKAGE=1 2>&1 | tail -5

# 找到编译好的APP
APP_PATH=$(find .theos -name "AisiSpy.app" -type d 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    # theos可能放在其他位置
    APP_PATH=$(find $THEOS_STAGING_DIR -name "AisiSpy.app" -type d 2>/dev/null | head -1)
fi
if [ -z "$APP_PATH" ]; then
    echo "[错误] 未找到编译好的AisiSpy.app"
    echo "  尝试手动查找..."
    find . -name "AisiSpy.app" -type d 2>/dev/null
    exit 1
fi
echo "  -> App编译成功: $APP_PATH"

# ========== 4. 打包IPA ==========
echo "[4/4] 打包 IPA..."
rm -rf build
mkdir -p build/Payload

# 复制APP
cp -R "$APP_PATH" build/Payload/AisiSpy.app

# 复制helper和Tweak到APP内
cp helper/aisi_helper build/Payload/AisiSpy.app/
cp Tweak/.theos/obj/debug/AisiMonitor.dylib build/Payload/AisiSpy.app/
chmod 6755 build/Payload/AisiSpy.app/aisi_helper
chmod 755 build/Payload/AisiSpy.app/AisiMonitor.dylib

# 用entitlements签名主二进制
ldid -SResources/entitlements.plist build/Payload/AisiSpy.app/AisiSpy
ldid -SResources/entitlements.plist build/Payload/AisiSpy.app/aisi_helper

# 复制Info.plist
cp Resources/Info.plist build/Payload/AisiSpy.app/Info.plist

# 打包
cd build
zip -qr ../AisiSpy.ipa Payload/
cd ..

# 生成TIPA (TrollStore专用格式 = IPA + 特殊元数据)
cp AisiSpy.ipa AisiSpy.tipa

echo ""
echo "============================================"
echo "  编译完成!"
echo "============================================"
echo "  IPA:  AisiSpy.ipa ($(du -h AisiSpy.ipa | cut -f1))"
echo "  TIPA: AisiSpy.tipa ($(du -h AisiSpy.tipa | cut -f1))"
echo ""
echo "安装方法:"
echo "  1. 将 AisiSpy.ipa (或.tipa) 传到手机"
echo "  2. 用 TrollStore 打开安装"
echo "  3. 打开AisiSpy App"
echo "  4. 启动爱思助手"
echo "  5. 在AisiSpy中点「注入监视」"
echo ""
echo "日志位置:"
echo "  /var/mobile/Documents/aisi_monitor.log"
echo "  /var/mobile/Documents/aisi_helper.log"
echo "============================================"
