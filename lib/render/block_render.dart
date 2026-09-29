// 结构化块 → Flutter widget。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import 'inline_render.dart';

/// 折叠块的展开状态由外部持有（ListView 会回收子项，本地 State 靠不住）
class FoldState {
  final Set<String> expanded = <String>{};
  bool isOpen(String key) => expanded.contains(key);
  void toggle(String key) {
    if (!expanded.remove(key)) expanded.add(key);
  }
}

/// 单个块的渲染入口。
/// [index] 为顶层块下标（用于折叠状态键）；嵌套块传 -1。
Widget buildBlock(
  MdBlock b,
  MdStyle st, {
  required LinkTap? onLink,
  required FoldState folds,
  required VoidCallback onFoldChanged,
  int index = -1,
  double maxWidth = 900,
  List<String> pathKeys = const [],
}) {
  final key = pathKeys.isEmpty ? '$index' : pathKeys.join('/');

  switch (b) {
    case BlkHeading(:final level, :final inl):
      // 拉开层级跨度：原来 1.62/1.38/1.18/1.06/1/1 与正文区分度太低，
      // h1/h2 再配一条底部细分隔线（GitHub/Typora 的通用做法）
      final size = switch (level) {
        1 => st.fontSize * 1.86,
        2 => st.fontSize * 1.5,
        3 => st.fontSize * 1.26,
        4 => st.fontSize * 1.12,
        5 => st.fontSize,
        _ => st.fontSize * 0.92,
      };
      final ruled = level <= 2;
      final textColor = level == 6 ? st.muted : st.text;
      return Padding(
        padding: EdgeInsets.only(
          top: switch (level) {
            1 => 26,
            2 => 22,
            3 => 16,
            _ => 12,
          },
          bottom: ruled ? 10 : 6,
        ),
        child: Container(
          width: double.infinity,
          decoration: ruled
              ? BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: st.border, width: 1),
                  ),
                )
              : null,
          padding: ruled ? const EdgeInsets.only(bottom: 6) : null,
          child: Text.rich(
            TextSpan(
              children: buildInlines(
                inl,
                st,
                onLink: onLink,
                maxWidth: maxWidth,
                base: TextStyle(
                  fontSize: size,
                  height: 1.35,
                  fontWeight: level <= 2 ? FontWeight.w700 : FontWeight.w600,
                  color: textColor,
                ),
              ),
            ),
          ),
        ),
      );

    case BlkPara(:final inl):
      if (inl.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text.rich(
          TextSpan(
            children:
                buildInlines(inl, st, onLink: onLink, maxWidth: maxWidth),
          ),
        ),
      );

    case BlkCode(:final lang, :final lines):
      return _CodeBlock(lang: lang, lines: lines, st: st);

    case BlkMermaid(:final code):
      return _MermaidFallback(code: code, st: st);

    case BlkList(:final ordered, :final start, :final items):
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: EdgeInsets.only(left: 4, top: i == 0 ? 0 : 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: ordered ? 30 : 20,
                      child: Text(
                        ordered ? '${start + i}.' : '•',
                        textAlign: ordered ? TextAlign.right : TextAlign.center,
                        style: TextStyle(
                          fontSize: st.fontSize,
                          height: 1.75,
                          // 符号/序号小面积上强调色，列表结构扫一眼就出来
                          color: st.accent,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final child in items[i])
                            buildBlock(
                              child,
                              st,
                              onLink: onLink,
                              folds: folds,
                              onFoldChanged: onFoldChanged,
                              maxWidth: maxWidth - 48,
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );

    case BlkQuote(:final blocks):
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Container(
          decoration: BoxDecoration(
            // 底色 + 左边条 + 弱化的文字色，三层信号把引用从正文里托出来
            color: st.quoteBg,
            border: Border(left: BorderSide(color: st.quoteBar, width: 4)),
            borderRadius: const BorderRadius.only(
              topRight: Radius.circular(6),
              bottomRight: Radius.circular(6),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(14, 6, 12, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final child in blocks)
                buildBlock(
                  child,
                  st.copyWith(fontSize: st.fontSize * 0.97, text: st.muted),
                  onLink: onLink,
                  folds: folds,
                  onFoldChanged: onFoldChanged,
                  maxWidth: maxWidth - 30,
                ),
            ],
          ),
        ),
      );

    case BlkTable(:final aligns, :final head, :final rows):
      return _TableView(
        aligns: aligns,
        head: head,
        rows: rows,
        st: st,
        onLink: onLink,
        maxWidth: maxWidth,
      );

    case BlkHr():
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Divider(height: 1, thickness: 1, color: st.border),
      );

    case BlkDetails(:final summary, :final blocks):
      final open = folds.isOpen(key);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Container(
          decoration: BoxDecoration(
            color: st.chipBg,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: st.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: () {
                  folds.toggle(key);
                  onFoldChanged();
                },
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        open ? Icons.expand_more : Icons.chevron_right,
                        size: 20,
                        color: st.muted,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: buildInlines(
                              summary,
                              st,
                              onLink: onLink,
                              maxWidth: maxWidth,
                              base: TextStyle(
                                fontSize: st.fontSize * 0.98,
                                height: 1.5,
                                fontWeight: FontWeight.w600,
                                color: st.text,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (open)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Divider(height: 14),
                      for (final child in blocks)
                        buildBlock(
                          child,
                          st,
                          onLink: onLink,
                          folds: folds,
                          onFoldChanged: onFoldChanged,
                          maxWidth: maxWidth - 28,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );

    case BlkRaw(:final text):
      if (text.trim().isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          text,
          style: TextStyle(fontSize: st.fontSize * 0.95, color: st.muted),
        ),
      );
  }
}

// ------------------------------------------------------------------ 代码块

class _CodeBlock extends StatefulWidget {
  final String lang;
  final List<List<MdToken>> lines;
  final MdStyle st;
  const _CodeBlock({required this.lang, required this.lines, required this.st});

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;

  String get _plain =>
      widget.lines.map((l) => l.map((t) => t.s).join()).join();

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _plain));
    if (!mounted) return;
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final spans = <InlineSpan>[];
    final base = TextStyle(
      fontFamily: 'monospace',
      fontSize: st.fontSize * 0.88,
      height: 1.5,
      color: st.text,
    );
    for (var i = 0; i < widget.lines.length; i++) {
      for (final t in widget.lines[i]) {
        spans.add(TextSpan(
          text: t.s,
          style: base.copyWith(
            color: hexColor(t.c) ?? st.text,
            fontWeight: t.b ? FontWeight.w700 : null,
            fontStyle: t.i ? FontStyle.italic : null,
            decoration: t.u ? TextDecoration.underline : null,
          ),
        ));
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: st.codeBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: st.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部栏：语言标签 + 复制按钮（读代码片段时最常要的两个东西）
            Container(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              decoration: BoxDecoration(
                color: st.chipBg,
                border: Border(bottom: BorderSide(color: st.border)),
              ),
              child: Row(
                children: [
                  Text(
                    widget.lang.isEmpty ? 'code' : widget.lang,
                    style: TextStyle(
                      fontSize: st.fontSize * 0.78,
                      color: st.muted,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: _copy,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _copied ? Icons.check : Icons.copy_outlined,
                            size: 13,
                            color: _copied ? Colors.green : st.muted,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            _copied ? '已复制' : '复制',
                            style: TextStyle(
                              fontSize: st.fontSize * 0.75,
                              color: _copied ? Colors.green : st.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              // 长行横向滚动而不是换行：换行会把缩进结构搅烂，代码没法读。
              // 用 Text 而不是 SelectableText：整个阅读区外层套了 SelectionArea，
              // 选区由它统一管理（嵌套可选组件不被支持），也才能跨块连选。
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text.rich(
                  TextSpan(style: base, children: spans),
                  softWrap: false,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ Mermaid

class _MermaidFallback extends StatelessWidget {
  final String code;
  final MdStyle st;
  const _MermaidFallback({required this.code, required this.st});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: st.chipBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: st.border),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.schema_outlined, size: 16, color: st.muted),
                const SizedBox(width: 6),
                Text(
                  'Mermaid 图表（源码视图）',
                  style: TextStyle(
                    fontSize: st.fontSize * 0.82,
                    color: st.muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: st.fontSize * 0.85,
                height: 1.5,
                color: st.text,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 表格

class _TableView extends StatelessWidget {
  final List<String> aligns;
  final List<List<MdInline>> head;
  final List<List<List<MdInline>>> rows;
  final MdStyle st;
  final LinkTap? onLink;
  final double maxWidth;
  const _TableView({
    required this.aligns,
    required this.head,
    required this.rows,
    required this.st,
    required this.onLink,
    required this.maxWidth,
  });

  Alignment _al(int i) {
    final a = i < aligns.length ? aligns[i] : 'none';
    return switch (a) {
      'center' => Alignment.center,
      'right' => Alignment.centerRight,
      _ => Alignment.centerLeft,
    };
  }

  @override
  Widget build(BuildContext context) {
    Widget cell(List<MdInline> inl, int i, {bool bold = false}) => Container(
          alignment: _al(i),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Text.rich(
            TextSpan(
              children: buildInlines(
                inl,
                st,
                onLink: onLink,
                maxWidth: maxWidth,
                base: TextStyle(
                  fontSize: st.fontSize * 0.94,
                  height: 1.5,
                  color: st.text,
                  fontWeight: bold ? FontWeight.w600 : null,
                ),
              ),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder.all(color: st.border, width: 1),
            children: [
              if (head.isNotEmpty)
                TableRow(
                  decoration: BoxDecoration(color: st.chipBg),
                  children: [
                    for (var i = 0; i < head.length; i++)
                      cell(head[i], i, bold: true),
                  ],
                ),
              // 斑马纹：行多了以后目光容易串行，隔行底色能拉住视线
              for (var ri = 0; ri < rows.length; ri++)
                TableRow(
                  decoration: ri.isOdd ? BoxDecoration(color: st.zebraBg) : null,
                  children: [
                    for (var i = 0; i < rows[ri].length; i++) cell(rows[ri][i], i),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 工具

String fileNameOf(String path) {
  final i = path.lastIndexOf(Platform.pathSeparator);
  final j = path.lastIndexOf('/');
  final k = i > j ? i : j;
  return k < 0 ? path : path.substring(k + 1);
}
