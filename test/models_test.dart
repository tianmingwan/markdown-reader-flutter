import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdreader_flutter/core/models.dart';

void main() {
  group('自然排序', () {
    test('数字按数值比较而不是字典序', () {
      final names = ['第10题.md', '第2题.md', '第1题.md'];
      names.sort(naturalCompare);
      expect(names, ['第1题.md', '第2题.md', '第10题.md']);
    });

    test('混合中英文与前缀', () {
      final a = ['a2', 'a10', 'a1', 'b1'];
      a.sort(naturalCompare);
      expect(a, ['a1', 'a2', 'a10', 'b1']);
    });

    test('大小写不敏感', () {
      expect(naturalCompare('Abc.md', 'abd.md') < 0, isTrue);
    });
  });

  group('排序模式', () {
    TreeNode dir(String n, int size) =>
        TreeNode(n, '/x/$n', 'dir', size, 100, const []);
    TreeNode file(String n, int size, int mtime) =>
        TreeNode(n, '/x/$n', 'file', size, mtime, const []);

    test('目录恒在文件之前', () {
      final nodes = [
        file('b.md', 10, 5),
        dir('zzz', 0),
        file('a.md', 10, 5),
      ];
      final out = sortNodes(nodes, SortMode.nameAsc);
      expect(out.first.isDir, isTrue);
      expect(out[1].name, 'a.md');
      expect(out[2].name, 'b.md');
    });

    test('六种模式各自生效', () {
      final nodes = [
        file('a.md', 100, 1),
        file('b.md', 300, 3),
        file('c.md', 200, 2),
      ];
      expect(sortNodes(nodes, SortMode.sizeDesc).map((e) => e.name),
          ['b.md', 'c.md', 'a.md']);
      expect(sortNodes(nodes, SortMode.sizeAsc).map((e) => e.name),
          ['a.md', 'c.md', 'b.md']);
      expect(sortNodes(nodes, SortMode.mtimeDesc).map((e) => e.name),
          ['b.md', 'c.md', 'a.md']);
      expect(sortNodes(nodes, SortMode.mtimeAsc).map((e) => e.name),
          ['a.md', 'c.md', 'b.md']);
      expect(sortNodes(nodes, SortMode.nameDesc).map((e) => e.name),
          ['c.md', 'b.md', 'a.md']);
    });

    test('fromId 回落到名称升序', () {
      expect(SortMode.fromId('size-desc'), SortMode.sizeDesc);
      expect(SortMode.fromId(null), SortMode.nameAsc);
      expect(SortMode.fromId('bogus'), SortMode.nameAsc);
    });
  });

  group('块解析', () {
    test('标题 / 段落 / 内联样式', () {
      final raw = jsonDecode('''
      {"t":"Heading","level":2,"inl":[{"t":"Text","s":"标题"}]}
      ''');
      final b = parseBlock(raw) as BlkHeading;
      expect(b.level, 2);
      expect((b.inl.first as InlText).s, '标题');
    });

    test('代码块 token（颜色/字重）', () {
      final raw = jsonDecode('''
      {"t":"Code","lang":"rust","text":"fn a(){}",
       "lines":[[{"s":"fn","c":"#ff0000","b":true,"i":false,"u":false}]]}
      ''');
      final b = parseBlock(raw) as BlkCode;
      expect(b.lang, 'rust');
      expect(b.lines.first.first.s, 'fn');
      expect(b.lines.first.first.c, '#ff0000');
      expect(b.lines.first.first.b, isTrue);
    });

    test('折叠块（details）', () {
      final raw = jsonDecode('''
      {"t":"Details","summary":[{"t":"Text","s":"看答案"}],
       "blocks":[{"t":"Para","inl":[{"t":"Text","s":"解析"}]}]}
      ''');
      final b = parseBlock(raw) as BlkDetails;
      expect((b.summary.first as InlText).s, '看答案');
      expect(b.blocks.length, 1);
    });

    test('表格结构', () {
      final raw = jsonDecode('''
      {"t":"Table","aligns":["left","right"],
       "head":[[{"t":"Text","s":"a"}],[{"t":"Text","s":"b"}]],
       "rows":[[[{"t":"Text","s":"1"}],[{"t":"Text","s":"2"}]]]}
      ''');
      final b = parseBlock(raw) as BlkTable;
      expect(b.aligns, ['left', 'right']);
      expect(b.head.length, 2);
      expect(b.rows.first.length, 2);
    });

    test('嵌套列表', () {
      final raw = jsonDecode('''
      {"t":"List","ordered":false,"start":1,"items":[
        [{"t":"Para","inl":[{"t":"Text","s":"一"}]},
         {"t":"List","ordered":true,"start":1,"items":[[{"t":"Para","inl":[{"t":"Text","s":"内"}]}]]}]
      ]}
      ''');
      final b = parseBlock(raw) as BlkList;
      expect(b.items.first.length, 2);
      expect(b.items.first[1], isA<BlkList>());
    });

    test('未知类型降级为 Raw 而不是抛异常', () {
      final b = parseBlock(jsonDecode('{"t":"FutureThing","x":1}'));
      expect(b, isA<BlkRaw>());
    });
  });

  group('内联解析', () {
    test('链接带 internal 标记', () {
      final i = parseInline(jsonDecode(
          '{"t":"Link","href":"/a/b.md","internal":true,"inl":[{"t":"Text","s":"下一章"}]}'));
      final l = i as InlLink;
      expect(l.internal, isTrue);
      expect(l.href, '/a/b.md');
    });

    test('图片 / 换行 / 任务框', () {
      expect(parseInline(jsonDecode('{"t":"Img","src":"/a.png","alt":"图"}')),
          isA<InlImg>());
      expect(parseInline(jsonDecode('{"t":"Br"}')), isA<InlBr>());
      final t = parseInline(jsonDecode('{"t":"Task","checked":true}')) as InlTask;
      expect(t.checked, isTrue);
    });
  });

  group('会话模型', () {
    test('往返序列化保真', () {
      final s = SessionData(
        recentRoots: [RootRef('fs', '/a')],
        lastRoot: RootRef('fs', '/a'),
        lastFile: '/a/x.md',
        filePositions: {'/a|/a/x.md': 0.42},
        theme: 'dark',
        fontSize: 19,
        sortMode: 'size-desc',
      );
      final again = SessionData.fromJson(s.toJson());
      expect(again.lastFile, '/a/x.md');
      expect(again.theme, 'dark');
      expect(again.fontSize, 19);
      expect(again.filePositions['/a|/a/x.md'], closeTo(0.42, 1e-6));
      expect(again.sortMode, 'size-desc');
      expect(again.recentRoots.first.loc, '/a');
    });

    test('theme 为 null 表示跟随系统', () {
      final s = SessionData.fromJson({'theme': null});
      expect(s.theme, isNull);
    });
  });

  group('惰性块解析', () {
    test('blockAt 按需解析且可重复取用', () {
      final doc = RenderedDoc.fromJson({
        'blocks': [
          {'t': 'Para', 'inl': [{'t': 'Text', 's': '一'}]},
          {'t': 'Para', 'inl': [{'t': 'Text', 's': '二'}]},
        ],
        'has_math': false,
        'has_mermaid': false,
        'words': 2,
      });
      expect(doc.blockCount, 2);
      expect(((doc.blockAt(1) as BlkPara).inl.first as InlText).s, '二');
      expect(doc.blockAt(0), same(doc.blockAt(0))); // 命中缓存
    });
  });
}
