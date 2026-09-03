#!/bin/bash
# AisiSpy 手机端一键编译脚本
# 需要: TrollStore + Sileo + Procursus工具链
# 在NewTerm中运行: bash build_on_ios.sh

set -e

echo "============================================"
echo "  AisiSpy 手机端编译"
echo "============================================"

# 检查是否在iOS上
if [ ! -d "/var/mobile" ]; then
    echo "[错误] 请在iOS设备上运行此脚本"
    exit 1
fi

# 检查root
if [ "$(id -u)" != "0" ]; then
    echo "[信息] 当前非root，尝试sudo..."
    if command -v sudo &> /dev/null; then
        sudo bash "$0" "$@"
        exit $?
    else
        echo "[错误] 需要root权限，请在NewTerm中用su切换到root"
        echo "  或安装sudo: apt install sudo"
        exit 1
    fi
fi

echo "[信息] 当前用户: $(whoami)"
echo ""

# ========== 1. 检查/安装依赖 ==========
echo "[1/3] 检查编译工具..."

need_install=0
for tool in clang ldid make; do
    if ! command -v $tool &> /dev/null; then
        echo "  缺少: $tool"
        need_install=1
    else
        echo "  已安装: $tool ($($tool --version 2>&1 | head -1))"
    fi
done

# 检查theos
if [ -z "$THEOS" ]; then
    export THEOS=/var/theos
fi
if [ ! -d "$THEOS" ]; then
    echo "  缺少: theos"
    need_install=1
else
    echo "  已安装: theos ($THEOS)"
fi

# 检查iOS SDK
SDK=$(ls -d $THEOS/sdks/iPhoneOS*.sdk 2>/dev/null | head -1)
if [ -z "$SDK" ]; then
    echo "  缺少: iOS SDK"
    need_install=1
else
    echo "  已安装: iOS SDK ($SDK)"
fi

if [ $need_install -eq 1 ]; then
    echo ""
    echo "[信息] 正在安装依赖（通过Procursus）..."
    apt-get update
    apt-get install -y clang ldid make coreutils
    # 安装theos
    if [ ! -d "$THEOS" ]; then
        git clone --recursive https://github.com/theos/theos.git "$THEOS"
    fi
    # 安装iOS SDK
    if [ -z "$SDK" ]; then
        echo "[信息] 下载iOS 16.5 SDK..."
        curl -L -o /tmp/sdks.zip "https://github.com/xybp888/iOS-SDKs/archive/refs/heads/master.zip"
        unzip -q /tmp/sdks.zip -d /tmp/sdks_src
        cp -r /tmp/sdks_src/iOS-SDKs-master/iPhoneOS16.5.sdk "$THEOS/sdks/" 2>/dev/null || \
        cp -r /tmp/sdks_src/iOS-SDKs-master/iPhoneOS16.4.sdk "$THEOS/sdks/" 2>/dev/null
        rm -rf /tmp/sdks_src /tmp/sdks.zip
    fi
    echo "[信息] 依赖安装完成"
fi

SDK=$(ls -d $THEOS/sdks/iPhoneOS*.sdk | head -1)
echo "  使用SDK: $SDK"
echo ""

# ========== 2. 编译 ==========
echo "[2/3] 编译..."

# 编译Tweak
echo "  编译 Tweak.dylib..."
cd Tweak
make clean package FINALPACKAGE=1 2>&1 | tail -5
if [ ! -f .theos/obj/debug/AisiMonitor.dylib ]; then
    echo "[错误] Tweak.dylib编译失败"
    exit 1
fi
echo "  -> Tweak.dylib OK"
cd ..

# 编译helper
echo "  编译 root helper..."
clang -arch arm64 -isysroot "$SDK" \
    -o helper/aisi_helper \
    helper/helper.c \
    -framework Foundation -framework IOKit \
    -O2 -Wno-deprecated-declarations
chmod 6755 helper/aisi_helper
echo "  -> aisi_helper OK (setuid root)"

# 编译App
echo "  编译 AisiSpy App..."
make clean package FINALPACKAGE=1 2>&1 | tail -5

APP_PATH=$(find .theos -name "AisiSpy.app" -type d 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    APP_PATH=$(find $THEOS -name "AisiSpy.app" -type d 2>/dev/null | head -1)
fi
if [ -z "$APP_PATH" ]; then
    echo "[错误] 未找到AisiSpy.app"
    find . -name "*.app" -type d 2>/dev/null
    exit 1
fi
echo "  -> App OK: $APP_PATH"

# ========== 3. 打包IPA ==========
echo "[3/3] 打包 IPA..."

rm -rf build
mkdir -p build/Payload
cp -R "$APP_PATH" build/Payload/AisiSpy.app

# 放入helper和tweak
cp helper/aisi_helper build/Payload/AisiSpy.app/
cp Tweak/.theos/obj/debug/AisiMonitor.dylib build/Payload/AisiSpy.app/
chmod 6755 build/Payload/AisiSpy.app/aisi_helper
chmod 755 build/Payload/AisiSpy.app/AisiMonitor.dylib

# 签名
ldid -SResources/entitlements.plist build/Payload/AisiSpy.app/AisiSpy
ldid -SResources/entitlements.plist build/Payload/AisiSpy.app/aisi_helper
cp Resources/Info.plist build/Payload/AisiSpy.app/Info.plist

# 打包
cd build
zip -qr ../AisiSpy.ipa Payload/
cd ..
cp AisiSpy.ipa AisiSpy.tipa

echo ""
echo "============================================"
echo "  编译完成!"
echo "============================================"
echo "  IPA:  $(pwd)/AisiSpy.ipa"
echo "  TIPA: $(pwd)/AisiSpy.tipa"
echo ""
echo "  大小: $(du -h AisiSpy.ipa | cut -f1)"
echo ""
echo "安装方法:"
echo "  1. 用Filza找到 AisiSpy.ipa"
echo "  2. 点击用TrollStore打开"
echo "  3. 安装后桌面出现AisiSpy"
echo "============================================"
