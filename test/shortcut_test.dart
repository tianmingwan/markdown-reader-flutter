// 快捷键与高亮生命周期的行为测试。
// 用真实的按键事件驱动，不依赖窗口焦点注入。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mdreader_flutter/app.dart';
import 'package:mdreader_flutter/state.dart';

Widget host(AppState s) => MaterialApp(
      home: AppShortcuts(state: s, child: const Scaffold(body: Text('x'))),
    );

void main() {
  group('搜索高亮的生命周期', () {
    test('closeSearch 保留高亮词，clearSearch 才清除', () {
      final s = AppState();
      s.openSearch();
      s.highlightQuery = '宪法';
      expect(s.searchOpen, isTrue);

      s.closeSearch();
      expect(s.searchOpen, isFalse);
      expect(s.highlightQuery, '宪法', reason: '收起面板不应丢掉正文高亮');

      s.clearSearch();
      expect(s.highlightQuery, isNull);
      expect(s.hits, isEmpty);
    });

    test('toggleSearch 收起面板时同样保留高亮', () {
      final s = AppState();
      s.openSearch();
      s.highlightQuery = '行政处罚';
      s.toggleSearch();
      expect(s.searchOpen, isFalse);
      expect(s.highlightQuery, '行政处罚');
    });
  });

  group('快捷键（真实按键事件）', () {
    testWidgets('Ctrl+F 打开搜索面板', (t) async {
      final s = AppState();
      await t.pumpWidget(host(s));
      expect(s.searchOpen, isFalse);

      await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.keyF);
      await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await t.pumpAndSettle();

      expect(s.searchOpen, isTrue);
    });

    testWidgets('Esc 第一下收面板、保留高亮；第二下才清除高亮', (t) async {
      final s = AppState();
      await t.pumpWidget(host(s));

      s.openSearch();
      s.highlightQuery = '宪法';
      await t.pumpAndSettle();

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(s.searchOpen, isFalse, reason: '第一下应收起面板');
      expect(s.highlightQuery, '宪法', reason: '第一下不应清除高亮');

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(s.highlightQuery, isNull, reason: '第二下清除高亮');
    });

    testWidgets('无高亮时按 Esc 不报错也不改变状态', (t) async {
      final s = AppState();
      await t.pumpWidget(host(s));
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(s.searchOpen, isFalse);
      expect(s.highlightQuery, isNull);
    });
  });
}
