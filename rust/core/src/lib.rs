//! mdreader 核心逻辑库：目录扫描、markdown 渲染、全文搜索、会话持久化。
//! 不依赖 Tauri，纯 Rust 单元测试在此运行（`cargo test -p mdreader-core`）。

pub mod md;
pub mod search;
pub mod session;
pub mod tree;
pub mod blocks;
pub mod ffi;
