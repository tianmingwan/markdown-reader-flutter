// 应用状态：文件夹、标签、主题、字号、排序、会话、搜索。
import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher, AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/android_storage.dart';
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

/// 「问 AI」请求：把这段文字送进内置 DeepSeek 面板
class AiAsk {
  final String text;

  /// true = 开新对话并直接提问（内容放进去就发送）；false = 只放进输入框
  final bool submit;

  const AiAsk(this.text, {required this.submit});
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

  // ------------------------------------------------------------ AI 面板

  /// 默认宽度：够放下 DeepSeek 的对话列，又不至于把正文挤没
  static const double aiPaneDefaultWidth = 420;
  static const double aiPaneMinWidth = 260;
  static const double aiPaneMaxWidth = 900;

  /// 阅读区至少要留的宽度：面板再宽也不能把正文挤没
  static const double readerMinWidth = 360;

  /// 三栏（文件树 + 正文 + AI 面板）都放得下的最小窗口宽度；
  /// 比这个窄就让 AI 面板占满内容区，否则正文会被挤成一条缝（手机 / 竖屏平板）。
  static const double threeColumnMinWidth =
      280 + readerMinWidth + aiPaneMinWidth;

  /// AI 面板是否打开（右侧内嵌 DeepSeek）
  bool aiOpen = false;
  double aiWidth = aiPaneDefaultWidth;

  /// 正在拖动分栏：拖动期间要藏起原生网页，否则指针事件被它吃掉
  bool aiDragging = false;

  /// Flutter 自己弹的浮层（菜单/对话框/下拉）层数。原生网页是**独立的原生子窗口**，
  /// 永远盖在 Flutter 之上，所以浮层弹出时必须先把网页藏起来，否则菜单会被盖住。
  /// 初始为 1：home 路由本身占一层，>1 才说明有浮层。
  int overlayDepth = 1;

  /// 待处理的「问 AI」请求：选中内容 → 内置 DeepSeek 面板。
  /// [submit] = true 表示开新对话并直接提问（把内容放进去就发出去），
  /// false 表示只把内容放进新对话的输入框，由用户自己改完再发。
  AiAsk? aiPendingAsk;

  /// 把一段文字送进内置 AI 面板（必要时自动打开面板）。
  void askAi(String text, {required bool submit}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    aiPendingAsk = AiAsk(trimmed, submit: submit);
    if (!aiOpen) {
      aiOpen = true;
      session.aiPanelOpen = true;
      _scheduleSave();
    }
    notifyListeners();
  }

  /// 面板取走待处理请求（取走后置空，避免重复发送）
  AiAsk? takePendingAsk() {
    final a = aiPendingAsk;
    aiPendingAsk = null;
    return a;
  }

  /// 安卓「所有文件访问」授权状态（null = 非安卓 / 未知）。
  /// Flutter 版把目录当普通路径交给 Rust 扫描，没这个权限就扫不到 .md。
  bool? allFilesAccess;

  /// 重新查询「所有文件访问」（授权入口在系统设置里，回来时要再查一次）
  Future<void> refreshAllFilesAccess() async {
    if (!AndroidStorage.applicable) return;
    final v = await AndroidStorage.hasAllFilesAccess();
    if (v == allFilesAccess) return;
    allFilesAccess = v;
    notifyListeners();
  }

  /// 阅读区当前选中的文字（用于 AI 面板的「带入提问框」）。
  /// 用独立的 ValueNotifier 而不是 notifyListeners：拖选时选区每帧都在变，
  /// 走全局通知会让整个界面（含文件树、阅读区）跟着每帧重建。
  final ValueNotifier<String?> selection = ValueNotifier<String?>(null);

  String? get selectionText => selection.value;

  /// 原生网页此刻是否应该可见
  bool get aiNativeVisible => aiOpen && !aiDragging && overlayDepth <= 1;

  /// 面板占宽：窗口太窄时往下压，保证阅读区不被挤没
  double aiPaneWidthFor(double windowWidth) {
    final maxW = (windowWidth - readerMinWidth)
        .clamp(aiPaneMinWidth, aiPaneMaxWidth)
        .toDouble();
    return aiWidth.clamp(aiPaneMinWidth, maxW).toDouble();
  }

  void toggleAi() {
    aiOpen = !aiOpen;
    session.aiPanelOpen = aiOpen;
    _scheduleSave();
    notifyListeners();
  }

  void setAiWidth(double v) {
    final next = v.clamp(aiPaneMinWidth, aiPaneMaxWidth).toDouble();
    if (next == aiWidth) return;
    aiWidth = next;
    session.aiPanelWidth = aiWidth.round();
    _scheduleSave();
    notifyListeners();
  }

  void setAiDragging(bool v) {
    if (aiDragging == v) return;
    aiDragging = v;
    notifyListeners();
  }

  void setOverlayDepth(int depth) {
    final next = depth < 1 ? 1 : depth;
    if (next == overlayDepth) return;
    overlayDepth = next;
    notifyListeners();
  }

  /// 阅读区选中文字变化。
  ///
  /// **刻意不因为"选区被折叠"就清空**：安卓上点空白处时，第一下会同时收起
  /// 系统的选词菜单并折叠选区，如果这里立刻清空，「带入提问框」按钮会在同一拍里
  /// 变成禁用，用户永远点不上。所以只刷新非空选区，切换文档时才清。
  /// 故意不 notifyListeners：见 [selection] 的说明。
  void setSelection(String? text) {
    final trimmed = text?.trim();
    if (trimmed == null || trimmed.isEmpty) return; // 折叠/清空不改动已记下的选区
    if (trimmed == selection.value) return;
    selection.value = trimmed;
  }

  /// 切换文档 / 关闭面板时丢弃上一次的选区（避免把 A 文档的句子带进 B 文档的提问）
  void clearSelection() {
    if (selection.value == null) return;
    selection.value = null;
  }

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
      // 移动端要先解析出可写的配置目录，否则会话（含 AI 面板开关）存不下来
      await NativeCore.resolveConfigDir();
      await refreshAllFilesAccess();
      session = NativeCore.loadSession(NativeCore.configDir());
      themeMode = switch (session.theme) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      fontSize = (session.fontSize ?? 15).toDouble().clamp(13, 21);
      sortMode = SortMode.fromId(session.sortMode);
      aiOpen = session.aiPanelOpen ?? false;
      aiWidth = (session.aiPanelWidth ?? aiPaneDefaultWidth)
          .toDouble()
          .clamp(aiPaneMinWidth, aiPaneMaxWidth)
          .toDouble();
    } catch (e) {
      _toast('会话读取失败：$e');
    }
    notifyListeners();

    // 可选：启动即打开右侧 AI 面板（自动化验证 / 手动调试用）
    if (Platform.environment['MDREADER_AI'] == '1') {
      aiOpen = true;
      session.aiPanelOpen = true;
      session.aiPanelWidth = aiWidth.round();
      _scheduleSave();
      notifyListeners();
    }

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
    if ((tree?.mdCount ?? 0) == 0 && allFilesAccess == false) {
      // 目录能选中却一篇都没有：多半是没给「所有文件访问」
      _toast('扫不到文档：请在「所有文件访问」里允许本应用');
    }

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
      if (activeIndex != existing) clearSelection();
      activeIndex = existing;
      if (seek) tabs[existing].seekPending = true;
      notifyListeners();
      return;
    }
    clearSelection();
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
    if (activeIndex != i) clearSelection();
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

  /// 工具栏右侧的短提示（AI 面板的反馈也走这里：原生网页会盖住面板内部的
  /// 任何 Flutter 内容，所以提示必须显示在面板之外）。
  void showToast(String msg, {Duration duration = const Duration(seconds: 2)}) {
    toast = msg;
    notifyListeners();
    Future.delayed(duration, () {
      if (toast == msg) {
        toast = null;
        notifyListeners();
      }
    });
  }

  void _toast(String msg) => showToast(msg);

  @override
  void dispose() {
    _saveTimer?.cancel();
    _lifecycle?.dispose();
    selection.dispose();
    super.dispose();
  }
}
