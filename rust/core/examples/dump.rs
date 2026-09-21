//! 临时调试用：把 markdown 渲染成 HTML 输出到文件（性能诊断 harness 使用）。
//! 用法：cargo run --release --example dump -- <input.md> <output.html>
use std::fs;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let input = &args[1];
    let output = &args[2];
    let source = fs::read_to_string(input).expect("read input");
    let base = std::path::Path::new(input)
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_default();
    let r = mdreader_core::md::render(&source, &base, false, None);
    fs::write(output, &r.html).expect("write output");
    eprintln!(
        "src={} bytes -> html={} bytes, words={}, math={}, mermaid={}",
        source.len(),
        r.html.len(),
        r.words,
        r.has_math,
        r.has_mermaid
    );
}
