#!/bin/bash
# sign_device.sh — 用用户提供的 p12 + 描述文件 给重打包 IPA 签名并安装真机
# 用法: ./tools/sign_device.sh <ipa> <p12> <p12密码> <mobileprovision> <bundle-id>
set -euo pipefail
cd "$(dirname "$0")/.."

IPA="$1"; P12="$2"; P12PASS="$3"; PROFILE="$4"; NEW_BID="$5"
IDENT="iPhone Distribution"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
KC="/tmp/bili_sign.keychain"
KCPASS="biliacc123"

echo "== [1/6] 准备钥匙串 =="
security create-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
security unlock-keychain -p "$KCPASS" "$KC"
security import "$P12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign 2>/dev/null || true
security set-key-partition-list -S apple-tool:,apple: -k "$KCPASS" "$KC" >/dev/null 2>&1
IDENTITY=$(security find-identity -v -p codesigning "$KC" | grep -oE '[A-F0-9]{40}' | head -1)
[ -n "${IDENTITY:-}" ] || { echo "no signing identity in $KC"; exit 1; }
echo "identity hash: $IDENTITY"
# codesign 默认只搜索默认钥匙串链，临时钥匙串必须加入搜索链
security list-keychains -s "$KC" $(security list-keychains | tr '\n' ' ')

echo "== [2/6] 解包 IPA =="
rm -rf "$WORK/payload" && mkdir -p "$WORK/payload"
unzip -q "$IPA" -d "$WORK/payload"
APP="$(ls -d "$WORK/payload/Payload"/*.app | head -1)"

echo "== [3/6] 改写 bundle id -> $NEW_BID + 去扩展 + 嵌入 profile =="
plutil -replace CFBundleIdentifier -string "$NEW_BID" "$APP/Info.plist"
if [ -d "$APP/PlugIns" ]; then rm -rf "$APP/PlugIns"; echo "  removed PlugIns"; fi
# 去掉 watch/watchkit 关联（profile 只授权主 App）
rm -rf "$APP/Watch" "$APP/WatchKit" 2>/dev/null || true
cp "$PROFILE" "$APP/embedded.mobileprovision"
# 提取 profile 的 entitlements 作为签名权限
security cms -D -i "$PROFILE" > "$WORK/profile.plist"
plutil -extract Entitlements xml1 -o "$WORK/ents.plist" "$WORK/profile.plist"

echo "== [4/6] 签名（内层→外层）=="
while IFS= read -r -d '' bin; do
  codesign --force --sign "$IDENTITY" --entitlements "$WORK/ents.plist" \
    --generate-entitlement-der --keychain "$KC" "$bin" 2>&1 | grep -v "replacing" || true
done < <(find "$APP/Frameworks" -type f \( -name "*.dylib" -o -path "*.framework/*" -name "$(plutil -extract CFBundleExecutable raw -o - "$APP/Frameworks"/*.framework/Info.plist 2>/dev/null | head -1)" \) -print0 2>/dev/null)
find "$APP/Frameworks" -name "*.dylib" -exec codesign --force --sign "$IDENTITY" \
  --entitlements "$WORK/ents.plist" --generate-entitlement-der --keychain "$KC" {} \; 2>/dev/null
find "$APP/Frameworks" -maxdepth 1 -name "*.framework" -exec codesign --force --sign "$IDENTITY" \
  --entitlements "$WORK/ents.plist" --generate-entitlement-der --keychain "$KC" {} \; 2>/dev/null
EXE=$(plutil -extract CFBundleExecutable raw -o - "$APP/Info.plist")
codesign --force --sign "$IDENTITY" --entitlements "$WORK/ents.plist" \
  --generate-entitlement-der --keychain "$KC" "$APP/$EXE"
codesign --force --sign "$IDENTITY" --entitlements "$WORK/ents.plist" \
  --generate-entitlement-der --keychain "$KC" "$APP"
codesign --verify "$APP" && echo "  VERIFY OK"

echo "== [5/6] 重新打包 IPA =="
OUT="build/$(basename "${IPA%.ipa}")-signed.ipa"
( cd "$WORK/payload" && zip -q -r "/$OLDPWD/$OUT" Payload )
echo "  $OUT"

echo "== [6/6] 完成 =="
echo "$OUT"
