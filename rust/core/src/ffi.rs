//! Flutter / Dart FFI 导出层（验证用）。
//! 设计：入参 C 字符串，返回值 = serde_json JSON 字符串指针，由调用方 free。
use std::ffi::{c_char, CStr, CString};

fn cstr(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned())
}

fn to_c(s: String) -> *mut c_char {
    CString::new(s)
        .map(|c| c.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

/// 渲染 markdown。返回 RenderedMd 的 JSON。
#[no_mangle]
pub extern "C" fn mdreader_render_md(
    source: *const c_char,
    base_dir: *const c_char,
    dark: i32,
) -> *mut c_char {
    let (Some(src), Some(base)) = (cstr(source), cstr(base_dir)) else {
        return std::ptr::null_mut();
    };
    let r = crate::md::render(&src, &base, dark != 0, None);
    match serde_json::to_string(&r) {
        Ok(s) => to_c(s),
        Err(_) => std::ptr::null_mut(),
    }
}

/// 目录扫描。返回 Tree 的 JSON。
#[no_mangle]
pub extern "C" fn mdreader_scan_tree(root: *const c_char) -> *mut c_char {
    let Some(r) = cstr(root) else {
        return std::ptr::null_mut();
    };
    match serde_json::to_string(&crate::tree::scan(&r)) {
        Ok(s) => to_c(s),
        Err(_) => std::ptr::null_mut(),
    }
}

/// 全文搜索。返回 Vec<SearchHit> 的 JSON。
#[no_mangle]
pub extern "C" fn mdreader_search(root: *const c_char, query: *const c_char) -> *mut c_char {
    let (Some(r), Some(q)) = (cstr(root), cstr(query)) else {
        return std::ptr::null_mut();
    };
    match serde_json::to_string(&crate::search::search(&r, &q)) {
        Ok(s) => to_c(s),
        Err(_) => std::ptr::null_mut(),
    }
}

/// 释放 Rust 侧分配的字符串。
#[no_mangle]
pub extern "C" fn mdreader_free_string(p: *mut c_char) {
    if !p.is_null() {
        unsafe {
            drop(CString::from_raw(p));
        }
    }
}

/// 结构化渲染（Flutter 用）。返回 RenderedDoc 的 JSON。
#[no_mangle]
pub extern "C" fn mdreader_render_blocks(
    source: *const c_char,
    base_dir: *const c_char,
    dark: i32,
) -> *mut c_char {
    let (Some(src), Some(base)) = (cstr(source), cstr(base_dir)) else {
        return std::ptr::null_mut();
    };
    let doc = crate::blocks::render_blocks(&src, &base, dark != 0);
    match serde_json::to_string(&doc) {
        Ok(s) => to_c(s),
        Err(_) => std::ptr::null_mut(),
    }
}

/// 读取会话（cfg_dir 为配置目录绝对路径）。返回 Session 的 JSON。
#[no_mangle]
pub extern "C" fn mdreader_session_load(cfg_dir: *const c_char) -> *mut c_char {
    let Some(dir) = cstr(cfg_dir) else {
        return std::ptr::null_mut();
    };
    let s = crate::session::load(&std::path::PathBuf::from(dir));
    match serde_json::to_string(&s) {
        Ok(t) => to_c(t),
        Err(_) => std::ptr::null_mut(),
    }
}

/// 保存会话。json 为 Session 的 JSON。返回 1 成功 / 0 失败。
#[no_mangle]
pub extern "C" fn mdreader_session_save(cfg_dir: *const c_char, json: *const c_char) -> i32 {
    let (Some(dir), Some(js)) = (cstr(cfg_dir), cstr(json)) else {
        return 0;
    };
    match serde_json::from_str::<crate::session::Session>(&js) {
        Ok(s) => match crate::session::save(&std::path::PathBuf::from(dir), &s) {
            Ok(_) => 1,
            Err(_) => 0,
        },
        Err(_) => 0,
    }
}

/// 直接读文件并结构化渲染（省掉 Dart 侧读文件 + 跨边界传整篇源文本）。
/// 文件不存在或读取失败返回 null。
#[no_mangle]
pub extern "C" fn mdreader_render_file(path: *const c_char, dark: i32) -> *mut c_char {
    let Some(p) = cstr(path) else {
        return std::ptr::null_mut();
    };
    let src = match std::fs::read_to_string(&p) {
        Ok(s) => s,
        Err(_) => return std::ptr::null_mut(),
    };
    let base = std::path::Path::new(&p)
        .parent()
        .map(|x| x.to_string_lossy().to_string())
        .unwrap_or_default();
    let doc = crate::blocks::render_blocks(&src, &base, dark != 0);
    match serde_json::to_string(&doc) {
        Ok(s) => to_c(s),
        Err(_) => std::ptr::null_mut(),
    }
}
