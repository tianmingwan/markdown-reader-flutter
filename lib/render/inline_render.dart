// 结构化内联节点 → Flutter InlineSpan。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';

/// 渲染所需的视觉参数（跟随主题与字号）
class MdStyle {
  final bool dark;
  final double fontSize;
  final Color text;
  final Color muted;
  final Color link;
  final Color border;
  final Color codeBg;
  final Color quoteBar;
  final Color chipBg;
  /// 公式（TeX）未接渲染器时的呈现色；接入 KaTeX 类渲染器后此色仅作占位
  final Color mathFg;
  /// 当前搜索词：命中片段用红色高亮（正文与搜索摘要共用）
  final String? highlight;
  final Color markBg;
  final Color markFg;

  const MdStyle({
    required this.dark,
    required this.fontSize,
    required this.text,
    required this.muted,
    required this.link,
    required this.border,
    required this.codeBg,
    required this.quoteBar,
    required this.chipBg,
    required this.mathFg,
    this.highlight,
    this.markBg = const Color(0xFFFFD5D5),
    this.markFg = const Color(0xFFB71C1C),
  });

  factory MdStyle.of(BuildContext ctx, double fontSize, {String? highlight}) {
    final dark = Theme.of(ctx).brightness == Brightness.dark;
    return MdStyle(
      dark: dark,
      fontSize: fontSize,
      text: dark ? const Color(0xFFE6E6E6) : const Color(0xFF24292F),
      muted: dark ? const Color(0xFF9AA0A6) : const Color(0xFF6A737D),
      link: dark ? const Color(0xFF6CB6FF) : const Color(0xFF0969DA),
      border: dark ? const Color(0xFF3A3F45) : const Color(0xFFD8DEE4),
      codeBg: dark ? const Color(0xFF22272E) : const Color(0xFFF2F4F7),
      quoteBar: dark ? const Color(0xFF4A5158) : const Color(0xFFCBD3DB),
      chipBg: dark ? const Color(0xFF2A2F35) : const Color(0xFFEEF1F4),
      mathFg: dark ? const Color(0xFFB7A6FF) : const Color(0xFF6B4FBB),
      highlight: (highlight == null || highlight.isEmpty) ? null : highlight,
      markBg: dark ? const Color(0xFF5C1A1A) : const Color(0xFFFFD5D5),
      markFg: dark ? const Color(0xFFFF8A8A) : const Color(0xFFB71C1C),
    );
  }

  MdStyle copyWith({double? fontSize}) => MdStyle(
        dark: dark,
        fontSize: fontSize ?? this.fontSize,
        text: text,
        muted: muted,
        link: link,
        border: border,
        codeBg: codeBg,
        quoteBar: quoteBar,
        chipBg: chipBg,
        mathFg: mathFg,
        highlight: highlight,
        markBg: markBg,
        markFg: markFg,
      );
}

Color? hexColor(String? s) {
  if (s == null || s.length < 7) return null;
  final v = int.tryParse(s.substring(1), radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

typedef LinkTap = void Function(String href, bool internal);

/// 内联序列 → InlineSpan 列表
List<InlineSpan> buildInlines(
  List<MdInline> inl,
  MdStyle st, {
  LinkTap? onLink,
  TextStyle? base,
  double maxWidth = 900,
}) {
  final style = base ??
      TextStyle(fontSize: st.fontSize, height: 1.75, color: st.text);
  return _spans(inl, st, style, onLink, maxWidth);
}

List<InlineSpan> _spans(
  List<MdInline> inl,
  MdStyle st,
  TextStyle style,
  LinkTap? onLink,
  double maxWidth,
) {
  final out = <InlineSpan>[];
  for (final x in inl) {
    switch (x) {
      case InlText(:final s):
        _pushWithHighlight(s, style, out, st);
      case InlStrong(:final inl):
        final s2 = style.copyWith(fontWeight: FontWeight.w700);
        out.add(TextSpan(style: s2, children: _spans(inl, st, s2, onLink, maxWidth)));
      case InlEm(:final inl):
        final s2 = style.copyWith(fontStyle: FontStyle.italic);
        out.add(TextSpan(style: s2, children: _spans(inl, st, s2, onLink, maxWidth)));
      case InlStrike(:final inl):
        final s2 = style.copyWith(decoration: TextDecoration.lineThrough);
        out.add(TextSpan(style: s2, children: _spans(inl, st, s2, onLink, maxWidth)));
      case InlCode(:final s):
        out.add(TextSpan(
          text: s,
          style: style.copyWith(
            fontFamily: 'monospace',
            backgroundColor: st.codeBg,
            fontSize: style.fontSize! * 0.92,
          ),
        ));
      case InlLink(:final href, :final internal, :final inl):
        final s2 = style.copyWith(
          color: st.link,
          decoration: TextDecoration.underline,
        );
        final rec = TapGestureRecognizer()
          ..onTap = () => onLink?.call(href, internal);
        out.add(TextSpan(
          style: s2,
          children: _spans(inl, st, s2, onLink, maxWidth),
          recognizer: rec,
        ));
      case InlImg(:final src, :final alt):
        out.addAll(imageSpanOf(src, alt, st, maxWidth));
      case InlBr():
        out.add(TextSpan(text: '\n', style: style));
      case InlSoftBr():
        out.add(TextSpan(text: ' ', style: style));
      case InlTask(:final checked):
        out.add(TextSpan(
          text: checked ? '☑ ' : '☐ ',
          style: style.copyWith(color: st.muted),
        ));
    }
  }
  return out;
}

/// 把文本里命中搜索词的片段切出来，套上红色高亮样式。
/// 大小写不敏感，按原始下标切分（中文安全）。无命中时直接走普通路径。
void _pushWithHighlight(
  String s,
  TextStyle style,
  List<InlineSpan> out,
  MdStyle st,
) {
  final q = st.highlight;
  if (q == null || q.isEmpty || s.isEmpty) {
    _pushTextWithMath(s, style, out, st);
    return;
  }
  final lower = s.toLowerCase();
  final lowerQ = q.toLowerCase();
  var from = 0;
  var idx = lower.indexOf(lowerQ, from);
  if (idx < 0) {
    _pushTextWithMath(s, style, out, st);
    return;
  }
  while (idx >= 0) {
    if (idx > from) {
      _pushTextWithMath(s.substring(from, idx), style, out, st);
    }
    out.add(TextSpan(
      text: s.substring(idx, idx + q.length),
      style: style.copyWith(
        backgroundColor: st.markBg,
        color: st.markFg,
        fontWeight: FontWeight.w700,
      ),
    ));
    from = idx + q.length;
    idx = lower.indexOf(lowerQ, from);
  }
  if (from < s.length) {
    _pushTextWithMath(s.substring(from), style, out, st);
  }
}

/// 供搜索面板摘要复用：把一段纯文本按命中词切成 InlineSpan 列表。
List<InlineSpan> highlightSpans(
  String text,
  String query,
  TextStyle base, {
  required Color markBg,
  required Color markFg,
}) {
  final out = <InlineSpan>[];
  if (query.isEmpty) {
    out.add(TextSpan(text: text, style: base));
    return out;
  }
  final lower = text.toLowerCase();
  final lowerQ = query.toLowerCase();
  var from = 0;
  var idx = lower.indexOf(lowerQ, from);
  if (idx < 0) {
    out.add(TextSpan(text: text, style: base));
    return out;
  }
  while (idx >= 0) {
    if (idx > from) {
      out.add(TextSpan(text: text.substring(from, idx), style: base));
    }
    out.add(TextSpan(
      text: text.substring(idx, idx + query.length),
      style: base.copyWith(
        backgroundColor: markBg,
        color: markFg,
        fontWeight: FontWeight.w700,
      ),
    ));
    from = idx + query.length;
    idx = lower.indexOf(lowerQ, from);
  }
  if (from < text.length) {
    out.add(TextSpan(text: text.substring(from), style: base));
  }
  return out;
}

/// TeX 公式接入点：目前以可辨识样式（斜体 + 主题色）呈现。
/// 换用真正的排版引擎时，只需在这里把匹配到的 tex 换成对应 widget/span。
const Duration kMathStylePlaceholder = Duration.zero;

void _pushTextWithMath(
  String s,
  TextStyle style,
  List<InlineSpan> out,
  MdStyle st,
) {
  if (!s.contains(r'$')) {
    out.add(TextSpan(text: s, style: style));
    return;
  }
  final re = RegExp(r'\$\$([^$]+?)\$\$|\$([^$\n]+?)\$');
  var last = 0;
  for (final m in re.allMatches(s)) {
    if (m.start > last) {
      out.add(TextSpan(text: s.substring(last, m.start), style: style));
    }
    final tex = (m.group(1) ?? m.group(2) ?? '').trim();
    final display = m.group(1) != null;
    out.add(TextSpan(
      text: display ? ' $tex ' : tex,
      style: style.copyWith(
        fontStyle: FontStyle.italic,
        fontFamily: 'monospace',
        color: st.mathFg,
        fontSize: style.fontSize! * (display ? 1.02 : 0.98),
      ),
    ));
    last = m.end;
  }
  if (last < s.length) {
    out.add(TextSpan(text: s.substring(last), style: style));
  }
}

/// 图片内联：本地绝对路径读文件，远程走网络
List<InlineSpan> imageSpanOf(String src, String alt, MdStyle st,
    [double maxWidth = 900]) {
  final isRemote = src.startsWith('http://') || src.startsWith('https://');
  if (!isRemote && !File(src).existsSync()) {
    return [
      TextSpan(
        text: '🖼 ${alt.isEmpty ? src : alt}（图片不存在）',
        style: TextStyle(color: st.muted, fontSize: st.fontSize * 0.9),
      ),
    ];
  }
  final img = isRemote
      ? Image.network(src, fit: BoxFit.contain)
      : Image.file(File(src), fit: BoxFit.contain);
  return [
    WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: img,
        ),
      ),
    ),
  ];
}
