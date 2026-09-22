#!/usr/bin/env bash
# 构造 Linux deb 安装包（需先 flutter build linux --release）
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
ARCH="amd64"
BUILD="$here/build/linux/x64/release/bundle"
[ -d "$BUILD" ] || { echo "缺少 $BUILD，请先执行 flutter build linux --release" >&2; exit 1; }

WORK="$(mktemp -d)"
ROOT="$WORK/mdreader-flutter_${VERSION}_${ARCH}"
mkdir -p "$ROOT/DEBIAN" "$ROOT/opt/mdreader-flutter" "$ROOT/usr/bin" \
  "$ROOT/usr/share/applications" \
  "$ROOT/usr/share/icons/hicolor/128x128/apps" \
  "$ROOT/usr/share/icons/hicolor/256x256/apps"

cp -r "$BUILD"/* "$ROOT/opt/mdreader-flutter/"
ln -s /opt/mdreader-flutter/mdreader_flutter "$ROOT/usr/bin/mdreader-flutter"
cp "$here/assets/icon-128.png" "$ROOT/usr/share/icons/hicolor/128x128/apps/mdreader-flutter.png"
cp "$here/assets/icon-256.png" "$ROOT/usr/share/icons/hicolor/256x256/apps/mdreader-flutter.png"

cat > "$ROOT/usr/share/applications/mdreader-flutter.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Markdown阅读器 (Flutter)
Name[zh_CN]=Markdown阅读器 (Flutter)
Comment=打开即预览的 Markdown 阅读器 · Flutter + Rust
Exec=/opt/mdreader-flutter/mdreader_flutter %U
Icon=mdreader-flutter
Terminal=false
Categories=Office;Viewer;
MimeType=text/markdown;text/x-markdown;
StartupNotify=true
StartupWMClass=mdreader_flutter
DESKTOP

SIZE_KB=$(du -sk "$ROOT/opt" | awk '{print $1}')
cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: mdreader-flutter
Version: $VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Installed-Size: $SIZE_KB
Depends: libgtk-3-0 | libgtk-3-0t64, libblkid1, liblzma5, libepoxy0, libegl1, libgles2, libfontconfig1, libfreetype6, libharfbuzz0b, libcairo2, libpango-1.0-0, libx11-6, libwebkit2gtk-4.1-0
Maintainer: YG <aakb@localhost>
Homepage: https://github.com/tianmingwan/markdown-reader-flutter
Description: Markdown 阅读器（Flutter 重构版）
 打开即预览的 Markdown 阅读器：Rust 核心（markdown 解析 / syntect 高亮 /
 目录扫描 / 全文搜索）+ Flutter UI。
 .
 支持大文档虚拟滚动、多标签、折叠答案（details）、主题与字号、会话记忆，
 以及右侧 AI 搜索分栏（内嵌 DeepSeek 网页版，登录态本地保存）。
CONTROL

cat > "$ROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database -q /usr/share/applications || true
fi
exit 0
POSTINST
chmod 755 "$ROOT/DEBIAN/postinst"

mkdir -p "$here/dist"
OUT="$here/dist/mdreader-flutter_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "$ROOT" "$OUT" >/dev/null
echo "已生成 $OUT"
ls -la "$OUT"
rm -rf "$WORK"
