#!/usr/bin/env bash
# 构建 Rust core（cdylib）并放到 native/，供 flutter build 打进 bundle/lib。
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$here/native"
cd "$here/rust/core"
cargo build --release
cp target/release/libmdreader_core.so "$here/native/"
echo "已更新 native/libmdreader_core.so"
