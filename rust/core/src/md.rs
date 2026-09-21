//! markdown → HTML 渲染管线。
//! 设计目标（性能）：整条管线在 Rust 后端同步完成，毫秒级；
//! 语法高亮用 syntect（Rust 原生，无需前端 JS 库）；
//! KaTeX / Mermaid 只在文档确实包含时才让前端按需加载。

use pulldown_cmark::{html, CodeBlockKind, CowStr, Event, Options, Parser, Tag, TagEnd};
use serde::Serialize;
use std::path::PathBuf;
use std::sync::OnceLock;

use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderedMd {
    pub html: String,
    pub has_math: bool,
    pub has_mermaid: bool,
    pub words: usize,
}

fn syntaxes() -> &'static syntect::parsing::SyntaxSet {
    static SS: OnceLock<syntect::parsing::SyntaxSet> = OnceLock::new();
    SS.get_or_init(syntect::parsing::SyntaxSet::load_defaults_newlines)
}

fn theme(dark: bool) -> &'static syntect::highlighting::Theme {
    if dark {
        static D: OnceLock<syntect::highlighting::Theme> = OnceLock::new();
        D.get_or_init(|| {
            syntect::highlighting::ThemeSet::load_defaults()
                .themes
                .remove("base16-ocean.dark")
                .unwrap()
        })
    } else {
        static L: OnceLock<syntect::highlighting::Theme> = OnceLock::new();
        L.get_or_init(|| {
            syntect::highlighting::ThemeSet::load_defaults()
                .themes
                .remove("InspiredGitHub")
                .unwrap()
        })
    }
}

fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(c),
        }
    }
    out
}

/// 语法高亮一段代码，输出内联样式 span（主题色由 Rust 端决定，前端零负担）
fn highlight(code: &str, lang: Option<&str>, dark: bool) -> String {
    use syntect::easy::HighlightLines;
    use syntect::highlighting::FontStyle;
    use syntect::util::LinesWithEndings;

    let ss = syntaxes();
    let syntax = lang
        .and_then(|l| {
            let l = l.trim();
            if l.is_empty() {
                None
            } else {
                ss.find_syntax_by_token(l)
            }
        })
        .unwrap_or_else(|| ss.find_syntax_plain_text());

    let mut h = HighlightLines::new(syntax, theme(dark));
    let mut out = String::with_capacity(code.len() + 256);
    let mut last_style: Option<(u8, u8, u8, bool, bool, bool)> = None;

    for line in LinesWithEndings::from(code) {
        if let Ok(ranges) = h.highlight_line(line, ss) {
            for (style, text) in ranges {
                let fg = style.foreground;
                let key = (
                    fg.r,
                    fg.g,
                    fg.b,
                    style.font_style.contains(FontStyle::BOLD),
                    style.font_style.contains(FontStyle::ITALIC),
                    style.font_style.contains(FontStyle::UNDERLINE),
                );
                if last_style == Some(key) {
                    out.push_str(&escape(text));
                    continue;
                }
                last_style = Some(key);
                let (r, g, b, bold, italic, underline) = key;
                let mut css = String::new();
                if bold {
                    css.push_str("font-weight:600;");
                }
                if italic {
                    css.push_str("font-style:italic;");
                }
                if underline {
                    css.push_str("text-decoration:underline;");
                }
                out.push_str(&format!(
                    "<span style=\"color:#{r:02x}{g:02x}{b:02x};{css}\">{}</span>",
                    escape(text)
                ));
            }
        } else {
            out.push_str(&escape(line));
            last_style = None;
        }
    }
    out
}

/// 相对资源 → (绝对路径, 原始相对路径)；非相对返回 None 表示不改写
fn resolve_relative(base_dir: &str, dest: &str) -> Option<(String, String)> {
    if dest.starts_with("http://")
        || dest.starts_with("https://")
        || dest.starts_with("data:")
        || dest.starts_with("mdimg://")
        || dest.starts_with("mdopen://")
        || dest.starts_with('#')
        || dest.starts_with("file://")
    {
        return None;
    }
    let base = PathBuf::from(base_dir);
    let p = base.join(dest);
    let abs = p
        .canonicalize()
        .unwrap_or_else(|_| p.clone())
        .to_string_lossy()
        .replace('\\', "/");
    Some((abs, dest.to_string()))
}

fn enc(s: &str) -> String {
    utf8_percent_encode(s, NON_ALPHANUMERIC).to_string()
}

/// 渲染入口：markdown 文本 + 所在目录 → 完整 HTML。
/// `mobile_ctx`：安卓 SAF 场景传入 md 文档 Uri，相对资源改走 mdimg://mobile/<ctx>/<rel>
pub fn render(source: &str, base_dir: &str, dark: bool, mobile_ctx: Option<&str>) -> RenderedMd {
    let mut options = Options::empty();
    options.insert(
        Options::ENABLE_TABLES
            | Options::ENABLE_FOOTNOTES
            | Options::ENABLE_STRIKETHROUGH
            | Options::ENABLE_TASKLISTS,
    );
    let parser = Parser::new_ext(source, options);
    let events: Vec<Event> = parser.collect();

    let mut out_events: Vec<Event> = Vec::with_capacity(events.len() + 8);
    let mut skip_until = 0usize;
    let mut mermaid_count = 0usize;

    let mut i = 0usize;
    while i < events.len() {
        if i < skip_until {
            i += 1;
            continue;
        }
        match &events[i] {
            Event::Start(Tag::CodeBlock(CodeBlockKind::Fenced(info))) => {
                // 收集代码块文本直到 End(CodeBlock)
                let mut code = String::new();
                let mut j = i + 1;
                loop {
                    match events.get(j) {
                        Some(Event::Text(t)) => {
                            code.push_str(t);
                            j += 1;
                        }
                        Some(Event::End(TagEnd::CodeBlock)) => {
                            j += 1;
                            break;
                        }
                        Some(_) => {
                            j += 1; // 代码块内其它事件极少出现，忽略
                        }
                        None => break,
                    }
                }
                skip_until = j;
                let lang = info.trim();
                let frag = if lang.starts_with("mermaid") {
                    mermaid_count += 1;
                    format!("<pre class=\"mermaid\">{}</pre>", escape(&code))
                } else {
                    let lang_opt = if lang.is_empty() { None } else { Some(lang) };
                    format!(
                        "<pre class=\"code-block\"><code>{}</code></pre>",
                        highlight(&code, lang_opt, dark)
                    )
                };
                out_events.push(Event::Html(CowStr::from(frag)));
            }
            Event::Start(Tag::Image {
                link_type,
                dest_url,
                title,
                id,
            }) => {
                if let Some((abs, rel)) = resolve_relative(base_dir, dest_url) {
                    let src = match mobile_ctx {
                        Some(ctx) => format!("mdimg://mobile/{}/{}", enc(ctx), enc(&rel)),
                        None => format!("mdimg://local/{}", enc(&abs)),
                    };
                    let tag = Tag::Image {
                        link_type: link_type.clone(),
                        dest_url: CowStr::from(src),
                        title: title.clone(),
                        id: id.clone(),
                    };
                    out_events.push(Event::Start(tag));
                } else {
                    out_events.push(events[i].clone());
                }
            }
            Event::Start(Tag::Link {
                link_type,
                dest_url,
                title,
                id,
            }) => {
                // 指向其它 .md 的链接 → 应用内新标签打开
                let is_md_link = dest_url
                    .split(['#', '?'])
                    .next()
                    .map(|p| {
                        let lower = p.to_lowercase();
                        lower.ends_with(".md") || lower.ends_with(".markdown")
                    })
                    .unwrap_or(false);
                if is_md_link {
                    let (path_part, frag_part) = match dest_url.find('#') {
                        Some(idx) => (&dest_url[..idx], &dest_url[idx..]),
                        None => (dest_url.as_ref(), ""),
                    };
                    if let Some((abs, rel)) = resolve_relative(base_dir, path_part) {
                        let href = match mobile_ctx {
                            Some(ctx) => format!("mdopen://mobile/{}/{}{}", enc(ctx), enc(&rel), frag_part),
                            None => format!("mdopen://local/{}{}", enc(&abs), frag_part),
                        };
                        let tag = Tag::Link {
                            link_type: link_type.clone(),
                            dest_url: CowStr::from(href),
                            title: title.clone(),
                            id: id.clone(),
                        };
                        out_events.push(Event::Start(tag));
                    } else {
                        out_events.push(events[i].clone());
                    }
                } else {
                    out_events.push(events[i].clone());
                }
            }
            _ => out_events.push(events[i].clone()),
        }
        i += 1;
    }

    let mut html_out = String::with_capacity(source.len() + 1024);
    html::push_html(&mut html_out, out_events.into_iter());

    let has_math = source.contains('$');
    let has_mermaid = mermaid_count > 0;
    let words = source.chars().filter(|c| !c.is_whitespace()).count();

    RenderedMd {
        html: html_out,
        has_math,
        has_mermaid,
        words,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_headings_and_tables() {
        let r = render("# 标题\n\n| a | b |\n|---|---|\n| 1 | 2 |", "C:/tmp", false, None);
        assert!(r.html.contains("<h1>标题</h1>"));
        assert!(r.html.contains("<table>"));
    }

    #[test]
    fn mermaid_block_detected() {
        let r = render("```mermaid\ngraph TD; A-->B\n```\n", "C:/tmp", false, None);
        assert!(r.has_mermaid);
        assert!(r.html.contains("class=\"mermaid\""));
        assert!(r.html.contains("graph TD; A--&gt;B"));
    }

    #[test]
    fn multiple_mermaid_blocks_all_emitted() {
        let r = render(
            "```mermaid\ngraph TD; A-->B\n```\n\n```mermaid\nsequenceDiagram\nA->>B: hi\n```\n",
            "C:/tmp",
            false,
            None,
        );
        assert!(r.has_mermaid);
        assert_eq!(r.html.matches("class=\"mermaid\"").count(), 2);
    }

    #[test]
    fn mermaid_in_list_item_kept_as_mermaid() {
        let r = render(
            "- 列表项：\n\n  ```mermaid\n  graph TD\n  A-->B\n  ```\n",
            "C:/tmp",
            false,
            None,
        );
        assert!(r.has_mermaid);
        assert!(r.html.contains("class=\"mermaid\""));
        // pulldown_cmark 已剥离列表嵌套的公共缩进，代码原样保留
        assert!(r.html.contains("graph TD\nA--&gt;B"));
        assert!(!r.html.contains("  graph TD"));
    }

    #[test]
    fn non_mermaid_fenced_block_not_flagged() {
        let r = render("```flow\nst=>start: 开始\n```\n", "C:/tmp", false, None);
        assert!(!r.has_mermaid);
        assert!(r.html.contains("code-block"));
        assert!(!r.html.contains("class=\"mermaid\""));
    }

    #[test]
    fn mermaid_content_html_escaped() {
        let r = render("```mermaid\ngraph TD; A[<b>&</b>] --> B[\"引号\"]\n```\n", "C:/tmp", false, None);
        assert!(r.has_mermaid);
        assert!(r.html.contains("&lt;b&gt;&amp;&lt;/b&gt;"));
        assert!(!r.html.contains("<b>&</b>"));
    }

    #[test]
    fn math_detected() {
        let r = render("公式 $x^2$", "C:/tmp", false, None);
        assert!(r.has_math);
    }

    #[test]
    fn code_highlight_emits_spans() {
        let r = render("```rust\nfn main() { println!(\"hi\"); }\n```\n", "C:/tmp", true, None);
        assert!(r.html.contains("code-block"));
        assert!(r.html.contains("<span style=\"color:"));
    }

    #[test]
    fn relative_image_rewritten() {
        let r = render("![图](img/a.png)", "C:/tmp/note", false, None);
        assert!(r.html.contains("mdimg://local/"));
        assert!(r.html.contains("img%2Fa"));
    }

    #[test]
    fn md_link_rewritten() {
        let r = render("[下一章](part2.md#x)", "C:/tmp/note", false, None);
        assert!(r.html.contains("mdopen://local/"));
        assert!(r.html.contains("#x"));
    }

    #[test]
    fn external_links_untouched() {
        let r = render("[链接](https://example.com)", "C:/tmp", false, None);
        assert!(r.html.contains("https://example.com"));
        assert!(!r.html.contains("mdopen://"));
    }

    #[test]
    fn task_list_parsed() {
        let r = render("- [x] 完成\n- [ ] 未完成\n", "C:/tmp", false, None);
        assert!(r.html.contains("checkbox"));
    }
}