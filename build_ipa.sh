#!/bin/bash
# 在 Mac 上一键产出「未签名 IPA」，直接用巨魔商店（TrollStore）安装，永不过期。
# 用法：把整个「问爻-iPhone导航App」目录拷到 Mac，终端里执行 bash build_ipa.sh
set -e
cd "$(dirname "$0")"

# NOTE: -target builds must NOT pass -destination (xcodebuild rejects the mix).
xcodebuild -project WenYaoNav.xcodeproj \
  -target WenYaoNav \
  -configuration Release \
  -sdk iphoneos \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  -derivedDataPath build \
  clean build

APP="$(find build/Build/Products -maxdepth 4 -type d -name 'WenYaoNav.app' -print -quit)"
if [ -z "$APP" ]; then echo "找不到 WenYaoNav.app"; exit 1; fi
echo "构建产物：$APP"

rm -rf Payload WenYaoNav-unsigned.ipa
mkdir Payload
cp -R "$APP" Payload/
# TrollStore/installd 需要代码签名目录，ad-hoc 签名即可
codesign -s - --force --deep "Payload/WenYaoNav.app" || echo "ad-hoc 签名失败，继续"
zip -qry WenYaoNav-unsigned.ipa Payload
ls -lh WenYaoNav-unsigned.ipa

echo "完成：WenYaoNav-unsigned.ipa"
echo "把这个 IPA 传到 iPhone，用巨魔商店打开安装即可（无需签名、无需 Apple ID）。"
