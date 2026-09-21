// 应用状态：文件夹、标签、主题、字号、排序、会话、搜索。
import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher, AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/models.dart';
import 'core/native.dart';
import 'perf.dart';
import 'render/block_render.dart';

class TabItem {
  final String path;
  final String name;
  RenderedDoc? doc;
  String? error;
  bool loading;
  double scrollRatio;
  /// 由搜索结果打开时置位：文档就绪后滚动到首个命中块
  bool seekPending = false;
  TabItem({
    required this.path,
    required this.name,
    this.doc,
    this.error,
    this.loading = false,
    this.scrollRatio = 0,
    this.seekPending = false,
  });
}

class AppState extends ChangeNotifier {
  AppLifecycleListener? _lifecycle;

  String? root;
  TreeData? tree;
  bool scanning = false;

  final List<TabItem> tabs = [];
  int activeIndex = -1;

  SortMode sortMode = SortMode.nameAsc;
  double fontSize = 15;
  ThemeMode themeMode = ThemeMode.system;

  final FoldState folds = FoldState();

  // 搜索
  bool searchOpen = false;
  String query = '';
  List<SearchHit> hits = [];
  bool searching = false;
  int searchSeq = 0;
  /// 当前搜索词：正文与搜索摘要都用它做红色高亮
  String? highlightQuery;

  bool sidebarOpen = true;
  String? toast;

  SessionData session = SessionData();
  Timer? _saveTimer;
  int _dbgRead = 0, _dbgRender = 0;

  TabItem? get active =>
      activeIndex >= 0 && activeIndex < tabs.length ? tabs[activeIndex] : null;

  // ------------------------------------------------------------ 启动

  /// 关窗口/退出时兜底把会话写盘。
  /// 否则「滚动停止 → 400ms 防抖 → 800ms 防抖」这 1.2 秒内关窗会丢掉最后的位置。
  void _installExitHook() {
    _lifecycle ??= AppLifecycleListener(
      onExitRequested: () async {
        await flush();
        return AppExitResponse.exit;
      },
    );
  }

  Future<void> boot() async {
    _installExitHook();
    try {
      session = NativeCore.loadSession(NativeCore.configDir());
      themeMode = switch (session.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      fontSize = (session.fontSize ?? 15).toDouble().clamp(13, 21);
      sortMode = SortMode.fromId(session.sortMode);
    } catch (e) {
      _toast('会话读取失败：$e');
    }
    notifyListeners();

    // 命令行特性：MDREADER_OPEN=<目录> 直接打开（也用于自动化自测）
    final preset = Platform.environment['MDREADER_OPEN'];
    if (preset != null && preset.isNotEmpty) {
      if (Directory(preset).existsSync()) {
        await openRoot(preset);
      } else if (File(preset).existsSync()) {
        await openRoot(File(preset).parent.path);
        await openTab(preset);
      }
      // 可选：启动即执行一次搜索（用于自动化验证搜索高亮链路）
      final q = Platform.environment['MDREADER_SEARCH'];
      if (q != null && q.isNotEmpty) {
        openSearch();
        await runSearch(q);
      }
      // 可选：只设置正文高亮词（不开搜索面板），等价于「搜完收起面板」的状态
      final hl = Platform.environment['MDREADER_HL'];
      if (hl != null && hl.isNotEmpty) {
        highlightQuery = hl;
        notifyListeners();
      }
      return;
    }
    if (session.lastRoot != null && session.lastRoot!.kind == 'fs') {
      final p = session.lastRoot!.loc;
      if (Directory(p).existsSync()) {
        await openRoot(p, restoreFile: session.lastFile);
      }
    }
  }

  // ------------------------------------------------------------ 打开 / 扫描

  Future<void> openRoot(String path, {String? restoreFile}) async {
    scanning = true;
    root = path;
    notifyListeners();
    try {
      tree = await NativeCore.scanTree(path);
    } catch (e) {
      _toast('扫描失败：$e');
      scanning = false;
      notifyListeners();
      return;
    }
    scanning = false;

    session.lastRoot = RootRef('fs', path);
    final recents = session.recentRoots.where((r) => r.loc != path).toList();
    recents.insert(0, RootRef('fs', path));
    session.recentRoots = recents.take(10).toList();
    _scheduleSave();

    notifyListeners();

    if (restoreFile != null && File(restoreFile).existsSync()) {
      await openTab(restoreFile, ratio: session.filePositions[_posKey(restoreFile)]);
    } else {
      final first = _firstMd(tree?.children ?? const []);
      if (first != null) await openTab(first);
    }
  }

  Future<void> refreshTree() async {
    if (root == null) return;
    final keep = active?.path;
    scanning = true;
    notifyListeners();
    try {
      tree = await NativeCore.scanTree(root!);
      _toast('已刷新');
    } catch (e) {
      _toast('刷新失败：$e');
    }
    scanning = false;
    notifyListeners();
    if (keep != null) {
      final idx = tabs.indexWhere((t) => t.path == keep);
      if (idx >= 0) activeIndex = idx;
      notifyListeners();
    }
  }

  String? _firstMd(List<TreeNode> nodes) {
    for (final n in nodes) {
      if (!n.isDir) return n.path;
      final inner = _firstMd(n.children);
      if (inner != null) return inner;
    }
    return null;
  }

  // ------------------------------------------------------------ 标签

  Future<void> openTab(
    String path, {
    double? ratio,
    String? fragment,
    bool seek = false,
  }) async {
    final existing = tabs.indexWhere((t) => t.path == path);
    if (existing >= 0) {
      activeIndex = existing;
      if (seek) tabs[existing].seekPending = true;
      notifyListeners();
      return;
    }
    final tab = TabItem(
      path: path,
      name: path.split('/').last,
      loading: true,
      scrollRatio: ratio ?? session.filePositions[_posKey(path)] ?? 0,
      seekPending: seek,
    );
    tabs.add(tab);
    activeIndex = tabs.length - 1;
    session.lastFile = path;
    _scheduleSave();
    notifyListeners();

    final tOpen = DateTime.now();
    _dbgRead = _dbgRender = 0;
    try {
      final f = File(path);
      if (!f.existsSync()) throw StateError('文件不存在');
      final t1 = DateTime.now();
      final doc = await NativeCore.renderFile(path, _isDark());
      final t3 = DateTime.now();
      tab.doc = doc;
      _dbgRead = 0;
      _dbgRender = t3.difference(t1).inMilliseconds;
      tab.loading = false;
      tab.error = null;
    } catch (e) {
      tab.loading = false;
      tab.error = '$e';
    }
    notifyListeners();
    if (Perf.enabled) {
      final ms = DateTime.now().difference(tOpen).inMilliseconds;
      // ignore: avoid_print
      print('PERF_OPEN path=$path blocks=${tab.doc?.blockCount ?? 0} '
          'bytes=${File(path).lengthSync()} openMs=$ms '
          'readMs=${_dbgRead} renderMs=${_dbgRender}');
      Perf.markReady();
      // ignore: avoid_print
      print('PERF_READY');
      Timer(const Duration(seconds: 6), () {
        // ignore: avoid_print
        print(Perf.report(5.0));
        exit(0);
      });
    }
    _selftestReport();
  }

  /// 自测模式：MDREADER_SELFTEST=1 时，首篇文档渲染完打印统计后退出。
  void _selftestReport() {
    if (Platform.environment['MDREADER_SELFTEST'] != '1') return;
    final t = active;
    if (t == null || t.loading) return;
    final doc = t.doc;
    var details = 0, lists = 0, codes = 0, tables = 0, headings = 0, quotes = 0;
    for (final b in doc?.blocks ?? const <MdBlock>[]) {
      if (b is BlkDetails) details++;
      if (b is BlkList) lists++;
      if (b is BlkCode) codes++;
      if (b is BlkTable) tables++;
      if (b is BlkHeading) headings++;
      if (b is BlkQuote) quotes++;
    }
    // ignore: avoid_print
    print('SELFTEST ok path=${t.path} blocks=${doc?.blocks.length ?? 0} '
        'words=${doc?.words ?? 0} details=$details list=$lists code=$codes '
        'table=$tables heading=$headings quote=$quotes '
        'tabs=${tabs.length} mdCount=${tree?.mdCount ?? 0} '
        'hasMath=${doc?.hasMath} hasMermaid=${doc?.hasMermaid}');
    Future.delayed(const Duration(milliseconds: 300), () => exit(0));
  }

  void closeTab(int i) {
    if (i < 0 || i >= tabs.length) return;
    tabs.removeAt(i);
    if (tabs.isEmpty) {
      activeIndex = -1;
    } else if (activeIndex >= tabs.length) {
      activeIndex = tabs.length - 1;
    } else if (i < activeIndex) {
      activeIndex--;
    }
    notifyListeners();
  }

  void activate(int i) {
    if (i < 0 || i >= tabs.length) return;
    activeIndex = i;
    final t = tabs[i];
    if (t.doc == null && !t.loading) {
      openTab(t.path);
      return;
    }
    notifyListeners();
  }

  /// 主题切换后需要按新主题重新高亮（Rust 侧高亮依赖明暗）
  Future<void> recolorAll() async {
    for (final t in tabs) {
      if (t.doc == null) continue;
      try {
        if (!File(t.path).existsSync()) continue;
        t.doc = await NativeCore.renderFile(t.path, _isDark());
      } catch (_) {}
    }
    notifyListeners();
  }

  bool _isDark() {
    if (themeMode == ThemeMode.dark) return true;
    if (themeMode == ThemeMode.light) return false;
    return PlatformDispatcher.instance.platformBrightness == Brightness.dark;
  }

  // ------------------------------------------------------------ 设置

  void setFontSize(double v) {
    fontSize = v.clamp(13.0, 21.0);
    session.fontSize = fontSize.round();
    _scheduleSave();
    notifyListeners();
  }

  void setSortMode(SortMode m) {
    sortMode = m;
    session.sortMode = m.id;
    _scheduleSave();
    notifyListeners();
  }

  Future<void> setTheme(ThemeMode m) async {
    themeMode = m;
    session.theme = switch (m) {
      ThemeMode.light => 'light',
      ThemeMode.dark => 'dark',
      ThemeMode.system => null,
    };
    _scheduleSave();
    notifyListeners();
    await recolorAll();
  }

  void toggleSidebar() {
    sidebarOpen = !sidebarOpen;
    notifyListeners();
  }

  void rememberScroll(String path, double ratio) {
    session.filePositions[_posKey(path)] = ratio;
    final t = tabs.firstWhere((x) => x.path == path,
        orElse: () => TabItem(path: path, name: ''));
    t.scrollRatio = ratio;
    _scheduleSave();
  }

  String _posKey(String path) => '${root ?? ""}|$path';

  // ------------------------------------------------------------ 搜索

  /// 快捷键用：显式打开搜索面板（幂等）
  void openSearch() {
    searchOpen = true;
    notifyListeners();
  }

  /// 关闭搜索面板但**保留正文高亮**（用户常要在正文里顺着高亮读下去）
  void closeSearch() {
    searchOpen = false;
    notifyListeners();
  }

  /// 显式清除搜索词与高亮
  void clearSearch() {
    searchOpen = false;
    hits = [];
    query = '';
    highlightQuery = null;
    notifyListeners();
  }

  void toggleSearch() {
    searchOpen = !searchOpen;
    if (!searchOpen) {
      // 只收起面板，高亮留在正文里
      notifyListeners();
      return;
    }
    notifyListeners();
  }

  Future<void> runSearch(String q) async {
    query = q;
    final trimmed = q.trim();
    highlightQuery = trimmed.isEmpty ? null : trimmed;
    if (trimmed.length < 1 || root == null) {
      hits = [];
      searching = false;
      notifyListeners();
      return;
    }
    final seq = ++searchSeq;
    searching = true;
    notifyListeners();
    try {
      final r = await NativeCore.search(root!, q.trim());
      if (seq != searchSeq) return; // 丢弃过期结果
      hits = r;
    } catch (e) {
      if (seq == searchSeq) _toast('搜索失败：$e');
    }
    if (seq == searchSeq) searching = false;
    notifyListeners();
  }

  // ------------------------------------------------------------ 会话落盘

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), () {
      try {
        NativeCore.saveSession(NativeCore.configDir(), session);
      } catch (_) {}
    });
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    try {
      NativeCore.saveSession(NativeCore.configDir(), session);
    } catch (_) {}
  }

  void _toast(String msg) {
    toast = msg;
    notifyListeners();
    Future.delayed(const Duration(seconds: 2), () {
      if (toast == msg) {
        toast = null;
        notifyListeners();
      }
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }
}
