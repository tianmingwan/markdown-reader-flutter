// 主界面：工具栏 + 文件树 + 多标签 + 虚拟滚动阅读区 + 搜索 + 状态栏。
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'ai/ai_pane.dart';
import 'core/android_storage.dart';
import 'core/models.dart';
import 'render/block_render.dart';
import 'render/inline_render.dart';
import 'state.dart';

/// Ctrl+F：打开应用内全文搜索（走 Rust 后端，覆盖整篇文档，
/// 不像浏览器原生 Ctrl+F 在大文档虚拟滚动下只能命中已渲染窗口）
class OpenSearchIntent extends Intent {
  const OpenSearchIntent();
}

class CloseSearchIntent extends Intent {
  const CloseSearchIntent();
}

/// Ctrl+P：快速打开（模糊匹配当前文件夹里的文档，大库找文件不去树上翻）
class QuickOpenIntent extends Intent {
  const QuickOpenIntent();
}

/// Ctrl+W：关闭当前标签
class CloseTabIntent extends Intent {
  const CloseTabIntent();
}

/// 过滤掉系统/第三方塞进选中菜单的「文本处理」项。
///
/// 安卓上 `ACTION_PROCESS_TEXT` 的处理器（联想 ROM 的"智能识别"、爱奇艺搜索、
/// 朗读、在 Via 中搜索、搜视频…）会被 Flutter 以 `ContextMenuButtonType.custom`
/// 的形式并进选中菜单。用户只想用内置 DeepSeek，所以这些一律不显示。
/// 复制 / 分享 / 全选这类内置动作（类型不是 custom）保持原样。
List<ContextMenuButtonItem> filteredSelectionMenuItems(
  List<ContextMenuButtonItem> items,
) =>
    items.where((b) => b.type != ContextMenuButtonType.custom).toList();

/// Ctrl+Shift+A：开关右侧 AI 搜索分栏
class ToggleAiIntent extends Intent {
  const ToggleAiIntent();
}

/// 浮层感知：原生网页是独立子窗口，永远盖在 Flutter 之上，
/// 所以 Flutter 自己弹菜单/对话框时必须先把网页藏起来（见 AppState.overlayDepth）。
class AiOverlayObserver extends NavigatorObserver {
  final AppState state;
  AiOverlayObserver(this.state);
  int _depth = 1; // home 路由本身占一层

  void _sync(int depth) {
    _depth = depth < 1 ? 1 : depth;
    state.setOverlayDepth(_depth);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // 首帧里 push 的初始路由不能在 build 期间触发重建
    if (_depth == 1 && previousRoute == null) return;
    _sync(_depth + 1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sync(_depth - 1);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _sync(_depth - 1);
  }
}

/// 快捷键层（独立出来便于测试）。
/// Esc 两级语义：搜索面板开着 → 收起面板（正文高亮保留）；
/// 面板已收但仍有高亮 → 清除高亮。
class AppShortcuts extends StatelessWidget {
  final AppState state;
  final Widget child;
  const AppShortcuts({super.key, required this.state, required this.child});

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyF, control: true):
            OpenSearchIntent(),
        SingleActivator(LogicalKeyboardKey.escape): CloseSearchIntent(),
        SingleActivator(LogicalKeyboardKey.keyA,
            control: true, shift: true): ToggleAiIntent(),
        SingleActivator(LogicalKeyboardKey.keyP, control: true):
            QuickOpenIntent(),
        SingleActivator(LogicalKeyboardKey.keyW, control: true):
            CloseTabIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          OpenSearchIntent: CallbackAction<OpenSearchIntent>(
            onInvoke: (_) {
              state.openSearch();
              if (!state.sidebarOpen) state.toggleSidebar();
              return null;
            },
          ),
          ToggleAiIntent: CallbackAction<ToggleAiIntent>(
            onInvoke: (_) {
              state.toggleAi();
              return null;
            },
          ),
          QuickOpenIntent: CallbackAction<QuickOpenIntent>(
            onInvoke: (_) {
              // 这里的 context 来自 AppShortcuts.build（在 Navigator 之下），
              // 每次重建闭包都会拿到最新的
              if (state.root != null) {
                showQuickOpen(context, state);
              }
              return null;
            },
          ),
          CloseTabIntent: CallbackAction<CloseTabIntent>(
            onInvoke: (_) {
              if (state.activeIndex >= 0) state.closeTab(state.activeIndex);
              return null;
            },
          ),
          CloseSearchIntent: CallbackAction<CloseSearchIntent>(
            onInvoke: (_) {
              if (state.searchOpen) {
                state.closeSearch();
              } else if (state.outlineOpen) {
                state.toggleOutline();
              } else if (state.highlightQuery != null) {
                state.clearSearch();
              }
              return null;
            },
          ),
        },
        child: Focus(autofocus: true, child: child),
      ),
    );
  }
}

class MarkdownReaderApp extends StatefulWidget {
  const MarkdownReaderApp({super.key});

  @override
  State<MarkdownReaderApp> createState() => _MarkdownReaderAppState();
}

class _MarkdownReaderAppState extends State<MarkdownReaderApp> {
  final AppState state = AppState();
  late final AiOverlayObserver _aiObserver = AiOverlayObserver(state);

  @override
  void initState() {
    super.initState();
    state.boot();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => MaterialApp(
        title: 'markdown阅读器',
        debugShowCheckedModeBanner: false,
        navigatorObservers: [_aiObserver],
        themeMode: state.themeMode,
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF3B6FD4),
          brightness: Brightness.light,
          scaffoldBackgroundColor: const Color(0xFFFFFFFF),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: const Color(0xFF3B6FD4),
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF17191C),
        ),
        home: AppShortcuts(
          state: state,
          child: HomePage(state: state),
        ),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  final AppState state;
  const HomePage({super.key, required this.state});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 授权「所有文件访问」要跳系统设置页，回到前台时重新查询：
  /// 授权成功就顺手把当前目录重扫一遍（之前是 0 篇）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final before = s.allFilesAccess;
    s.refreshAllFilesAccess().then((_) {
      if (before == false && s.allFilesAccess == true && mounted) {
        s.showToast('已获得「所有文件访问」权限',
            duration: const Duration(seconds: 4));
        if (s.root != null) s.refreshTree();
      }
    });
  }

  Future<void> _pickFolder() async {
    // 安卓：没给「所有文件访问」的话，选中的目录会被扫成 0 篇，先引导授权
    if (AndroidStorage.applicable && s.allFilesAccess == false) {
      await _askAllFilesAccess();
      return;
    }
    final p = await getDirectoryPath();
    if (p != null) await s.openRoot(p);
  }

  /// 说明为什么需要这个权限，并把用户送到系统设置页
  Future<void> _askAllFilesAccess() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要「所有文件访问」权限'),
        content: const Text(
          '安卓 11 起，应用默认不能直接读取存储卡里的文档，'
          '选中文件夹也会显示 0 篇。\n\n'
          '请在接下来的系统设置页里打开「允许管理所有文件」（不同 ROM 文案略有差异），'
          '返回本应用后会自动重扫。',
          style: TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('去授权'),
          ),
        ],
      ),
    );
    if (go == true) await AndroidStorage.requestAllFilesAccess();
  }

  @override
  Widget build(BuildContext context) {
    final windowW = MediaQuery.of(context).size.width;
    // 窄屏（手机 / 竖屏平板）：分栏直接占满内容区，否则正文会被挤成一条缝
    final takeover = s.aiOpen && windowW < AppState.threeColumnMinWidth;
    return PopScope(
      // Android 返回键：先关 AI 面板 / 搜索面板，都没有才退出应用
      canPop: !s.aiOpen && !s.searchOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (s.aiOpen) {
          s.toggleAi();
        } else if (s.searchOpen) {
          s.closeSearch();
        }
      },
      child: Scaffold(
        appBar: _buildAppBar(),
        body: Column(
          children: [
            Expanded(
              child: takeover
                  ? AiPane(
                      state: s,
                      width: windowW,
                      compact: true,
                    )
                  : Row(
                      children: [
                        if (s.sidebarOpen) ...[
                          SizedBox(
                            width: 280,
                            child: s.searchOpen
                                ? SearchPanel(state: s)
                                : s.outlineOpen
                                    ? OutlinePanel(state: s)
                                    : FileTreePanel(
                                        state: s, onPickFolder: _pickFolder),
                          ),
                          const VerticalDivider(width: 1),
                        ],
                        Expanded(child: _buildMain()),
                        if (s.aiOpen) ...[
                          AiPaneResizer(state: s),
                          AiPane(state: s, width: _aiPaneWidth(context)),
                        ],
                      ],
                    ),
            ),
            if (s.tabs.isNotEmpty) _buildStatusBar(),
          ],
        ),
      ),
    );
  }

  /// 面板占宽：窗口太窄时往下压，保证阅读区不被挤没
  double _aiPaneWidth(BuildContext context) =>
      s.aiPaneWidthFor(MediaQuery.of(context).size.width);

  /// 打开文件夹 + 最近打开历史（换文件夹的入口：
  /// 之前的历史只藏在欢迎页，标签一开就永远看不到，等于没有）
  Widget _buildFolderMenu() {
    return PopupMenuButton<String>(
      tooltip: '打开文件夹（含最近打开）',
      icon: const Icon(Icons.folder_open),
      onSelected: (v) {
        if (v == '__pick__') {
          _pickFolder();
        } else {
          s.openRoot(v);
        }
      },
      itemBuilder: (ctx) {
        final t = Theme.of(ctx);
        final items = <PopupMenuEntry<String>>[
          const PopupMenuItem(
            value: '__pick__',
            child: Row(
              children: [
                Icon(Icons.create_new_folder_outlined, size: 16),
                SizedBox(width: 8),
                Text('打开文件夹…', style: TextStyle(fontSize: 12.5)),
              ],
            ),
          ),
        ];
        final recents = s.session.recentRoots;
        if (recents.isNotEmpty) {
          items.add(const PopupMenuDivider());
          for (final r in recents) {
            final exists = Directory(r.loc).existsSync();
            final current = s.root == r.loc;
            items.add(PopupMenuItem(
              value: r.loc,
              enabled: exists && !current,
              child: Row(
                children: [
                  Icon(
                    current
                        ? Icons.check
                        : exists
                            ? Icons.history
                            : Icons.folder_off_outlined,
                    size: 15,
                    color: exists ? t.hintColor : t.disabledColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      r.loc,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: exists ? null : t.disabledColor,
                      ),
                    ),
                  ),
                ],
              ),
            ));
          }
        }
        return items;
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final t = Theme.of(context);
    return AppBar(
      toolbarHeight: 46,
      elevation: 0,
      scrolledUnderElevation: 1,
      titleSpacing: 8,
      title: Row(
        children: [
          IconButton(
            tooltip: s.sidebarOpen ? '收起侧栏' : '展开侧栏',
            icon: Icon(s.sidebarOpen ? Icons.menu_open : Icons.menu),
            onPressed: s.toggleSidebar,
          ),
          _buildFolderMenu(),
          IconButton(
            tooltip: '刷新目录',
            icon: const Icon(Icons.refresh),
            onPressed: s.root == null ? null : () => s.refreshTree(),
          ),
          IconButton(
            tooltip: '快速打开（Ctrl+P）',
            icon: const Icon(Icons.bolt_outlined),
            onPressed:
                s.root == null ? null : () => showQuickOpen(context, s),
          ),
          IconButton(
            tooltip: '全文搜索',
            icon: Icon(s.searchOpen ? Icons.search_off : Icons.search),
            onPressed: () {
              if (s.searchOpen) {
                s.closeSearch();
              } else {
                s.openSearch();
                if (!s.sidebarOpen) s.toggleSidebar();
              }
            },
          ),
          IconButton(
            tooltip: s.outlineOpen ? '关闭大纲' : '大纲（按标题跳转）',
            icon: Icon(s.outlineOpen ? Icons.toc : Icons.toc_outlined),
            color:
                s.outlineOpen ? Theme.of(context).colorScheme.primary : null,
            onPressed: () {
              s.toggleOutline();
              if (s.outlineOpen && !s.sidebarOpen) s.toggleSidebar();
            },
          ),
          IconButton(
            tooltip: s.aiOpen
                ? '关闭 AI 搜索面板'
                : 'AI 搜索：在右侧打开 DeepSeek 对话',
            icon: Icon(
              s.aiOpen ? Icons.smart_toy : Icons.smart_toy_outlined,
            ),
            color: s.aiOpen ? Theme.of(context).colorScheme.primary : null,
            onPressed: s.toggleAi,
          ),
          if (s.highlightQuery != null && !s.searchOpen) ...[
            const Spacer(),
            Flexible(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: MdStyle.of(context, 12).markBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '高亮：${s.highlightQuery}',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: MdStyle.of(context, 12).markFg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: s.clearSearch,
                    child: Icon(Icons.close,
                        size: 13, color: MdStyle.of(context, 12).markFg),
                  ),
                ],
              ),
            )),
          ],
          if (s.toast != null)
            Flexible(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text(
                  s.toast!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.colorScheme.primary),
                ),
              ),
            ),
          // 字号
          IconButton(
            tooltip: '减小字号',
            icon: const Icon(Icons.text_decrease),
            onPressed: () => s.setFontSize(s.fontSize - 1),
          ),
          Text('${s.fontSize.round()}', style: const TextStyle(fontSize: 12)),
          IconButton(
            tooltip: '增大字号',
            icon: const Icon(Icons.text_increase),
            onPressed: () => s.setFontSize(s.fontSize + 1),
          ),
          // 主题
          PopupMenuButton<String>(
            tooltip: '主题',
            icon: const Icon(Icons.brightness_6),
            onSelected: (v) => s.setTheme(switch (v) {
              'light' => ThemeMode.light,
              'dark' => ThemeMode.dark,
              _ => ThemeMode.system,
            }),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'system', child: Text('跟随系统')),
              PopupMenuItem(value: 'light', child: Text('浅色')),
              PopupMenuItem(value: 'dark', child: Text('深色')),
            ],
          ),
        ],
      ),
      bottom: s.tabs.isEmpty ? null : PreferredSize(
        preferredSize: const Size.fromHeight(38),
        child: _buildTabStrip(),
      ),
    );
  }

  Widget _buildTabStrip() {
    final t = Theme.of(context);
    return Container(
      height: 38,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: t.dividerColor)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: s.tabs.length,
        itemBuilder: (context, i) {
          final tab = s.tabs[i];
          final active = i == s.activeIndex;
          return Tooltip(
            message: tab.path,
            waitDuration: const Duration(milliseconds: 500),
            child: GestureDetector(
              // 桌面惯例：中键点标签直接关闭（浏览器/编辑器的肌肉记忆）
              onTertiaryTapUp: (_) => s.closeTab(i),
              child: InkWell(
                onTap: () => s.activate(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: active ? t.colorScheme.primary : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        tab.name,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                          color: active ? t.colorScheme.primary : t.colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () => s.closeTab(i),
                        child: Icon(Icons.close, size: 14, color: t.hintColor),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMain() {
    final tab = s.active;
    if (s.scanning) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tab == null) {
      return _welcome();
    }
    if (tab.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tab.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('打开失败：${tab.error}'),
        ),
      );
    }
    return ReadView(state: s, tab: tab);
  }

  Widget _welcome() {
    final t = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.description_outlined, size: 56, color: t.hintColor),
          const SizedBox(height: 14),
          Text('Markdown 阅读器（Flutter + Rust）',
              style: TextStyle(fontSize: 16, color: t.hintColor)),
          const SizedBox(height: 8),
          Text(
            '打开一个文件夹开始阅读',
            style: TextStyle(fontSize: 13, color: t.hintColor),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _pickFolder,
            icon: const Icon(Icons.folder_open),
            label: const Text('打开文件夹'),
          ),
          if (s.session.recentRoots.isNotEmpty) ...[
            const SizedBox(height: 26),
            Text('最近打开',
                style: TextStyle(fontSize: 12, color: t.hintColor)),
            const SizedBox(height: 8),
            for (final r in s.session.recentRoots.take(5))
              if (Directory(r.loc).existsSync())
                TextButton(
                  onPressed: () => s.openRoot(r.loc),
                  child: Text(r.loc,
                      style: const TextStyle(fontSize: 12.5)),
                ),
          ],
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    final tab = s.active;
    final t = Theme.of(context);
    final words = tab?.doc?.words ?? 0;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        border: Border(top: BorderSide(color: t.dividerColor)),
      ),
      child: Row(
        children: [
          if (s.highlightQuery != null) ...[
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: MdStyle.of(context, 12).markBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '高亮「${s.highlightQuery}」',
                    style: TextStyle(
                      fontSize: 11,
                      color: MdStyle.of(context, 12).markFg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 3),
                  InkWell(
                    onTap: s.clearSearch,
                    child: Icon(Icons.close,
                        size: 12, color: MdStyle.of(context, 12).markFg),
                  ),
                ],
              ),
            ),
          ],
          Expanded(
            child: Text(
              tab?.path ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: t.hintColor),
            ),
          ),
          if (words > 0)
            Text('$words 字', style: TextStyle(fontSize: 11.5, color: t.hintColor)),
          if (tab != null) ...[
            const SizedBox(width: 14),
            Text('${(tab.scrollRatio * 100).toStringAsFixed(0)}%',
                style: TextStyle(fontSize: 11.5, color: t.hintColor)),
          ],
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ 阅读区

class ReadView extends StatefulWidget {
  final AppState state;
  final TabItem tab;
  const ReadView({super.key, required this.state, required this.tab});

  @override
  State<ReadView> createState() => _ReadViewState();
}

class _ReadViewState extends State<ReadView> {
  final ScrollController _ctl = ScrollController();
  String? _restoredFor;
  Timer? _saveTimer;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _ctl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restore();
      _maybeSeek();
    });
  }

  @override
  void didUpdateWidget(covariant ReadView old) {
    super.didUpdateWidget(old);
    final docJustReady = old.tab.doc == null && widget.tab.doc != null;
    if (old.tab.path != widget.tab.path || docJustReady) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restore();
        _maybeSeek();
      });
    }
  }

  /// 由搜索结果打开时，滚动到首个命中块（块高不等，用比例近似定位）
  void _maybeSeek() {
    final tab = widget.tab;
    if (!tab.seekPending || !_ctl.hasClients) return;
    final q = widget.state.highlightQuery;
    final doc = tab.doc;
    if (q == null || q.isEmpty || doc == null || doc.blockCount == 0) return;
    tab.seekPending = false;

    final lq = q.toLowerCase();
    var hit = -1;
    final total = doc.blockCount;
    for (var i = 0; i < total; i++) {
      if (rawBlockText(doc.rawBlocks[i]).toLowerCase().contains(lq)) {
        hit = i;
        break;
      }
    }
    if (hit < 0) return;

    _jumpToBlock(hit, total);
  }

  /// 由大纲（TOC）点击触发：滚动到第 idx 个顶层块。
  void _maybeOutlineSeek() {
    final tab = widget.tab;
    final idx = tab.seekBlockIndex;
    if (idx == null || !_ctl.hasClients) return;
    final doc = tab.doc;
    if (doc == null || doc.blockCount == 0) return;
    tab.seekBlockIndex = null;
    _jumpToBlock(idx, doc.blockCount);
  }

  /// 按比例近似定位到某个顶层块。
  ///
  /// 块高不等，而 ListView 的 maxScrollExtent 首帧只是估算值（偏低），
  /// 所以与滚动恢复一样做多轮收敛：随着总高测量变准，落点跟着收敛。
  void _jumpToBlock(int idx, int total) {
    final ratio = (idx / total).clamp(0.0, 1.0);
    var pass = 0;
    void step() {
      if (!_ctl.hasClients || !mounted || pass >= 4) return;
      final max = _ctl.position.maxScrollExtent;
      if (max > 0) _ctl.jumpTo((max * ratio).clamp(0.0, max));
      pass++;
      if (pass < 4) {
        Timer(const Duration(milliseconds: 80), step);
      }
    }

    step();
  }

  /// 恢复滚动位置。
  ///
  /// 不能用「比例 × 首帧 maxScrollExtent」一次跳到位：ListView 是不定高列表，
  /// 首帧的 maxScrollExtent 只是**按可见项估算**的总高，实测比稳定值低约 26%
  /// （法律 2082 题：首帧 1,137,267 → 稳定 1,546,197），
  /// 于是 50% 的位置会落到 36.8% 处——文档越深偏得越多。
  /// 这里改为多轮收敛：每轮用**当前最新的** maxScrollExtent 重跳同一比例，
  /// 随着列表测量到的项越来越多，max 收敛，落点也随之收敛。
  void _restore() {
    final dbg = Platform.environment['MDREADER_DEBUG'] == '1';
    if (!_ctl.hasClients) {
      if (dbg) print('[restore] 取消：无客户端');
      return;
    }
    if (_restoredFor == widget.tab.path) return;
    _restoredFor = widget.tab.path;
    final ratio = widget.tab.scrollRatio;
    if (ratio <= 0.001) {
      if (dbg) print('[restore] 比例为 0，留在顶部');
      return;
    }
    if (dbg) {
      print('[restore] ratio=$ratio firstMax=${_ctl.position.maxScrollExtent}');
    }
    _restoreConverge(ratio);
  }

  Future<void> _restoreConverge(double ratio) async {
    final dbg = Platform.environment['MDREADER_DEBUG'] == '1';
    _restoring = true;
    try {
      var lastMax = 0.0;
      for (var pass = 0; pass < 6; pass++) {
        if (!_ctl.hasClients || !mounted) return;
        final max = _ctl.position.maxScrollExtent;
        if (max <= 0) {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          continue;
        }
        // 总高已稳定（变化 <0.5%）即认为落点收敛，不必再等
        if (lastMax > 0 && (max - lastMax).abs() / max < 0.005) break;
        lastMax = max;
        final target = (max * ratio).clamp(0.0, max);
        _ctl.jumpTo(target);
        if (dbg && pass == 0) print('[restore] 第 1 轮 jumpTo=$target (max=$max)');
        await Future<void>.delayed(const Duration(milliseconds: 90));
      }
      // 循环退出时总高可能刚又变了一点，等布局稳定后做最后一次校正
      await Future<void>.delayed(const Duration(milliseconds: 160));
      if (_ctl.hasClients && mounted) {
        final m = _ctl.position.maxScrollExtent;
        if (m > 0) _ctl.jumpTo((m * ratio).clamp(0.0, m));
      }
    } finally {
      _restoring = false;
      if (dbg && _ctl.hasClients) {
        final m = _ctl.position.maxScrollExtent;
        print('[restore] 收敛后 offset=${_ctl.offset} max=$m '
            'realRatio=${(_ctl.offset / (m <= 0 ? 1 : m)).toStringAsFixed(4)} '
            '（期望 $ratio）');
      }
    }
  }

  void _onScroll() {
    if (!_ctl.hasClients) return;
    // 恢复过程中列表会边跳边修正高度，此时写回会把中间态当成用户位置
    if (_restoring) return;
    final max = _ctl.position.maxScrollExtent;
    final ratio = max <= 0 ? 0.0 : (_ctl.offset / max).clamp(0.0, 1.0);
    widget.tab.scrollRatio = ratio;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      widget.state.rememberScroll(widget.tab.path, ratio);
    });
  }

  void _handleLink(String href, bool internal) {
    if (internal) {
      if (File(href).existsSync()) {
        widget.state.openTab(href);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件不存在：$href')),
        );
      }
      return;
    }
    launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.tab.doc;
    if (doc == null || doc.blockCount == 0) {
      return const Center(child: Text('（空文档）'));
    }
    // 大纲点击可能发生在文档已就绪后（不会走 initState/didUpdateWidget 的钩子），
    // 所以每次构建后都检查一次待跳转
    if (widget.tab.seekBlockIndex != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOutlineSeek());
    }
    final st = MdStyle.of(
      context,
      widget.state.fontSize,
      highlight: widget.state.highlightQuery,
    );
    // 正文列宽按**实际留给阅读区的宽度**算：右侧 AI 分栏打开时不能再按整窗宽度算，
    // 否则文本会一直铺到分栏边上（列宽公式的意义就是留出两侧留白）。
    // 上限 880：中文每行超过 ~45 字阅读效率明显下降，宽屏上宁要留白不要长行。
    final windowW = MediaQuery.of(context).size.width;
    final aiW =
        widget.state.aiOpen ? widget.state.aiPaneWidthFor(windowW) : 0.0;
    final width =
        ((windowW - aiW) * (widget.state.sidebarOpen ? 0.78 : 0.86))
            .clamp(320.0, 880.0);

    return SelectionArea(
      // 选中文字存进 state，供 AI 面板「带入提问框」用。
      // 包在阅读区外层（而不是逐块 SelectableText）才能跨块连选整道题。
      onSelectionChanged: (content) =>
          widget.state.setSelection(content?.plainText),
      // 选中菜单里直接给出「问内置 DeepSeek」两个动作，省得再去找面板按钮
      contextMenuBuilder: (context, region) {
        // getSelectedContent() 不是公开 API，用我们自己捕获的选区（onSelectionChanged）
        final picked = widget.state.selectionText ?? '';
        final has = picked.trim().isNotEmpty;
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: region.contextMenuAnchors,
          // 第三方/ROM 的「文本处理」项已由 filteredSelectionMenuItems 去掉，
          // 剩下的顺序是：复制/分享/全选 → 我们的两项。
          buttonItems: <ContextMenuButtonItem>[
            ...filteredSelectionMenuItems(region.contextMenuButtonItems),
            if (has) ...[
              ContextMenuButtonItem(
                label: '问 DeepSeek',
                onPressed: () {
                  region.hideToolbar();
                  widget.state.askAi(picked, submit: true);
                },
              ),
              ContextMenuButtonItem(
                label: '放进 DeepSeek',
                onPressed: () {
                  region.hideToolbar();
                  widget.state.askAi(picked, submit: false);
                },
              ),
            ],
          ],
        );
      },
      child: Center(
        child: ListView.builder(
          controller: _ctl,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
          itemCount: doc.blockCount,
          itemBuilder: (context, i) {
            return ConstrainedBox(
              constraints: BoxConstraints(maxWidth: width),
              child: buildBlock(
                doc.blockAt(i),
                st,
                onLink: _handleLink,
                folds: widget.state.folds,
                onFoldChanged: () => setState(() {}),
                index: i,
                maxWidth: width,
              ),
            );
          },
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 侧栏：文件树

class FileTreePanel extends StatefulWidget {
  final AppState state;
  final VoidCallback onPickFolder;
  const FileTreePanel(
      {super.key, required this.state, required this.onPickFolder});

  @override
  State<FileTreePanel> createState() => _FileTreePanelState();
}

class _FileTreePanelState extends State<FileTreePanel> {
  final Set<String> expanded = {};

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final t = Theme.of(context);
    if (s.root == null) {
      return Center(
        child: TextButton.icon(
          onPressed: widget.onPickFolder,
          icon: const Icon(Icons.folder_open),
          label: const Text('打开文件夹'),
        ),
      );
    }
    final nodes = sortNodes(s.tree?.children ?? const [], s.sortMode);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  s.tree?.name ?? '',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text('${s.tree?.mdCount ?? 0} md',
                  style: TextStyle(fontSize: 11, color: t.hintColor)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: DropdownButton<SortMode>(
            value: s.sortMode,
            isExpanded: true,
            isDense: true,
            style: TextStyle(fontSize: 12, color: t.colorScheme.onSurface),
            underline: const SizedBox.shrink(),
            items: [
              for (final m in SortMode.values)
                DropdownMenuItem(value: m, child: Text(m.label)),
            ],
            onChanged: (m) {
              if (m != null) s.setSortMode(m);
            },
          ),
        ),
        const Divider(height: 8),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              for (final n in nodes) ..._renderNode(n, 0),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _renderNode(TreeNode n, int depth) {
    final s = widget.state;
    final t = Theme.of(context);
    final isOpen = expanded.contains(n.path);
    final active = s.active?.path == n.path;

    if (!n.isDir) {
      return [
        InkWell(
          onTap: () => s.openTab(n.path),
          child: Container(
            color: active
                ? t.colorScheme.primaryContainer.withValues(alpha: 0.45)
                : null,
            padding: EdgeInsets.only(
                left: 14.0 + depth * 14, top: 5, bottom: 5, right: 8),
            child: Row(
              children: [
                Icon(Icons.article_outlined, size: 14, color: t.hintColor),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    n.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: active
                          ? t.colorScheme.primary
                          : t.colorScheme.onSurface,
                      fontWeight: active ? FontWeight.w600 : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ];
    }

    final kids = sortNodes(n.children, s.sortMode);
    return [
      InkWell(
        onTap: () => setState(() {
          if (!expanded.remove(n.path)) expanded.add(n.path);
        }),
        child: Padding(
          padding: EdgeInsets.only(
              left: 6.0 + depth * 14, top: 5, bottom: 5, right: 8),
          child: Row(
            children: [
              Icon(
                isOpen ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                size: 16,
                color: t.hintColor,
              ),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  n.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
      ),
      if (isOpen)
        for (final c in kids) ..._renderNode(c, depth + 1),
    ];
  }
}

// ------------------------------------------------------------------ 侧栏：搜索

class SearchPanel extends StatefulWidget {
  final AppState state;
  const SearchPanel({super.key, required this.state});

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel> {
  final _ctl = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    // 已有查询词时回填（例如由快捷键/钩子触发的搜索）
    _ctl.text = widget.state.query;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      widget.state.runSearch(v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final t = Theme.of(context);
    final markStyle = MdStyle.of(context, 12);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextField(
            controller: _ctl,
            autofocus: true,
            onChanged: _onChanged,
            decoration: InputDecoration(
              hintText: '搜索文件名或内容…',
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _ctl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        _ctl.clear();
                        s.clearSearch();
                        setState(() {});
                      },
                    ),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (s.searching) const LinearProgressIndicator(minHeight: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Text(
                s.query.isEmpty ? '' : '${s.hits.length} 条命中',
                style: TextStyle(fontSize: 11.5, color: t.hintColor),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: s.hits.length,
            itemBuilder: (context, i) {
              final h = s.hits[i];
              return InkWell(
                onTap: () => s.openTab(h.path, seek: true),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            h.matchedBy == 'name'
                                ? Icons.label_outline
                                : Icons.subject,
                            size: 13,
                            color: t.hintColor,
                          ),
                          const SizedBox(width: 5),
                          Expanded(
                            child: Text(
                              h.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12.5, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                      for (final sn in h.snippets)
                        Padding(
                          padding: const EdgeInsets.only(left: 18, top: 2),
                          child: Text.rich(
                            TextSpan(
                              children: highlightSpans(
                                sn,
                                s.highlightQuery ?? '',
                                TextStyle(fontSize: 11.5, color: t.hintColor),
                                markBg: markStyle.markBg,
                                markFg: markStyle.markFg,
                              ),
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        if (s.hits.isEmpty && s.query.isNotEmpty && !s.searching)
          Padding(
            padding: const EdgeInsets.all(14),
            child: Text('没有命中结果',
                style: TextStyle(fontSize: 12, color: t.hintColor)),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 侧栏：大纲

/// 内联节点 → 纯文本（大纲条目用）
String plainInlineText(List<MdInline> inl) {
  final b = StringBuffer();
  void walk(List<MdInline> xs) {
    for (final x in xs) {
      switch (x) {
        case InlText(:final s):
          b.write(s);
        case InlCode(:final s):
          b.write(s);
        case InlStrong(:final inl) || InlEm(:final inl) || InlStrike(:final inl):
          walk(inl);
        case InlLink(:final inl):
          walk(inl);
        case InlImg(:final alt):
          b.write(alt);
        case InlBr() || InlSoftBr():
          b.write(' ');
        case InlTask():
          break;
      }
    }
  }

  walk(inl);
  return b.toString().trim();
}

/// 一个标题条目：顶层块下标 + 层级 + 文本
typedef OutlineItem = ({int blockIndex, int level, String text});

/// 从渲染好的文档里抽出标题序列（解析结果在 doc 内部有缓存）
List<OutlineItem> outlineOf(RenderedDoc doc) {
  final out = <OutlineItem>[];
  for (var i = 0; i < doc.blockCount; i++) {
    final b = doc.blockAt(i);
    if (b is BlkHeading) {
      final text = plainInlineText(b.inl);
      if (text.isNotEmpty) out.add((blockIndex: i, level: b.level, text: text));
    }
  }
  return out;
}

/// 大纲面板：列出当前文档的标题，点击跳转到对应位置。
/// 长文档（几百页的笔记/题库）没有它只能靠滚轮硬翻。
class OutlinePanel extends StatelessWidget {
  final AppState state;
  const OutlinePanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tab = state.active;
    final doc = tab?.doc;
    if (tab == null || doc == null) {
      return Center(
        child: Text('打开一篇文档后显示大纲',
            style: TextStyle(fontSize: 12.5, color: t.hintColor)),
      );
    }
    final items = outlineOf(doc);
    if (items.isEmpty) {
      return Center(
        child: Text('本文档没有标题',
            style: TextStyle(fontSize: 12.5, color: t.hintColor)),
      );
    }
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
          child: Text(
            '${tab.name} · ${items.length} 个标题',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 12),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final it = items[i];
              return InkWell(
                onTap: () => state.seekToBlock(it.blockIndex),
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 10.0 + (it.level - 1).clamp(0, 5) * 12,
                    right: 8,
                    top: 5,
                    bottom: 5,
                  ),
                  child: Text(
                    it.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: it.level <= 2 ? 12.5 : 12,
                      fontWeight:
                          it.level <= 2 ? FontWeight.w600 : FontWeight.w400,
                      color: it.level <= 2
                          ? t.colorScheme.onSurface
                          : t.hintColor,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 快速打开（Ctrl+P）

/// 打开「快速打开」对话框：模糊匹配当前文件夹里的所有文档。
Future<void> showQuickOpen(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    builder: (_) => QuickOpenDialog(state: state),
  );
}

class QuickOpenDialog extends StatefulWidget {
  final AppState state;
  const QuickOpenDialog({super.key, required this.state});

  @override
  State<QuickOpenDialog> createState() => _QuickOpenDialogState();
}

class _QuickOpenDialogState extends State<QuickOpenDialog> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();

  /// 全部文件（打开对话框时拍平一次，不随输入变化）
  late final List<TreeNode> _all = widget.state.flatFiles();
  String _q = '';
  int _selected = 0;

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 朴素但好用的匹配：文件名优先（前缀 > 包含），路径兜底；
  /// 多个空格分隔的词必须全部命中（"民法 代理" 能筛 "16-民法·民事法律行为与代理.md"）
  List<TreeNode> get _matches {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return _all.take(50).toList();
    final terms = q.split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
    bool hit(String text) {
      final l = text.toLowerCase();
      return terms.every(l.contains);
    }

    final scored = <(int, TreeNode)>[];
    for (final n in _all) {
      final name = n.name.toLowerCase();
      if (hit(n.name)) {
        // 名字命中：前缀命中排最前，越短越靠前
        final prefix = terms.every(name.startsWith) ? 0 : 1;
        scored.add((prefix * 100000 + name.length, n));
      } else if (hit(n.path)) {
        scored.add((200000 + n.path.length, n));
      }
    }
    scored.sort((a, b) => a.$1.compareTo(b.$1));
    return scored.take(50).map((e) => e.$2).toList();
  }

  void _open(TreeNode n) {
    Navigator.of(context).pop();
    widget.state.openTab(n.path);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final m = _matches;
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (_selected + 1).clamp(0, m.length - 1));
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _selected = (_selected - 1).clamp(0, m.length - 1));
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.enter && m.isNotEmpty) {
      _open(m[_selected.clamp(0, m.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = _matches;
    if (_selected >= m.length) _selected = m.isEmpty ? 0 : m.length - 1;
    final root = widget.state.root ?? '';
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 90, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 430),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Focus(
                onKeyEvent: _onKey,
                child: TextField(
                  controller: _ctl,
                  focusNode: _focus,
                  autofocus: true,
                  onChanged: (v) => setState(() {
                    _q = v;
                    _selected = 0;
                  }),
                  decoration: InputDecoration(
                    hintText: '输入文件名快速打开（${_all.length} 篇文档）…',
                    isDense: true,
                    prefixIcon: const Icon(Icons.bolt, size: 18),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
            ),
            Flexible(
              child: m.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text('没有匹配「$_q」的文档',
                          style: TextStyle(fontSize: 12.5, color: t.hintColor)),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: m.length,
                      itemBuilder: (context, i) {
                        final n = m[i];
                        final sel = i == _selected;
                        final rel = n.path.startsWith('$root/')
                            ? n.path.substring(root.length + 1)
                            : n.path;
                        return InkWell(
                          onTap: () => _open(n),
                          child: Container(
                            color: sel
                                ? t.colorScheme.primaryContainer
                                    .withValues(alpha: 0.5)
                                : null,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 7),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  n.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: sel
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                                Text(
                                  rel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11, color: t.hintColor),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: t.dividerColor)),
              ),
              child: Text(
                '↑↓ 选择 · Enter 打开 · Esc 关闭',
                style: TextStyle(fontSize: 11, color: t.hintColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
