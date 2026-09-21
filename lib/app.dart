// 主界面：工具栏 + 文件树 + 多标签 + 虚拟滚动阅读区 + 搜索 + 状态栏。
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/models.dart';
import 'core/native.dart';
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
          CloseSearchIntent: CallbackAction<CloseSearchIntent>(
            onInvoke: (_) {
              if (state.searchOpen) {
                state.closeSearch();
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

class _HomePageState extends State<HomePage> {
  AppState get s => widget.state;

  Future<void> _pickFolder() async {
    final p = await getDirectoryPath();
    if (p != null) await s.openRoot(p);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                if (s.sidebarOpen) ...[
                  SizedBox(
                    width: 280,
                    child: s.searchOpen
                        ? SearchPanel(state: s)
                        : FileTreePanel(state: s, onPickFolder: _pickFolder),
                  ),
                  const VerticalDivider(width: 1),
                ],
                Expanded(child: _buildMain()),
              ],
            ),
          ),
          if (s.tabs.isNotEmpty) _buildStatusBar(),
        ],
      ),
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
          IconButton(
            tooltip: '打开文件夹',
            icon: const Icon(Icons.folder_open),
            onPressed: _pickFolder,
          ),
          IconButton(
            tooltip: '刷新目录',
            icon: const Icon(Icons.refresh),
            onPressed: s.root == null ? null : () => s.refreshTree(),
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
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Text(
                s.toast!,
                style: TextStyle(fontSize: 12, color: t.colorScheme.primary),
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
          return InkWell(
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

    final max = _ctl.position.maxScrollExtent;
    if (max <= 0) return;
    final target = (max * (hit / total)).clamp(0.0, max);
    _ctl.jumpTo(target);
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
    final st = MdStyle.of(
      context,
      widget.state.fontSize,
      highlight: widget.state.highlightQuery,
    );
    final width = (MediaQuery.of(context).size.width *
            (widget.state.sidebarOpen ? 0.78 : 0.86))
        .clamp(320.0, 1180.0);

    return Center(
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
