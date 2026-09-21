#!/usr/bin/env bash
# 一键：重建 Rust core → 构建 Flutter Linux release → 运行（可传 MDREADER_* 环境变量）
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
"$here/scripts/build-rust.sh"
cd "$here"
flutter build linux --release
exec "$here/build/linux/x64/release/bundle/mdreader_flutter" "$@"
