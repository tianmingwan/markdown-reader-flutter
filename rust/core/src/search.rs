//! 全文搜索：按文件名 + 文件内容匹配，内容搜索在后台线程执行、限制文件大小与结果数。
use serde::Serialize;
use std::path::Path;

use crate::tree::{is_md_file, SKIP_DIRS};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub path: String, // 标准化正斜杠路径
    pub name: String,
    pub matched_by: String, // "name" | "content"
    pub snippets: Vec<String>,
}

const MAX_READ_BYTES: u64 = 1024 * 1024; // 单个文件最多读 1MB
const MAX_HITS: usize = 200;
const MAX_SNIPPETS: usize = 2;
const SNIPPET_LEN: usize = 80;

/// 把字节偏移对齐到最近的 UTF-8 字符边界（向前找）
fn char_boundary(text: &str, byte_idx: usize) -> usize {
    if byte_idx >= text.len() {
        return text.len();
    }
    if text.is_char_boundary(byte_idx) {
        byte_idx
    } else {
        let mut i = byte_idx;
        while i > 0 && !text.is_char_boundary(i) {
            i -= 1;
        }
        i
    }
}

/// 从匹配位置周围截取摘要（字符边界安全，兼容中文等多字节文本）
fn snippet_around(text: &str, match_idx: usize, match_len: usize) -> String {
    let start = char_boundary(text, match_idx.saturating_sub(SNIPPET_LEN / 2));
    let end = char_boundary(text, (match_idx + match_len + SNIPPET_LEN / 2 + 10).min(text.len()));
    let mut out = String::new();
    if start > 0 {
        out.push('…');
    }
    out.push_str(&text[start..end].trim().chars().take(SNIPPET_LEN).collect::<String>());
    if end < text.len() {
        out.push('…');
    }
    out
}

fn norm(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

/// 在 root 下搜索 query（大小写不敏感）
pub fn search(root: &str, query: &str) -> Vec<SearchHit> {
    let q = query.trim().to_lowercase();
    let mut hits: Vec<SearchHit> = Vec::new();

    if q.is_empty() {
        return hits;
    }
    let min_content_len = 2; // 内容搜索至少 2 个字符，避免噪音

    let walker = ignore::WalkBuilder::new(root)
        .hidden(true)
        .filter_entry(|entry| {
            if entry.depth() == 0 {
                return true;
            }
            let name = entry.file_name().to_string_lossy();
            !(entry.file_type().map(|t| t.is_dir()).unwrap_or(false) && SKIP_DIRS.contains(&name.as_ref()))
        })
        .build();

    for entry in walker.flatten() {
        if hits.len() >= MAX_HITS {
            break;
        }
        let path = entry.path();
        if path.is_dir() {
            continue;
        }
        let Some(name) = path.file_name().map(|s| s.to_string_lossy().into_owned()) else {
            continue;
        };
        if !is_md_file(&name) {
            continue;
        }
        let path_str = norm(path);

        if name.to_lowercase().contains(&q) {
            hits.push(SearchHit {
                path: path_str,
                name,
                matched_by: "name".into(),
                snippets: vec![],
            });
            continue;
        }

        if q.chars().count() < min_content_len {
            continue;
        }

        // 内容匹配
        let meta = match path.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if meta.len() > MAX_READ_BYTES {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(path) else {
            continue;
        };
        let lower = text.to_lowercase();
        let mut snippets = Vec::new();
        let mut search_from = 0usize;
        while let Some(rel) = lower[search_from..].find(&q) {
            let idx = search_from + rel;
            let snippet = snippet_around(&text, idx, q.len());
            snippets.push(snippet);
            search_from = idx + q.len();
            if snippets.len() >= MAX_SNIPPETS {
                break;
            }
        }
        if !snippets.is_empty() {
            hits.push(SearchHit {
                path: path_str,
                name,
                matched_by: "content".into(),
                snippets,
            });
        }
    }

    hits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_finds_by_name_and_content() {
        let base = std::env::temp_dir().join(format!("mdreader_search_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        std::fs::write(base.join("计划.md"), "# 项目计划\n明天去爬山\n").unwrap();
        std::fs::write(base.join("notes.md"), "什么都没有\n").unwrap();
        let root = base.to_string_lossy().replace('\\', "/");

        let by_name = search(&root, "计划");
        assert!(by_name.iter().any(|h| h.matched_by == "name"));

        let by_content = search(&root, "爬山");
        assert!(
            by_content
                .iter()
                .any(|h| h.matched_by == "content" && !h.snippets.is_empty())
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn search_chinese_content_in_subfolder_no_panic() {
        // 复现原 bug：中文文本 + 匹配位置较深时，字节切片越界会 panic
        let base = std::env::temp_dir().join(format!("mdreader_search_cn_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("子目录")).unwrap();
        let mut long_text = String::new();
        for i in 0..60 {
            long_text.push_str(&format!("第{}章：这是一个用来凑长度的中文句子。\n", i));
        }
        long_text.push_str("这里藏着一个关键词：量子力学。\n");
        std::fs::write(base.join("子目录").join("笔记.md"), &long_text).unwrap();
        let root = base.to_string_lossy().replace('\\', "/");

        let hits = search(&root, "量子力学");
        assert!(
            hits.iter().any(|h| h.matched_by == "content" && !h.snippets.is_empty()),
            "应在子目录 md 中搜到中文内容"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn snippet_never_panics_on_multibyte() {
        let text = "中文中文中文中文中文中文中文中文中文".repeat(10) + "目标词" + &"中文".repeat(20);
        let idx = text.find("目标词").unwrap();
        let s = snippet_around(&text, idx, "目标词".len());
        assert!(s.contains("目标词"));
    }
}