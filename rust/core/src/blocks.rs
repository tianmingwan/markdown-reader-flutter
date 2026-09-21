//! markdown → 结构化节点树（供 Flutter 直接构建 widget，不再走 HTML）。
//!
//! 为什么不用 HTML：Flutter 不是 HTML 渲染器，把 1.7M 字符的 HTML 交给 Dart 解析
//! 既慢又脆。这里直接在 Rust 侧遍历 pulldown-cmark 事件流，产出块/内联两级节点树，
//! 序列化为 JSON 交给 Dart。代码高亮（syntect）直接输出 (文本, 颜色) 片段。
//!
//! 保留的既有语义（与原 md.rs 对齐）：
//!   - 相对图片 → 绝对路径（Flutter 侧直接读文件，不再走自定义协议）
//!   - .md 相对链接 → 内部跳转（mdopen 语义降级为 kind 标记）
//!   - `mermaid` 围栏块 → 独立块类型
//!   - `<details>/<summary>` → 折叠块（错题文档每题一个答案折叠）
//!   - 表格 / 任务列表 / 删除线 / 脚注（与原 Options 一致）

use pulldown_cmark::{Alignment, CodeBlockKind, Event, Options, Parser, Tag, TagEnd};
use serde::Serialize;
use std::path::PathBuf;

// ---------------------------------------------------------------- 节点模型

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "t")]
pub enum Block {
    /// 标题。level 1..=6
    Heading { level: u8, inl: Vec<Inline> },
    /// 段落
    Para { inl: Vec<Inline> },
    /// 代码块：text 为原文，lines 为高亮片段（每行一组）
    Code {
        lang: String,
        text: String,
        lines: Vec<Vec<Token>>,
    },
    /// mermaid 图（Flutter 侧决定渲染或降级）
    Mermaid { code: String },
    /// 列表。items 每项是一个块序列（支持嵌套列表/多段）
    List {
        ordered: bool,
        start: u64,
        items: Vec<Vec<Block>>,
    },
    /// 引用块
    Quote { blocks: Vec<Block> },
    /// 表格
    Table {
        aligns: Vec<String>,
        head: Vec<Vec<Inline>>,
        rows: Vec<Vec<Vec<Inline>>>,
    },
    /// 分隔线
    Hr,
    /// `<details>` 折叠块
    Details {
        summary: Vec<Inline>,
        blocks: Vec<Block>,
    },
    /// 无法结构化处理的原始 HTML（降级为纯文本展示）
    Raw { text: String },
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "t")]
pub enum Inline {
    Text { s: String },
    Strong { inl: Vec<Inline> },
    Em { inl: Vec<Inline> },
    Strike { inl: Vec<Inline> },
    Code { s: String },
    /// 链接。`internal` 为 true 表示指向本地 .md，Flutter 侧在应用内新开标签
    Link {
        href: String,
        internal: bool,
        inl: Vec<Inline>,
    },
    /// 图片。src 已解析为绝对路径（本地）或原始 URL（远程）
    Img { src: String, alt: String },
    /// 硬换行
    Br,
    /// 任务列表勾选框
    Task { checked: bool },
    /// 软换行（渲染为空格）
    SoftBr,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct Token {
    pub s: String,
    pub c: Option<String>,
    pub b: bool,
    pub i: bool,
    pub u: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct RenderedDoc {
    pub blocks: Vec<Block>,
    pub has_math: bool,
    pub has_mermaid: bool,
    pub words: usize,
}

// ---------------------------------------------------------------- 高亮

fn syntaxes() -> &'static syntect::parsing::SyntaxSet {
    static SS: std::sync::OnceLock<syntect::parsing::SyntaxSet> = std::sync::OnceLock::new();
    SS.get_or_init(syntect::parsing::SyntaxSet::load_defaults_newlines)
}

fn theme(dark: bool) -> &'static syntect::highlighting::Theme {
    if dark {
        static D: std::sync::OnceLock<syntect::highlighting::Theme> = std::sync::OnceLock::new();
        D.get_or_init(|| {
            syntect::highlighting::ThemeSet::load_defaults()
                .themes
                .remove("base16-ocean.dark")
                .unwrap()
        })
    } else {
        static L: std::sync::OnceLock<syntect::highlighting::Theme> = std::sync::OnceLock::new();
        L.get_or_init(|| {
            syntect::highlighting::ThemeSet::load_defaults()
                .themes
                .remove("InspiredGitHub")
                .unwrap()
        })
    }
}

/// 高亮为「每行一组 token」，token 带颜色与字重，Dart 侧直接拼 TextSpan。
fn highlight_tokens(code: &str, lang: &str, dark: bool) -> Vec<Vec<Token>> {
    use syntect::easy::HighlightLines;
    use syntect::highlighting::FontStyle;
    use syntect::util::LinesWithEndings;

    let ss = syntaxes();
    let syntax = if lang.is_empty() {
        ss.find_syntax_plain_text()
    } else {
        ss.find_syntax_by_token(lang)
            .unwrap_or_else(|| ss.find_syntax_plain_text())
    };

    let mut h = HighlightLines::new(syntax, theme(dark));
    let mut lines: Vec<Vec<Token>> = Vec::new();

    for line in LinesWithEndings::from(code) {
        let mut toks: Vec<Token> = Vec::new();
        match h.highlight_line(line, ss) {
            Ok(ranges) => {
                for (style, text) in ranges {
                    if text.is_empty() {
                        continue;
                    }
                    let fg = style.foreground;
                    let tok = Token {
                        s: text.to_string(),
                        c: Some(format!("#{:02x}{:02x}{:02x}", fg.r, fg.g, fg.b)),
                        b: style.font_style.contains(FontStyle::BOLD),
                        i: style.font_style.contains(FontStyle::ITALIC),
                        u: style.font_style.contains(FontStyle::UNDERLINE),
                    };
                    toks.push(tok);
                }
            }
            Err(_) => {
                toks.push(Token {
                    s: line.to_string(),
                    c: None,
                    b: false,
                    i: false,
                    u: false,
                });
            }
        }
        lines.push(toks);
    }
    lines
}

// ---------------------------------------------------------------- 路径解析

fn is_external(dest: &str) -> bool {
    dest.starts_with("http://")
        || dest.starts_with("https://")
        || dest.starts_with("data:")
        || dest.starts_with("mailto:")
        || dest.starts_with('#')
}

fn resolve(base_dir: &str, dest: &str) -> Option<String> {
    if is_external(dest) {
        return None;
    }
    let p = PathBuf::from(base_dir).join(dest);
    let abs = p
        .canonicalize()
        .unwrap_or(p)
        .to_string_lossy()
        .replace('\\', "/");
    Some(abs)
}

fn is_md(dest: &str) -> bool {
    let head = dest.split(['#', '?']).next().unwrap_or("");
    let lower = head.to_lowercase();
    lower.ends_with(".md") || lower.ends_with(".markdown")
}

// ---------------------------------------------------------------- 解析器

struct Parser0<'a> {
    ev: &'a [Event<'a>],
    i: usize,
    base_dir: String,
    dark: bool,
}

impl<'a> Parser0<'a> {
    fn peek(&self) -> Option<&Event<'a>> {
        self.ev.get(self.i)
    }

    /// 解析块序列，直到遇到 `stop` 返回 true 的事件（不消耗它）
    fn blocks(&mut self, stop: &dyn Fn(&Event) -> bool, inside_details: bool) -> Vec<Block> {
        let mut out: Vec<Block> = Vec::new();

        while let Some(ev) = self.peek() {
            if stop(ev) {
                break;
            }

            match ev {
                Event::Start(Tag::Heading { level, .. }) => {
                    let lv = *level as u8;
                    self.i += 1;
                    let inl = self.inlines(&|e| matches!(e, Event::End(TagEnd::Heading(_))));
                    self.i += 1; // 吃掉 End(Heading)
                    out.push(Block::Heading { level: lv, inl });
                }
                Event::Start(Tag::Paragraph) => {
                    self.i += 1;
                    let inl = self.inlines(&|e| matches!(e, Event::End(TagEnd::Paragraph)));
                    self.i += 1;
                    if !inl.is_empty() {
                        out.push(Block::Para { inl });
                    }
                }
                Event::Start(Tag::CodeBlock(kind)) => {
                    let lang = match kind {
                        CodeBlockKind::Fenced(info) => info.trim().to_string(),
                        CodeBlockKind::Indented => String::new(),
                    };
                    self.i += 1;
                    let mut code = String::new();
                    while let Some(e) = self.peek() {
                        match e {
                            Event::Text(t) => {
                                code.push_str(t);
                                self.i += 1;
                            }
                            Event::End(TagEnd::CodeBlock) => {
                                self.i += 1;
                                break;
                            }
                            _ => self.i += 1,
                        }
                    }
                    if lang == "mermaid" || lang.starts_with("mermaid") {
                        out.push(Block::Mermaid { code });
                    } else {
                        let lines = highlight_tokens(&code, &lang, self.dark);
                        out.push(Block::Code {
                            lang,
                            text: code,
                            lines,
                        });
                    }
                }
                Event::Start(Tag::List(start)) => {
                    let ordered = start.is_some();
                    let st = start.unwrap_or(1);
                    self.i += 1;
                    let mut items: Vec<Vec<Block>> = Vec::new();
                    while let Some(e) = self.peek() {
                        if matches!(e, Event::End(TagEnd::List(_))) {
                            self.i += 1;
                            break;
                        }
                        if matches!(e, Event::Start(Tag::Item)) {
                            self.i += 1;
                            let inner = self.blocks(
                                &|x| matches!(x, Event::End(TagEnd::Item)),
                                inside_details,
                            );
                            if let Some(Event::End(TagEnd::Item)) = self.peek() {
                                self.i += 1;
                            }
                            items.push(inner);
                        } else {
                            self.i += 1;
                        }
                    }
                    out.push(Block::List {
                        ordered,
                        start: st,
                        items,
                    });
                }
                Event::Start(Tag::BlockQuote(_)) => {
                    self.i += 1;
                    let inner = self.blocks(
                        &|e| matches!(e, Event::End(TagEnd::BlockQuote(_))),
                        inside_details,
                    );
                    self.i += 1;
                    out.push(Block::Quote { blocks: inner });
                }
                Event::Start(Tag::Table(aligns)) => {
                    let als: Vec<String> = aligns
                        .iter()
                        .map(|a| {
                            match a {
                                Alignment::Left => "left",
                                Alignment::Center => "center",
                                Alignment::Right => "right",
                                Alignment::None => "none",
                            }
                            .to_string()
                        })
                        .collect();
                    self.i += 1;
                    let mut head: Vec<Vec<Inline>> = Vec::new();
                    let mut rows: Vec<Vec<Vec<Inline>>> = Vec::new();
                    let mut cur_row: Vec<Vec<Inline>> = Vec::new();
                    let mut in_head = false;
                    while let Some(e) = self.peek() {
                        match e {
                            Event::End(TagEnd::Table) => {
                                self.i += 1;
                                break;
                            }
                            Event::Start(Tag::TableHead) => {
                                in_head = true;
                                cur_row = Vec::new();
                                self.i += 1;
                            }
                            Event::End(TagEnd::TableHead) => {
                                head = std::mem::take(&mut cur_row);
                                in_head = false;
                                self.i += 1;
                            }
                            Event::Start(Tag::TableRow) => {
                                cur_row = Vec::new();
                                self.i += 1;
                            }
                            Event::End(TagEnd::TableRow) => {
                                rows.push(std::mem::take(&mut cur_row));
                                self.i += 1;
                            }
                            Event::Start(Tag::TableCell) => {
                                self.i += 1;
                                let cell = self.inlines(&|e| matches!(e, Event::End(TagEnd::TableCell)));
                                if let Some(Event::End(TagEnd::TableCell)) = self.peek() {
                                    self.i += 1;
                                }
                                cur_row.push(cell);
                            }
                            _ => self.i += 1,
                        }
                    }
                    let _ = in_head;
                    out.push(Block::Table {
                        aligns: als,
                        head,
                        rows,
                    });
                }
                Event::Rule => {
                    self.i += 1;
                    out.push(Block::Hr);
                }
                Event::Html(h) | Event::InlineHtml(h) => {
                    let raw = h.to_string();
                    self.i += 1;
                    let trimmed = raw.trim();
                    // <details> 已由 split_details 预处理抽出；这里只处理其它原始 HTML
                    if trimmed.starts_with("</details") || trimmed.starts_with("<summary") {
                        // 预处理后不应出现，忽略
                    } else if !trimmed.is_empty() {
                        let text = strip_tags(trimmed);
                        if !text.trim().is_empty() {
                            out.push(Block::Raw { text });
                        }
                    }
                }
                Event::End(_) => break,
                _ => {
                    // 游离内联（如 HTML 块外的裸文本）→ 收集为一个段落
                    let inl = self.inlines(&|e| {
                        matches!(
                            e,
                            Event::Start(Tag::Heading { .. })
                                | Event::Start(Tag::Paragraph)
                                | Event::Start(Tag::List(_))
                                | Event::Start(Tag::CodeBlock(_))
                                | Event::Start(Tag::BlockQuote(_))
                                | Event::Start(Tag::Table(_))
                                | Event::Rule
                                | Event::End(_)
                        )
                    });
                    if !inl.is_empty() {
                        out.push(Block::Para { inl });
                    }
                }
            }
        }
        out
    }

    /// 解析内联序列，直到 `stop` 返回 true 的事件（不消耗它）
    fn inlines(&mut self, stop: &dyn Fn(&Event) -> bool) -> Vec<Inline> {
        let mut out: Vec<Inline> = Vec::new();
        while let Some(ev) = self.peek() {
            if stop(ev) {
                break;
            }
            match ev {
                Event::Text(t) => {
                    out.push(Inline::Text { s: t.to_string() });
                    self.i += 1;
                }
                Event::Code(c) => {
                    out.push(Inline::Code { s: c.to_string() });
                    self.i += 1;
                }
                Event::SoftBreak => {
                    out.push(Inline::SoftBr);
                    self.i += 1;
                }
                Event::HardBreak => {
                    out.push(Inline::Br);
                    self.i += 1;
                }
                Event::TaskListMarker(checked) => {
                    out.push(Inline::Task { checked: *checked });
                    self.i += 1;
                }
                Event::InlineHtml(h) => {
                    let raw = h.to_string();
                    self.i += 1;
                    let txt = strip_tags(&raw);
                    if !txt.is_empty() {
                        out.push(Inline::Text { s: txt });
                    }
                }
                Event::Html(h) => {
                    let raw = h.to_string();
                    self.i += 1;
                    let txt = strip_tags(&raw);
                    if !txt.is_empty() {
                        out.push(Inline::Text { s: txt });
                    }
                }
                Event::Start(Tag::Strong) => {
                    self.i += 1;
                    let inner = self.inlines(&|e| matches!(e, Event::End(TagEnd::Strong)));
                    self.i += 1;
                    out.push(Inline::Strong { inl: inner });
                }
                Event::Start(Tag::Emphasis) => {
                    self.i += 1;
                    let inner = self.inlines(&|e| matches!(e, Event::End(TagEnd::Emphasis)));
                    self.i += 1;
                    out.push(Inline::Em { inl: inner });
                }
                Event::Start(Tag::Strikethrough) => {
                    self.i += 1;
                    let inner = self.inlines(&|e| matches!(e, Event::End(TagEnd::Strikethrough)));
                    self.i += 1;
                    out.push(Inline::Strike { inl: inner });
                }
                Event::Start(Tag::Link { dest_url, .. }) => {
                    let dest = dest_url.to_string();
                    self.i += 1;
                    let inner = self.inlines(&|e| matches!(e, Event::End(TagEnd::Link)));
                    self.i += 1;
                    let internal = is_md(&dest);
                    let href = if internal {
                        resolve(&self.base_dir, dest.split('#').next().unwrap_or(""))
                            .unwrap_or(dest.clone())
                    } else {
                        dest.clone()
                    };
                    out.push(Inline::Link {
                        href,
                        internal,
                        inl: inner,
                    });
                }
                Event::Start(Tag::Image { dest_url, .. }) => {
                    let dest = dest_url.to_string();
                    self.i += 1;
                    let alt = self.inlines(&|e| matches!(e, Event::End(TagEnd::Image)));
                    self.i += 1;
                    let src = resolve(&self.base_dir, &dest).unwrap_or(dest.clone());
                    out.push(Inline::Img {
                        src,
                        alt: plain(&alt),
                    });
                }
                Event::Start(_) | Event::End(_) => {
                    self.i += 1;
                }
                _ => {
                    self.i += 1;
                }
            }
        }
        out
    }
}

fn plain(inl: &[Inline]) -> String {
    let mut s = String::new();
    for x in inl {
        match x {
            Inline::Text { s: t } => s.push_str(t),
            Inline::Code { s: t } => s.push_str(t),
            Inline::Strong { inl } | Inline::Em { inl } | Inline::Strike { inl } => {
                s.push_str(&plain(inl))
            }
            Inline::Link { inl, .. } => s.push_str(&plain(inl)),
            Inline::Img { alt, .. } => s.push_str(alt),
            Inline::SoftBr => s.push(' '),
            _ => {}
        }
    }
    s
}

fn summary_of(blocks: &[Block]) -> Vec<Inline> {
    for b in blocks {
        if let Block::Para { inl } = b {
            return inl.clone();
        }
    }
    vec![]
}

fn extract_summary(html: &str) -> String {
    if let Some(a) = html.find("<summary") {
        if let Some(b) = html[a..].find('>') {
            let start = a + b + 1;
            if let Some(c) = html[start..].find("</summary>") {
                return html[start..start + c].to_string();
            }
        }
    }
    String::new()
}

fn strip_summary(html: &str) -> String {
    if let Some(a) = html.find("<summary") {
        if let Some(b) = html[a..].find(">") {
            let start = a + b + 1;
            if let Some(c) = html[start..].find("</summary>") {
                return html[start + c + "</summary>".len()..].to_string();
            }
        }
        return html[..a].to_string();
    }
    html.to_string()
}

/// 极简去标签（原始 HTML 降级为纯文本时的兜底）
fn strip_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
}

// ---------------------------------------------------------------- 入口

/// 渲染入口（结构化）。
pub fn render_blocks(source: &str, base_dir: &str, dark: bool) -> RenderedDoc {
    let has_math = source.contains('$');
    let has_mermaid = source.contains("```mermaid");
    let words = source.chars().filter(|c| !c.is_whitespace()).count();

    let mut blocks: Vec<Block> = Vec::new();
    for seg in split_details(source) {
        match seg {
            Seg::Md(text) => {
                if text.trim().is_empty() {
                    continue;
                }
                blocks.extend(parse_md(&text, base_dir, dark));
            }
            Seg::Details { summary, inner } => {
                let summary_inl = summary_inlines(&summary);
                let inner_blocks = if inner.trim().is_empty() {
                    Vec::new()
                } else {
                    parse_md(&inner, base_dir, dark)
                };
                blocks.push(Block::Details {
                    summary: summary_inl,
                    blocks: inner_blocks,
                });
            }
        }
    }

    if has_math || has_mermaid {
        // 仅作标记位，Front 端按需加载公式/图表渲染器
    }

    RenderedDoc {
        blocks,
        has_math,
        has_mermaid,
        words,
    }
}

fn parse_md(source: &str, base_dir: &str, dark: bool) -> Vec<Block> {
    let mut options = Options::empty();
    options.insert(
        Options::ENABLE_TABLES
            | Options::ENABLE_FOOTNOTES
            | Options::ENABLE_STRIKETHROUGH
            | Options::ENABLE_TASKLISTS,
    );
    let parser = Parser::new_ext(source, options);
    let events: Vec<Event> = parser.collect();
    let mut p = Parser0 {
        ev: &events,
        i: 0,
        base_dir: base_dir.to_string(),
        dark,
    };
    p.blocks(&|_| false, false)
}

// ---------------------------------------------------------------- details 预处理

enum Seg {
    Md(String),
    Details { summary: String, inner: String },
}

/// 把 `<details>...</details>` 从源文本里抽出来，其余部分原样返回。
/// 不依赖 pulldown-cmark 对 HTML 块的识别（它在 `<details>` 紧跟 `<summary>` 时会当内联 HTML）。
fn split_details(source: &str) -> Vec<Seg> {
    let mut segs: Vec<Seg> = Vec::new();
    let mut rest = source;

    loop {
        let Some(a) = rest.find("<details") else {
            break;
        };
        // 找 head 结束
        let Some(gt) = rest[a..].find('>') else {
            break;
        };
        let head_end = a + gt + 1;
        // 找 </details>
        let Some(close_rel) = rest[head_end..].find("</details>") else {
            break;
        };
        let close = head_end + close_rel;
        let body = &rest[head_end..close];

        // 提取 summary
        let (summary, inner) = match body.find("<summary") {
            Some(sa) => {
                let sh_end = body[sa..].find('>').map(|x| sa + x + 1).unwrap_or(sa);
                match body[sh_end..].find("</summary>") {
                    Some(se) => {
                        let st = sh_end + se;
                        let sum = body[sh_end..st].to_string();
                        let rest_body = format!("{}{}", &body[..sa], &body[st + "</summary>".len()..]);
                        (sum, rest_body)
                    }
                    None => (String::new(), body.to_string()),
                }
            }
            None => (String::new(), body.to_string()),
        };

        if a > 0 {
            segs.push(Seg::Md(rest[..a].to_string()));
        }
        segs.push(Seg::Details { summary, inner });
        rest = &rest[close + "</details>".len()..];
    }

    if !rest.is_empty() {
        segs.push(Seg::Md(rest.to_string()));
    }
    segs
}

/// summary 常带 `<b>`，转成 markdown 的 `**` 后交给统一解析，保住加粗。
fn summary_inlines(html: &str) -> Vec<Inline> {
    if html.trim().is_empty() {
        return vec![Inline::Text {
            s: "详情".to_string(),
        }];
    }
    let mut md = html
        .replace("<b>", "**")
        .replace("</b>", "**")
        .replace("<strong>", "**")
        .replace("</strong>", "**")
        .replace("<i>", "*")
        .replace("</i>", "*");
    md = strip_tags(&md);
    let blocks = parse_md(&md, "", false);
    for b in &blocks {
        if let Block::Para { inl } = b {
            return inl.clone();
        }
    }
    vec![Inline::Text { s: md }]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn r(s: &str) -> Vec<Block> {
        render_blocks(s, "/tmp/base", false).blocks
    }

    #[test]
    fn heading_and_para() {
        let b = r("# 标题\n\n正文 **粗** 和 `代码`");
        assert_eq!(b.len(), 2);
        match &b[0] {
            Block::Heading { level, inl } => {
                assert_eq!(*level, 1);
                assert_eq!(inl.len(), 1);
            }
            _ => panic!("期望标题"),
        }
        match &b[1] {
            Block::Para { inl } => {
                assert!(inl.iter().any(|x| matches!(x, Inline::Strong { .. })));
                assert!(inl.iter().any(|x| matches!(x, Inline::Code { .. })));
            }
            _ => panic!("期望段落"),
        }
    }

    #[test]
    fn table_structured() {
        let b = r("| a | b |\n|---|---|\n| 1 | 2 |");
        match &b[0] {
            Block::Table { head, rows, .. } => {
                assert_eq!(head.len(), 2);
                assert_eq!(rows.len(), 1);
                assert_eq!(rows[0].len(), 2);
            }
            _ => panic!("期望表格"),
        }
    }

    #[test]
    fn mermaid_block() {
        let b = r("```mermaid\ngraph TD; A-->B\n```");
        match &b[0] {
            Block::Mermaid { code } => assert!(code.contains("graph TD")),
            _ => panic!("期望 mermaid"),
        }
    }

    #[test]
    fn code_block_has_tokens() {
        let b = r("```rust\nfn main() {}\n```");
        match &b[0] {
            Block::Code { lang, lines, .. } => {
                assert_eq!(lang, "rust");
                assert!(!lines.is_empty());
                assert!(lines[0].iter().any(|t| t.c.is_some()));
            }
            _ => panic!("期望代码块"),
        }
    }

    #[test]
    fn details_becomes_fold() {
        let src = "<details>\n<summary>看答案</summary>\n\n- 解析内容\n\n</details>";
        let b = r(src);
        match &b[0] {
            Block::Details { summary, blocks } => {
                assert!(blocks.iter().any(|x| matches!(x, Block::List { .. })));
                assert!(!summary.is_empty());
            }
            other => panic!("期望折叠块，实际 {other:?}"),
        }
    }

    #[test]
    fn nested_list() {
        let b = r("- 一\n  - 二\n- 三");
        match &b[0] {
            Block::List { items, .. } => {
                assert_eq!(items.len(), 2);
                assert!(items[0].iter().any(|x| matches!(x, Block::List { .. })));
            }
            _ => panic!("期望列表"),
        }
    }

    #[test]
    fn blockquote() {
        let b = r("> 引用 **粗**");
        match &b[0] {
            Block::Quote { blocks } => assert!(matches!(blocks[0], Block::Para { .. })),
            _ => panic!("期望引用"),
        }
    }

    #[test]
    fn image_resolved_and_link_internal() {
        let b = r("![图](img/a.png)\n\n[下一章](part2.md#x)\n\n[外链](https://a.com)");
        let mut imgs = 0;
        let mut internal = 0;
        let mut external = 0;
        for blk in &b {
            if let Block::Para { inl } = blk {
                for x in inl {
                    match x {
                        Inline::Img { src, alt } => {
                            imgs += 1;
                            assert!(src.contains("img/a.png"));
                            assert_eq!(alt, "图");
                        }
                        Inline::Link { internal: i, .. } => {
                            if *i {
                                internal += 1;
                            } else {
                                external += 1;
                            }
                        }
                        _ => {}
                    }
                }
            }
        }
        assert_eq!(imgs, 1);
        assert_eq!(internal, 1);
        assert_eq!(external, 1);
    }

    #[test]
    fn hr_and_task_list() {
        let b = r("---\n\n- [x] 完成\n- [ ] 未完成");
        assert!(matches!(b[0], Block::Hr));
        let mut found = 0;
        for blk in &b {
            if let Block::List { items, .. } = blk {
                for it in items {
                    if let Some(Block::Para { inl }) = it.first() {
                        if inl.iter().any(|x| matches!(x, Inline::Task { .. })) {
                            found += 1;
                        }
                    }
                }
            }
        }
        assert_eq!(found, 2);
    }
}
