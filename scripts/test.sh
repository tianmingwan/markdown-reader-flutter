#!/usr/bin/env bash
# 全量测试：Rust core 单测 + Dart/Flutter 测试
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
echo "== Rust core 单元测试 =="
cargo test --manifest-path "$here/rust/core/Cargo.toml" --release
echo
echo "== Flutter / Dart 测试 =="
"$here/scripts/build-rust.sh" >/dev/null
cd "$here"
flutter test --concurrency=1
