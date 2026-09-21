//! 会话持久化：最近打开的文件夹、上次阅读位置、每篇文档的滚动比例、主题。
//! 存 JSON 于应用配置目录，原子写入（先写临时文件再改名）。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RootRef {
    pub kind: String, // "fs" | "saf"
    pub loc: String,  // fs: 目录绝对路径；saf: 目录树 Uri
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub recent_roots: Vec<RootRef>,
    pub last_root: Option<RootRef>,
    pub last_file: Option<String>,
    /// key = "rootloc|filepath" → 滚动比例 0..1
    pub file_positions: HashMap<String, f32>,
    /// "light" | "dark" | null（null=跟随系统）
    pub theme: Option<String>,
    /// 正文字号 px（null=默认 15）
    pub font_size: Option<u32>,
    /// 文件树排序方式（null=name-asc）
    pub sort_mode: Option<String>,
}

impl Default for Session {
    fn default() -> Self {
        Session {
            recent_roots: Vec::new(),
            last_root: None,
            last_file: None,
            file_positions: HashMap::new(),
            theme: None,
            font_size: None,
            sort_mode: None,
        }
    }
}

pub fn session_path(cfg_dir: &PathBuf) -> PathBuf {
    cfg_dir.join("session.json")
}

pub fn load(cfg_dir: &PathBuf) -> Session {
    let path = session_path(cfg_dir);
    let Ok(text) = std::fs::read_to_string(path) else {
        return Session::default();
    };
    serde_json::from_str(&text).unwrap_or_default()
}

pub fn save(cfg_dir: &PathBuf, session: &Session) -> Result<(), String> {
    let dir = cfg_dir.clone();
    if let Err(e) = std::fs::create_dir_all(&dir) {
        return Err(e.to_string());
    }
    let path = session_path(&dir);
    let tmp = dir.join("session.json.tmp");
    let Ok(json) = serde_json::to_string_pretty(session) else {
        return Err("序列化失败".into());
    };
    if let Err(e) = std::fs::write(&tmp, json) {
        return Err(e.to_string());
    }
    if let Err(e) = std::fs::rename(&tmp, &path) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e.to_string());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_roundtrip() {
        let dir = std::env::temp_dir().join(format!("mdreader_sess_{}", std::process::id()));
        let mut s = Session::default();
        s.recent_roots.push(RootRef {
            kind: "fs".into(),
            loc: "C:/docs".into(),
        });
        s.last_file = Some("C:/docs/a.md".into());
        s.file_positions
            .insert("C:/docs|C:/docs/a.md".into(), 0.42);
        save(&dir, &s).unwrap();
        let l = load(&dir);
        assert_eq!(l.recent_roots.len(), 1);
        assert_eq!(l.last_file.as_deref(), Some("C:/docs/a.md"));
        assert_eq!(l.file_positions["C:/docs|C:/docs/a.md"], 0.42);
        let _ = std::fs::remove_dir_all(&dir);
    }
}