#!/bin/bash
# mac_repack.sh — 在 Apple Silicon Mac 上一键完成：
#   1. 编译 arm64 iOS dylib（本地，不经 CI）
#   2. 注入脱壳 IPA → build/bili-universal-accelerated.ipa（设备侧载用）
#   3. 额外产出 build/mac-run/ 下的重签 .app（Apple Silicon Mac 直接运行用）
#
# 用法: ./tools/mac_repack.sh [ipa路径]
# 依赖: Xcode (xcode-select -s /Applications/Xcode.app/Contents/Developer)
set -euo pipefail
cd "$(dirname "$0")/.."

IPA="${1:-../哔哩哔哩-弹幕番剧直播高清视频_9.12.0.ipa}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
ENT="tools/mac_run.entitlements.plist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== [1/4] 编译 dylib (arm64 iOS) =="
clang -arch arm64 -miphoneos-version-min=13.0 -shared -fobjc-arc -O2 \
  -framework Foundation -isysroot "$SDK" \
  -o build/BiliAccelerator.dylib src/Tweak.m
codesign --force -s - build/BiliAccelerator.dylib
file build/BiliAccelerator.dylib

echo "== [2/4] 注入 IPA（设备侧载用，侧载工具会重签） =="
python3 tools/repack.py "$IPA" build/BiliAccelerator.dylib \
  -o build/bili-universal-accelerated.ipa

echo "== [3/4] 准备 Mac 直跑 .app =="
MACRUN=build/mac-run
rm -rf "$MACRUN" && mkdir -p "$MACRUN"
unzip -q "$IPA" -d "$WORK/payload"
APP="$(ls -d "$WORK/payload"/*.app | head -1)"
cp -R "$APP" "$MACRUN/"
APPNAME="$(basename "$APP")"
EXE="$(plutil -extract CFBundleExecutable raw -o - "$MACRUN/$APPNAME/Info.plist")"

echo "== [4/4] Mac 直跑：注入 + ad-hoc 重签 =="
python3 tools/inject_dylib.py \
  -i "$MACRUN/$APPNAME/$EXE" -o "$WORK/exe_injected" \
  --dylib "@executable_path/Frameworks/BiliAccelerator.dylib"
mv "$WORK/exe_injected" "$MACRUN/$APPNAME/$EXE"
chmod 755 "$MACRUN/$APPNAME/$EXE"
mkdir -p "$MACRUN/$APPNAME/Frameworks"
cp build/BiliAccelerator.dylib "$MACRUN/$APPNAME/Frameworks/"

# 主二进制 + dylib 都用同一组 entitlements ad-hoc 重签（含 lldb/get-task-allow）
codesign --force -s - --entitlements "$ENT" --generate-entitlement-der \
  "$MACRUN/$APPNAME/Frameworks/BiliAccelerator.dylib"
codesign --force -s - --entitlements "$ENT" --generate-entitlement-der \
  "$MACRUN/$APPNAME/$EXE"
# 每个内嵌 framework 也要重签，否则 Mac 上 library validation 拒载
find "$MACRUN/$APPNAME" -name "*.framework" -o -name "*.dylib" | while read -r fw; do
  codesign --force -s - --generate-entitlement-der "$fw" || true
done
# 主 bundle 最后签
codesign --force -s - --entitlements "$ENT" --generate-entitlement-der "$MACRUN/$APPNAME"

echo ""
echo "完成。两条路径："
echo "  设备侧载 IPA : build/bili-universal-accelerated.ipa"
echo "  Mac 直跑 App : 把 $MACRUN/$APPNAME 拖到 /Applications 后 open 启动"
echo "  调参（Mac 直跑）: 终端直接跑二进制，例："
echo "    BiliAcc_verbose=1 BiliAcc_mode=force \\"
echo "    \"$MACRUN/$APPNAME/$EXE\""
