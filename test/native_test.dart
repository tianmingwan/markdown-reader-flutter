// Rust core 的集成测试：走真实 .so，验证渲染管线端到端。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdreader_flutter/core/models.dart';
import 'package:mdreader_flutter/core/native.dart';

void main() {
  setUpAll(() {
    // 让 NativeCore 能定位到工程内的 native/ 目录
    if (!File('native/libmdreader_core.so').existsSync()) {
      fail('缺少 native/libmdreader_core.so —— 请先构建 Rust core');
    }
  });

  test('动态库可加载', () {
    expect(NativeCore.available(), isTrue);
    expect(NativeCore.libPath(), endsWith('libmdreader_core.so'));
  });

  test('标题 / 列表 / 表格 / 代码块 结构化渲染', () async {
    final doc = await NativeCore.renderBlocks(
      '''
# 标题

段落 **加粗** 与 \`代码\`。

- 甲
- 乙

| a | b |
|---|---|
| 1 | 2 |

\`\`\`rust
fn main() {}
\`\`\`
''',
      '/tmp',
      false,
    );
    expect(doc.blockCount, greaterThanOrEqualTo(5));
    final kinds = doc.blocks.map((b) => b.runtimeType.toString()).toSet();
    expect(kinds, contains('BlkHeading'));
    expect(kinds, contains('BlkList'));
    expect(kinds, contains('BlkTable'));
    expect(kinds, contains('BlkCode'));
  });

  test('代码块带 syntect 高亮 token', () async {
    final doc = await NativeCore.renderBlocks(
      '```rust\nfn main() { let x = 1; }\n```',
      '/tmp',
      true,
    );
    final code = doc.blocks.first as BlkCode;
    expect(code.lang, 'rust');
    final colored = code.lines.expand((l) => l).where((t) => t.c != null);
    expect(colored.isNotEmpty, isTrue, reason: '应产生带颜色的 token');
  });

  test('<details> 折叠块被正确抽取', () async {
    final doc = await NativeCore.renderBlocks(
      '<details>\n<summary>看答案</summary>\n\n- 解析：**B**\n\n</details>',
      '/tmp',
      false,
    );
    final fold = doc.blocks.whereType<BlkDetails>().toList();
    expect(fold.length, 1);
    expect(fold.first.blocks.isNotEmpty, isTrue);
    expect((fold.first.summary.first as InlText).s.contains('看答案'), isTrue);
  });

  test('mermaid 围栏识别为独立块', () async {
    final doc = await NativeCore.renderBlocks(
      '```mermaid\ngraph TD\nA-->B\n```',
      '/tmp',
      false,
    );
    expect(doc.hasMermaid, isTrue);
    expect(doc.blocks.whereType<BlkMermaid>().length, 1);
  });

  test('数学标记检测', () async {
    final doc = await NativeCore.renderBlocks(r'公式 $a^2+b^2=c^2$', '/tmp', false);
    expect(doc.hasMath, isTrue);
  });

  test('相对图片解析成绝对路径、.md 链接标记为内部', () async {
    final doc = await NativeCore.renderBlocks(
      '![图](img/a.png)\n\n[下一章](part2.md)\n\n[外链](https://a.com)',
      '/tmp/somewhere',
      false,
    );
    final inlines = <MdInline>[];
    for (var i = 0; i < doc.blockCount; i++) {
      final b = doc.blockAt(i);
      if (b is BlkPara) inlines.addAll(b.inl);
    }
    final img = inlines.whereType<InlImg>().first;
    expect(img.src.startsWith('/'), isTrue);
    expect(img.src.endsWith('img/a.png'), isTrue);
    final links = inlines.whereType<InlLink>().toList();
    expect(links.where((l) => l.internal).length, 1);
    expect(links.where((l) => !l.internal).length, 1);
  });

  test('目录扫描返回树与 md 计数', () async {
    final tmp = Directory.systemTemp.createTempSync('mdreader_tree_');
    Directory('${tmp.path}/sub').createSync();
    File('${tmp.path}/a.md').writeAsStringSync('# a');
    File('${tmp.path}/sub/b.md').writeAsStringSync('# b');
    File('${tmp.path}/c.txt').writeAsStringSync('x');
    Directory('${tmp.path}/node_modules').createSync();

    final tree = await NativeCore.scanTree(tmp.path);
    expect(tree.mdCount, 2);
    // node_modules 应被跳过
    expect(tree.children.any((c) => c.name == 'node_modules'), isFalse);
    tmp.deleteSync(recursive: true);
  });

  test('全文搜索命中文件名与内容（中文安全）', () async {
    final tmp = Directory.systemTemp.createTempSync('mdreader_search_');
    File('${tmp.path}/宪法.md').writeAsStringSync('# 宪法概述\n内容一');
    File('${tmp.path}/其它.md').writeAsStringSync('这里也提到宪法一词');
    File('${tmp.path}/无关.md').writeAsStringSync('什么都没有');

    final hits = await NativeCore.search(tmp.path, '宪法');
    expect(hits.length, 2);
    expect(hits.any((h) => h.matchedBy == 'name'), isTrue);
    expect(hits.any((h) => h.matchedBy == 'content'), isTrue);
    tmp.deleteSync(recursive: true);
  });

  test('会话读写往返（隔离在临时目录）', () {
    final tmp = Directory.systemTemp.createTempSync('mdreader_cfg_');
    final s = SessionData(
      recentRoots: [RootRef('fs', '/tmp/x')],
      lastRoot: RootRef('fs', '/tmp/x'),
      lastFile: '/tmp/x/a.md',
      filePositions: {'/tmp/x|/tmp/x/a.md': 0.31},
      theme: 'dark',
      fontSize: 18,
      sortMode: 'mtime-desc',
    );
    expect(NativeCore.saveSession(tmp.path, s), isTrue);
    final back = NativeCore.loadSession(tmp.path);
    expect(back.lastFile, '/tmp/x/a.md');
    expect(back.fontSize, 18);
    expect(back.theme, 'dark');
    expect(back.filePositions['/tmp/x|/tmp/x/a.md'], closeTo(0.31, 1e-6));
    tmp.deleteSync(recursive: true);
  });

  test('不存在文件返回空而不是崩溃', () async {
    await expectLater(
      NativeCore.renderFile('/tmp/绝对不存在的文件_zzz.md', false),
      throwsA(isA<StateError>()),
    );
  });

  test('renderFile 与 renderBlocks 结果一致', () async {
    final tmp = Directory.systemTemp.createTempSync('mdreader_eq_');
    final f = File('${tmp.path}/x.md')
      ..writeAsStringSync('# 标题\n\n- 甲\n- 乙\n\n| a |\n|---|\n| 1 |\n');
    final viaFile = await NativeCore.renderFile(f.path, false);
    final viaStr = await NativeCore.renderBlocks(
        f.readAsStringSync(), tmp.path, false);
    expect(viaFile.blockCount, viaStr.blockCount);
    expect(viaFile.words, viaStr.words);
    tmp.deleteSync(recursive: true);
  });
}
