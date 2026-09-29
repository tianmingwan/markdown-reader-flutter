// 文件夹工作区记忆的集成测试：走真实 .so 与临时目录，
// 验证「换文件夹 → 记住标签组 → 切回 → 原样恢复」整条链路。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mdreader_flutter/core/native.dart';
import 'package:mdreader_flutter/state.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    if (!File('native/libmdreader_core.so').existsSync()) {
      fail('缺少 native/libmdreader_core.so —— 请先构建 Rust core');
    }
    tmp = Directory.systemTemp.createTempSync('mdreader_ws');
    NativeCore.configDirOverride = '${tmp.path}/cfg';
  });

  tearDownAll(() {
    NativeCore.configDirOverride = null;
    tmp.deleteSync(recursive: true);
  });

  /// 造一个小型笔记库：rootA 两篇、rootB 一篇
  (Directory, Directory) makeRoots() {
    final a = Directory('${tmp.path}/rootA')..createSync(recursive: true);
    File('${a.path}/a1.md').writeAsStringSync('# A 第一篇\n\n内容甲');
    File('${a.path}/a2.md').writeAsStringSync('# A 第二篇\n\n内容乙');
    final b = Directory('${tmp.path}/rootB')..createSync(recursive: true);
    File('${b.path}/b1.md').writeAsStringSync('# B 第一篇\n\n内容丙');
    return (a, b);
  }

  test('换文件夹记住标签组，切回时恢复活动标签', () async {
    final (a, b) = makeRoots();
    final s = AppState();

    await s.openRoot(a.path);
    expect(s.tabs.map((e) => e.path), ['${a.path}/a1.md']);

    await s.openTab('${a.path}/a2.md');
    expect(s.tabs.length, 2);
    expect(s.active!.path, '${a.path}/a2.md');

    // 切到 B：A 的标签组要被记下来；B 默认打开自己的第一篇
    await s.openRoot(b.path);
    expect(s.root, b.path);
    final wsA = s.session.workspaces[a.path]!;
    expect(wsA.tabs, ['${a.path}/a1.md', '${a.path}/a2.md']);
    expect(wsA.active, '${a.path}/a2.md');
    expect(s.active!.path, '${b.path}/b1.md');

    // A 的标签还留着（换文件夹不清标签，是并行工作区）
    expect(s.tabs.any((t) => t.path == '${a.path}/a2.md'), isTrue);

    // 在 B 里只开 b1，切回 A：恢复 A 的两篇，活动标签是 a2
    await s.openRoot(a.path);
    expect(s.active!.path, '${a.path}/a2.md');
    s.dispose();
  });

  test('最近打开列表：去重、置顶、当前文件夹在前', () async {
    final (a, b) = makeRoots();
    final s = AppState();

    await s.openRoot(a.path);
    await s.openRoot(b.path);
    await s.openRoot(a.path);
    final locs = s.session.recentRoots.map((r) => r.loc).toList();
    expect(locs.first, a.path, reason: '最后打开的要在最前');
    expect(locs.where((l) => l == a.path).length, 1, reason: '同一文件夹不重复');
    expect(locs.contains(b.path), isTrue);
    s.dispose();
  });
}
