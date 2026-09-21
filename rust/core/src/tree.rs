//! 目录扫描：递归收集文件夹与 .md 文件，排序输出。
use serde::Serialize;
use std::cmp::Ordering;
use std::path::Path;

/// 常见噪音目录，扫描时跳过（不显示在侧边栏）
pub const SKIP_DIRS: &[&str] = &[
    ".git", ".svn", ".hg", ".idea", ".vscode", "node_modules", "target", "dist", "build",
    "out", ".next", ".cache", "__pycache__", ".obsidian", ".trash",
];

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TreeNode {
    pub name: String,
    pub path: String, // 标准化正斜杠路径
    pub kind: String, // "dir" | "file"
    pub size: u64,    // 字节；目录为 0
    pub mtime: u64,   // 毫秒时间戳
    #[serde(skip_serializing_if = "Option::is_none")]
    pub children: Option<Vec<TreeNode>>,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Tree {
    pub name: String,
    pub path: String, // 根路径（正斜杠）
    pub md_count: u64,
    pub children: Vec<TreeNode>,
}

pub fn is_md_file(name: &str) -> bool {
    let lower = name.to_lowercase();
    lower.ends_with(".md") || lower.ends_with(".markdown")
}

fn norm(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn is_skipped_dir(name: &str) -> bool {
    name.starts_with('.') || SKIP_DIRS.contains(&name)
}

/// 扫描一个目录（非递归，单层），返回该目录下所有 md 文件的总大小（用于"按大小"排序文件夹）
fn scan_dir(dir: &Path, nodes: &mut Vec<TreeNode>) -> u64 {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return 0;
    };
    let mut subtree_size = 0u64;
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        let meta = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if meta.is_dir() {
            if is_skipped_dir(&name) {
                continue;
            }
            let mut children = Vec::new();
            let sub_size = scan_dir(&path, &mut children);
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            subtree_size += sub_size;
            nodes.push(TreeNode {
                name,
                path: norm(&path),
                kind: "dir".into(),
                size: sub_size, // 文件夹大小 = 子树文件总大小
                mtime,
                children: Some(children),
            });
        } else if meta.is_file() && is_md_file(&name) {
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            subtree_size += meta.len();
            nodes.push(TreeNode {
                name,
                path: norm(&path),
                kind: "file".into(),
                size: meta.len(),
                mtime,
                children: None,
            });
        }
    }
    // 排序：文件夹在前，其次按小写名称
    nodes.sort_by(|a, b| match (a.kind.as_str(), b.kind.as_str()) {
        ("dir", "dir") | ("file", "file") => cmp_name(&a.name, &b.name),
        ("dir", "file") => Ordering::Less,
        _ => Ordering::Greater,
    });
    subtree_size
}

fn cmp_name(a: &str, b: &str) -> Ordering {
    natural_cmp(a, b)
}

/// 把字符串拆成 数字块 / 文本块 交替的 token
fn tokens(s: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut cur_is_digit = false;
    for c in s.chars() {
        let is_digit = c.is_ascii_digit();
        if cur.is_empty() {
            cur.push(c);
            cur_is_digit = is_digit;
        } else if is_digit == cur_is_digit {
            cur.push(c);
        } else {
            out.push(std::mem::take(&mut cur));
            cur.push(c);
            cur_is_digit = is_digit;
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// 数字串按数值比较（忽略前导零）
fn cmp_numeric(a: &str, b: &str) -> Ordering {
    let na = a.trim_start_matches('0');
    let nb = b.trim_start_matches('0');
    let (na, nb) = (if na.is_empty() { "0" } else { na }, if nb.is_empty() { "0" } else { nb });
    na.len().cmp(&nb.len()).then_with(|| na.cmp(nb))
}

/// 自然排序：数字块按数值、文本块按字母（1. 2. 3. 10. 而不是 1. 10. 2. 3.）
fn natural_cmp(a: &str, b: &str) -> Ordering {
    let ta = tokens(a);
    let tb = tokens(b);
    let len = ta.len().min(tb.len());
    for i in 0..len {
        let x = &ta[i];
        let y = &tb[i];
        let xd = x.chars().all(|c| c.is_ascii_digit());
        let yd = y.chars().all(|c| c.is_ascii_digit());
        let ord = if xd && yd {
            cmp_numeric(x, y)
        } else if xd != yd {
            if xd {
                Ordering::Less
            } else {
                Ordering::Greater
            }
        } else {
            x.to_lowercase().cmp(&y.to_lowercase()).then_with(|| x.cmp(y))
        };
        if ord != Ordering::Equal {
            return ord;
        }
    }
    ta.len().cmp(&tb.len())
}

fn count_md(nodes: &[TreeNode]) -> u64 {
    nodes.iter().fold(0u64, |acc, n| {
        acc
            + if n.kind == "file" {
                1
            } else {
                n.children.as_deref().map(count_md).unwrap_or(0)
            }
    })
}

/// 扫描根目录，返回完整树
pub fn scan(root: &str) -> Tree {
    let root_path = Path::new(root);
    let name = root_path
        .file_name()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| root.to_string());
    let mut children = Vec::new();
    let _ = scan_dir(root_path, &mut children);
    let md_count = count_md(&children);
    Tree {
        name,
        path: norm(root_path),
        md_count,
        children,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scan_filters_and_sorts() {
        let base = std::env::temp_dir().join(format!("mdreader_test_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("b_dir")).unwrap();
        std::fs::create_dir_all(base.join("a_dir")).unwrap();
        std::fs::create_dir_all(base.join("node_modules")).unwrap();
        std::fs::create_dir_all(base.join(".hidden")).unwrap();
        std::fs::write(base.join("b.md"), "# b").unwrap();
        std::fs::write(base.join("a.md"), "# a").unwrap();
        std::fs::write(base.join("note.txt"), "no").unwrap();
        let tree = scan(base.to_string_lossy().as_ref());
        assert_eq!(tree.md_count, 2);
        let kinds: Vec<&str> = tree.children.iter().map(|n| n.kind.as_str()).collect();
        // 目录在前、文件在后；目录按名排序
        assert_eq!(kinds[0..2], ["dir", "dir"]);
        assert_eq!(tree.children[0].name, "a_dir");
        assert_eq!(tree.children[1].name, "b_dir");
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn natural_sort_numbers_in_order() {
        // 1. 2. 3. 10. 而不是 1. 10. 2. 3.
        let mut names = vec![
            "10. 总结.md",
            "2. 周报.md",
            "1. 方案.md",
            "3. 笔记.md",
            "11. 附录.md",
        ];
        names.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(
            names,
            vec![
                "1. 方案.md",
                "2. 周报.md",
                "3. 笔记.md",
                "10. 总结.md",
                "11. 附录.md",
            ]
        );
    }

    #[test]
    fn natural_sort_mixed_prefixes() {
        let mut names = vec!["b2.md", "b10.md", "a1.md", "a2.md", "B1.md"];
        names.sort_by(|a, b| natural_cmp(a, b));
        // 大小写不敏感："B1"≈"b1" 排在 "b2" 前；数字按数值：b2 < b10
        assert_eq!(names, vec!["a1.md", "a2.md", "B1.md", "b2.md", "b10.md"]);
    }

    #[test]
    fn dir_size_is_subtree_total() {
        // 文件夹的 size 应等于其内所有 md 文件大小之和（供"按大小"排序）
        let base = std::env::temp_dir().join(format!("mdreader_size_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(base.join("子目录A")).unwrap();
        std::fs::create_dir_all(base.join("子目录B").join("嵌套")).unwrap();
        std::fs::write(base.join("子目录A").join("a.md"), vec![b'x'; 100]).unwrap();
        std::fs::write(base.join("子目录A").join("b.md"), vec![b'x'; 50]).unwrap();
        std::fs::write(base.join("子目录B").join("嵌套").join("c.md"), vec![b'x'; 30]).unwrap();
        let tree = scan(base.to_string_lossy().as_ref());
        let dir_a = tree.children.iter().find(|n| n.name == "子目录A").unwrap();
        assert_eq!(dir_a.size, 150, "子目录A 应等于 100+50");
        let dir_b = tree.children.iter().find(|n| n.name == "子目录B").unwrap();
        assert_eq!(dir_b.size, 30, "子目录B 应等于嵌套里的 30");
        let _ = std::fs::remove_dir_all(&base);
    }
}