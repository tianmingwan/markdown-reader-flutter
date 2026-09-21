import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdreader_flutter/core/models.dart';
import 'package:mdreader_flutter/render/block_render.dart';
import 'package:mdreader_flutter/render/inline_render.dart';

/// 把块塞进最小可运行的脚手架里渲染
Widget host(List<MdBlock> blocks, {FoldState? folds, VoidCallback? onFold, LinkTap? onLink, double size = 15}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) {
          final st = MdStyle.of(ctx, size);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < blocks.length; i++)
                buildBlock(
                  blocks[i],
                  st,
                  onLink: onLink,
                  folds: folds ?? FoldState(),
                  onFoldChanged: onFold ?? () {},
                  index: i,
                ),
            ],
          );
        },
      ),
    ),
  );
}


/// 从 Text 的 span 树里取出第一个 TapGestureRecognizer（直接触发回调，
/// 比按坐标点击稳定：这里要验证的是 href/internal 是否正确接到 onLink）
TapGestureRecognizer? findLinkRecognizer(WidgetTester t) {
  TapGestureRecognizer? walk(TextSpan s) {
    final r = s.recognizer;
    if (r is TapGestureRecognizer) return r;
    for (final c in s.children ?? const <InlineSpan>[]) {
      if (c is TextSpan) {
        final hit = walk(c);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  final w = t.widget<Text>(find.byType(Text).first);
  return walk(w.textSpan as TextSpan);
}

void main() {
  highlightGroup();

  testWidgets('标题与段落文本可见', (t) async {
    await t.pumpWidget(host([
      const BlkHeading(1, [InlText('一级标题')]),
      const BlkPara([
        InlText('普通'),
        InlStrong([InlText('加粗')]),
        InlCode('code()'),
      ]),
    ]));
    expect(find.textContaining('一级标题'), findsOneWidget);
    expect(find.textContaining('普通'), findsOneWidget);
    expect(find.textContaining('加粗'), findsOneWidget);
    expect(find.textContaining('code()'), findsOneWidget);
  });

  testWidgets('折叠块默认收起，点击后展开', (t) async {
    final folds = FoldState();
    var rebuilt = 0;
    await t.pumpWidget(host(
      [
        const BlkDetails(
          [InlText('查看答案')],
          [
            BlkPara([InlText('隐藏的解析内容')]),
          ],
        ),
      ],
      folds: folds,
      onFold: () => rebuilt++,
    ));

    expect(find.textContaining('查看答案'), findsOneWidget);
    expect(find.textContaining('隐藏的解析内容'), findsNothing);

    await t.tap(find.textContaining('查看答案'));
    await t.pumpAndSettle();

    expect(folds.isOpen('0'), isTrue);
    expect(rebuilt, 1);
  });

  testWidgets('折叠状态由外部持有（回收后仍保持）', (t) async {
    final folds = FoldState()..toggle('0');
    await t.pumpWidget(host(
      [
        const BlkDetails(
          [InlText('答案')],
          [
            BlkPara([InlText('展开可见')]),
          ],
        ),
      ],
      folds: folds,
    ));
    expect(find.textContaining('展开可见'), findsOneWidget);
  });

  testWidgets('代码块按 token 上色', (t) async {
    await t.pumpWidget(host([
      BlkCode('rust', 'fn main(){}', [
        [
          MdToken('fn', '#ff0000', true, false, false),
          MdToken(' main', null, false, false, false),
        ],
      ]),
    ]));
    expect(find.textContaining('fn'), findsOneWidget);
    expect(find.text('rust'), findsOneWidget);
  });

  testWidgets('表格渲染行列', (t) async {
    await t.pumpWidget(host([
      const BlkTable(
        ['left', 'right'],
        [
          [InlText('列一')],
          [InlText('列二')],
        ],
        [
          [
            [InlText('甲')],
            [InlText('乙')],
          ],
        ],
      ),
    ]));
    expect(find.textContaining('列一'), findsOneWidget);
    expect(find.textContaining('列二'), findsOneWidget);
    expect(find.textContaining('甲'), findsOneWidget);
  });

  testWidgets('列表带序号与项目符号', (t) async {
    await t.pumpWidget(host([
      const BlkList(true, 3, [
        [BlkPara([InlText('第三项')])],
        [BlkPara([InlText('第四项')])],
      ]),
      const BlkList(false, 1, [
        [BlkPara([InlText('无序项')])],
      ]),
    ]));
    expect(find.text('3.'), findsOneWidget);
    expect(find.text('4.'), findsOneWidget);
    expect(find.text('•'), findsOneWidget);
  });

  testWidgets('引用块与分隔线', (t) async {
    await t.pumpWidget(host([
      const BlkQuote([
        BlkPara([InlText('被引用的内容')]),
      ]),
      const BlkHr(),
    ]));
    expect(find.textContaining('被引用的内容'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('内部链接点击回传 href 与 internal 标记', (t) async {
    String? href;
    bool? internal;
    await t.pumpWidget(host(
      [
        const BlkPara([
          InlLink('/tmp/下一章.md', true, [InlText('点我')]),
        ]),
      ],
      onLink: (h, i) {
        href = h;
        internal = i;
      },
    ));
    final rec = findLinkRecognizer(t);
    expect(rec, isNotNull, reason: '链接 span 上应挂 TapGestureRecognizer');
    rec!.onTap!();
    expect(href, '/tmp/下一章.md');
    expect(internal, isTrue);
  });

  testWidgets('外部链接标记为 internal=false', (t) async {
    String? href;
    bool? internal;
    await t.pumpWidget(host(
      [
        const BlkPara([
          InlLink('https://example.com', false, [InlText('外链')]),
        ]),
      ],
      onLink: (h, i) {
        href = h;
        internal = i;
      },
    ));
    final rec = findLinkRecognizer(t);
    expect(rec, isNotNull);
    rec!.onTap!();
    expect(href, 'https://example.com');
    expect(internal, isFalse);
  });

  testWidgets('Mermaid 降级为源码视图（不崩）', (t) async {
    await t.pumpWidget(host([
      const BlkMermaid('graph TD\nA-->B'),
    ]));
    expect(find.textContaining('Mermaid 图表'), findsOneWidget);
    expect(find.textContaining('graph TD'), findsOneWidget);
  });

  testWidgets('字号影响标题尺寸（A- / A+）', (t) async {
    double headingSize() {
      final w = t.widget<Text>(find.byType(Text).first);
      final span = w.textSpan as TextSpan;
      final child = span.children!.first as TextSpan;
      return child.style!.fontSize!;
    }

    await t.pumpWidget(host(
      [
        const BlkHeading(1, [InlText('标题')]),
      ],
      size: 15,
    ));
    final small = headingSize();
    await t.pumpWidget(host(
      [
        const BlkHeading(1, [InlText('标题')]),
      ],
      size: 21,
    ));
    final big = headingSize();
    expect(small, closeTo(15 * 1.62, 0.01));
    expect(big, greaterThan(small));
  });

  testWidgets('空段落不产生多余 widget', (t) async {
    await t.pumpWidget(host([
      const BlkPara([]),
      const BlkRaw('   '),
    ]));
    expect(find.byType(Text), findsNothing);
  });
}

/// 搜索高亮相关的补充用例
void highlightGroup() {
  group('搜索高亮', () {
    test('命中片段被切成独立 span 并带红色样式', () {
      const base = TextStyle(fontSize: 12);
      final spans = highlightSpans(
        '宪法是根本大法，学习宪法很重要',
        '宪法',
        base,
        markBg: const Color(0xFFFFD5D5),
        markFg: const Color(0xFFB71C1C),
      );
      final marked = spans.whereType<TextSpan>().where((s) =>
          s.style?.backgroundColor == const Color(0xFFFFD5D5)).toList();
      expect(marked.length, 2, reason: '两处命中都要高亮');
      expect(marked.every((s) => s.text == '宪法'), isTrue);
      // 切分不能丢字：拼回来必须与原文一致
      final joined = spans
          .whereType<TextSpan>()
          .map((s) => s.text ?? '')
          .join();
      expect(joined, '宪法是根本大法，学习宪法很重要');
    });

    test('无命中时原样返回单段', () {
      final spans = highlightSpans(
        '完全无关的文字',
        '宪法',
        const TextStyle(fontSize: 12),
        markBg: const Color(0xFFFFD5D5),
        markFg: const Color(0xFFB71C1C),
      );
      expect(spans.length, 1);
      expect((spans.first as TextSpan).text, '完全无关的文字');
    });

    test('大小写不敏感', () {
      final spans = highlightSpans(
        'Rust 与 RUST 都算命中',
        'rust',
        const TextStyle(fontSize: 12),
        markBg: const Color(0xFFFFD5D5),
        markFg: const Color(0xFFB71C1C),
      );
      final marked =
          spans.whereType<TextSpan>().where((s) => s.style?.backgroundColor != null);
      expect(marked.length, 2);
    });

    test('空查询词不高亮', () {
      final spans = highlightSpans(
        '文本',
        '',
        const TextStyle(fontSize: 12),
        markBg: const Color(0xFFFFD5D5),
        markFg: const Color(0xFFB71C1C),
      );
      expect(spans.length, 1);
      expect((spans.first as TextSpan).style?.backgroundColor, isNull);
    });

    testWidgets('正文高亮：段落里的命中词带红色背景', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (ctx) {
            final st = MdStyle.of(ctx, 15, highlight: '宪法');
            return Text.rich(
              TextSpan(
                children: buildInlines(
                  const [InlText('宪法是根本大法')],
                  st,
                ),
              ),
            );
          }),
        ),
      ));
      final w = t.widget<Text>(find.byType(Text));
      final span = w.textSpan as TextSpan;
      final hit = (span.children as List).whereType<TextSpan>().firstWhere(
            (s) => s.style?.backgroundColor != null,
          );
      expect(hit.text, '宪法');
      expect(hit.style!.backgroundColor, const Color(0xFFFFD5D5));
      expect(hit.style!.fontWeight, FontWeight.w700);
    });

    testWidgets('未开启高亮时不改变渲染', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (ctx) {
            final st = MdStyle.of(ctx, 15);
            return Text.rich(TextSpan(
              children: buildInlines(const [InlText('宪法是根本大法')], st),
            ));
          }),
        ),
      ));
      final w = t.widget<Text>(find.byType(Text));
      final span = w.textSpan as TextSpan;
      expect(
        (span.children as List)
            .whereType<TextSpan>()
            .every((s) => s.style?.backgroundColor == null),
        isTrue,
      );
    });
  });
}
