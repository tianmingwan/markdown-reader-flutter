// 新特性的纯 Dart / Widget 测试：
// 会话模型（工作区 + AI 站点）、大纲抽取、快速打开过滤。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdreader_flutter/app.dart';
import 'package:mdreader_flutter/core/models.dart';
import 'package:mdreader_flutter/core/native.dart';
import 'package:mdreader_flutter/state.dart';

// 测试小块 → 原始 JSON（手拼 parseBlock 能认的字段）
Object _blockToJson(MdBlock b) => switch (b) {
      BlkHeading(:final level, :final inl) => {
          't': 'Heading',
          'level': level,
          'inl': _inlToJson(inl),
        },
      BlkPara(:final inl) => {'t': 'Para', 'inl': _inlToJson(inl)},
      _ => {'t': 'Raw', 'text': ''},
    };

Object _inlToJson(List<MdInline> inl) => inl
    .map((x) => switch (x) {
          InlText(:final s) => {'t': 'Text', 's': s},
          InlStrong(:final inl) => {'t': 'Strong', 'inl': _inlToJson(inl)},
          _ => {'t': 'Text', 's': ''},
        })
    .toList();

RenderedDoc _docOf(List<MdBlock> blocks) => RenderedDoc(
    blocks.map((b) => jsonDecode(jsonEncode(_blockToJson(b)))).toList(),
    false,
    false,
    0);

void main() {
  group('会话模型', () {
    test('工作区与 AI 站点 URL 的 JSON 往返', () {
      final s = SessionData(
        recentRoots: [RootRef('fs', '/a')],
        aiBaseUrl: 'https://www.kimi.com/',
        workspaces: {
          '/a': RootWorkspace(tabs: ['/a/1.md', '/a/2.md'], active: '/a/2.md'),
        },
      );
      final back =
          SessionData.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, Object?>);
      expect(back.aiBaseUrl, 'https://www.kimi.com/');
      final ws = back.workspaces['/a']!;
      expect(ws.tabs, ['/a/1.md', '/a/2.md']);
      expect(ws.active, '/a/2.md');
    });

    test('旧版会话（没有新字段）解析不炸', () {
      final back = SessionData.fromJson(const {'lastFile': '/a/1.md'});
      expect(back.workspaces, isEmpty);
      expect(back.aiBaseUrl, isNull);
    });
  });

  group('大纲抽取', () {
    test('标题按顺序抽出，带块下标与层级', () {
      final doc = _docOf([
        const BlkPara([InlText('前言')]),
        const BlkHeading(1, [InlText('第一章')]),
        const BlkPara([InlText('正文')]),
        const BlkHeading(2, [
          InlStrong([InlText('重点罪名')]),
        ]),
      ]);
      final items = outlineOf(doc);
      expect(items.length, 2);
      expect(items[0].blockIndex, 1);
      expect(items[0].level, 1);
      expect(items[0].text, '第一章');
      expect(items[1].blockIndex, 3);
      expect(items[1].text, '重点罪名', reason: '加粗内联要展开取文字');
    });

    test('plainInlineText 拍平嵌套内联', () {
      expect(
        plainInlineText(const [
          InlText('宪法'),
          InlStrong([InlText('修正案')]),
          InlLink('', false, [InlText('链接')]),
        ]),
        '宪法修正案链接',
      );
    });
  });

  group('快速打开（Ctrl+P）', () {
    TreeNode file(String path) =>
        TreeNode(path.split('/').last, path, 'file', 10, 100, const []);

    AppState stateWithTree() => AppState()
      ..root = '/lib'
      ..tree = TreeData('lib', '/lib', 4, [
        TreeNode('法律', '/lib/法律', 'dir', 0, 100, [
          file('/lib/法律/16-民法·民事法律行为与代理.md'),
          file('/lib/法律/13-刑法·分则重点罪名.md'),
        ]),
        file('/lib/政治/01-时政.md'),
        file('/lib/README.md'),
      ]);

    testWidgets('输入关键词即时过滤，多个词都要命中', (t) async {
      NativeCore.configDirOverride =
          Directory.systemTemp.createTempSync('mdreader_qopen').path;
      addTearDown(() => NativeCore.configDirOverride = null);

      final s = stateWithTree();
      await t.pumpWidget(MaterialApp(home: QuickOpenDialog(state: s)));
      await t.pump();

      // 初始列出全部（拍平目录树）
      expect(find.text('16-民法·民事法律行为与代理.md'), findsOneWidget);
      expect(find.text('01-时政.md'), findsOneWidget);

      await t.enterText(find.byType(TextField), '民法 代理');
      await t.pump();
      expect(find.text('16-民法·民事法律行为与代理.md'), findsOneWidget);
      expect(find.text('13-刑法·分则重点罪名.md'), findsNothing,
          reason: '两个词必须都命中');
      expect(find.text('01-时政.md'), findsNothing);
      s.dispose();
    });
  });
}
