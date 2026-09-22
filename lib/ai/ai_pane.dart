// 右侧 AI 分栏：头部操作 + 网页区域。
//
// 网页怎么「装进」这一栏，三个平台不一样（见 ai_types.dart 的 AiBackendKind）：
//
// - Android / iOS / macOS：webview_flutter 的平台视图，直接当 widget 放进分栏。
// - Linux：Flutter 桌面端没有 platform view，所以网页是原生层（WebKitGTK）按 Dart
//   给的矩形盖在窗口上的一块**独立原生子窗口**。由此带来两条约束：
//     1. 网页一旦显示就会盖住这块矩形里所有 Flutter 内容 → 提示信息一律走工具栏
//        toast（面板之外），面板内部只画「网页还没盖上时」才需要看的东西；
//     2. 它是独立窗口，会吃掉指针事件 → 拖动分栏、Flutter 弹菜单/对话框时必须先
//        把它藏起来，否则分栏「粘住」、菜单被盖住。
// - Windows：没有内嵌能力，退化成「用系统浏览器打开」。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/ai_panel_native.dart';
import '../core/native.dart';
import '../state.dart';
import 'ai_types.dart';
import 'ai_webview.dart';

const String kDeepSeekUrl = 'https://chat.deepseek.com/';

/// 头部高度：Linux 上原生网页从这条线以下开始，所以头部按钮永远可点。
const double kAiPaneHeaderHeight = 34;

/// 右侧 AI 分栏。
class AiPane extends StatefulWidget {
  final AppState state;
  final double width;

  /// 窄屏（手机/竖屏平板）下面板会占满整个内容区，此时关闭按钮显示为返回箭头
  final bool compact;

  /// 仅测试用：覆盖平台探测结果（真机上按平台自动判定）
  final AiBackendKind? backendOverride;

  const AiPane({
    super.key,
    required this.state,
    required this.width,
    this.compact = false,
    this.backendOverride,
  });

  @override
  State<AiPane> createState() => _AiPaneState();
}

class _AiPaneState extends State<AiPane> with WidgetsBindingObserver {
  final GlobalKey _hostKey = GlobalKey();

  late final AiBackendKind _backend = widget.backendOverride ?? detectAiBackend();
  bool get _isNative => _backend == AiBackendKind.nativeOverlay;

  /// Linux：原生网页是否已经建好（第一次 open 成功后为 true，之后只更新矩形）
  bool _opened = false;
  bool _unsupported = false;
  bool _nativeVisible = false;

  /// idle | loading | ready | failed
  String _loadState = 'idle';
  String? _loadError;

  /// 是否成功就绪过（仅 Linux 用）：首次加载时故意先不显示原生网页，让 Flutter 侧的
  /// 「正在打开 DeepSeek…」可见（原生窗口一显示就会把这块盖住）；
  /// 就绪过一次之后，站内跳转引起的重新加载不再闪烁。
  bool _everReady = false;

  double _zoom = 1.0;

  /// 上一次同步给原生的矩形：重建很频繁（每次 state 变化都会走 didUpdateWidget），
  /// 矩形没变就不必再跨平台调一次。
  Rect? _lastSentRect;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _unsupported = _backend == AiBackendKind.external;
    if (_backend == AiBackendKind.inAppWebView) {
      AiWebView.onLoadChanged = _onLoadChanged;
      AiWebView.onPromptResult = _onPromptResult;
      // 平台视图不需要等布局，直接建
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureInAppWebView();
        _consumePendingAsk();
      });
      return;
    }
    if (_isNative) {
      WidgetsBinding.instance.addObserver(this);
      AiPanelNative.onLoadChanged = _onLoadChanged;
      AiPanelNative.onPromptResult = _onPromptResult;
      // 第一次布局完成后才知道占位区在哪
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncNative());
    }
  }

  @override
  void dispose() {
    if (_backend == AiBackendKind.inAppWebView) {
      // 控制器留着（静态持有）：网页与登录态都不销毁，重开即用。
      if (AiWebView.onLoadChanged == _onLoadChanged) {
        AiWebView.onLoadChanged = null;
      }
      if (AiWebView.onPromptResult == _onPromptResult) {
        AiWebView.onPromptResult = null;
      }
    } else if (_isNative) {
      if (AiPanelNative.onLoadChanged == _onLoadChanged) {
        AiPanelNative.onLoadChanged = null;
      }
      if (AiPanelNative.onPromptResult == _onPromptResult) {
        AiPanelNative.onPromptResult = null;
      }
      WidgetsBinding.instance.removeObserver(this);
      // 面板关掉只是隐藏原生网页：登录态与对话内容都留着，重开即用。
      AiPanelNative.setVisible(false);
    }
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 窗口缩放 / 显示器 DPI 变化（只有原生覆盖层需要重新贴合）
    if (_isNative) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncNative());
    }
  }

  @override
  void didUpdateWidget(covariant AiPane old) {
    super.didUpdateWidget(old);
    if (_isNative) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncNative());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumePendingAsk());
  }

  /// 处理"选中内容 → 内置 AI"的请求（由 AppState.askAi 投递）。
  ///
  /// 两种语义：submit=true 开新对话并直接提问；false 只把内容放进新对话输入框。
  Future<void> _consumePendingAsk() async {
    if (!mounted) return;
    final ask = s.takePendingAsk();
    if (ask == null) return;

    if (_backend == AiBackendKind.inAppWebView) {
      AiWebView.ensure(kDeepSeekUrl);
      // 新对话要先导航，填内容由 webview 在 onPageFinished 后补上
      AiWebView.askInNewChat(ask.text, submit: ask.submit);
      s.showToast(
        ask.submit ? '已在新对话里提问…' : '已把内容放进新对话的输入框',
        duration: const Duration(seconds: 4),
      );
      return;
    }

    if (_backend == AiBackendKind.external) {
      Clipboard.setData(ClipboardData(text: ask.text));
      s.showToast('本平台不支持内嵌面板，已复制内容到剪贴板');
      return;
    }

    // Linux：原生侧会排队，页面加载完自动填入（submit 时再自动发送）
    final ok = await AiPanelNative.prompt(ask.text,
        submit: ask.submit, newChat: true);
    if (!mounted) return;
    if (!ok) {
      // 原生面板还没建好：放回去，等 open 成功后重试
      s.aiPendingAsk ??= ask;
      return;
    }
    s.showToast(
      ask.submit ? '已在新对话里提问…' : '已把内容放进新对话的输入框',
      duration: const Duration(seconds: 4),
    );
  }

  // ---------------------------------------------------------- 应用内 WebView

  void _ensureInAppWebView() {
    if (!mounted) return;
    final existed = AiWebView.hasController;
    AiWebView.ensure(kDeepSeekUrl);
    if (!existed) {
      setState(() => _loadState = 'loading');
    }
  }

  // ---------------------------------------------------------- 原生同步（Linux）

  /// 占位区在窗口里的矩形，换算成设备像素（GTK 侧用的单位）。
  Rect? _hostRectPx() {
    final box = _hostKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final origin = box.localToGlobal(Offset.zero);
    final dpr = View.of(context).devicePixelRatio;
    return Rect.fromLTWH(
      origin.dx * dpr,
      origin.dy * dpr,
      box.size.width * dpr,
      box.size.height * dpr,
    );
  }

  Future<void> _syncNative() async {
    if (!mounted || !_isNative) return;
    final rect = _hostRectPx();
    if (rect == null) return;

    final want = s.aiNativeVisible && (_everReady || _loadState == 'ready');
    if (rect.width < 40 || rect.height < 40) {
      if (_nativeVisible) {
        _nativeVisible = false;
        await AiPanelNative.setVisible(false);
      }
      return;
    }

    if (!_opened) {
      _opened = true;
      _lastSentRect = rect;
      final cfg = NativeCore.configDir();
      final ok = await AiPanelNative.open(
        rect: rect,
        dataDir: '$cfg/webview',
        cacheDir: '$cfg/webview-cache',
      );
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _unsupported = true;
          s.showToast('内嵌网页不可用，已提供「用浏览器打开」');
        });
        return;
      }
      setState(() {
        _unsupported = false;
        _loadState = 'loading';
      });
      // 面板建好了才能把"问 AI"请求交给原生
      WidgetsBinding.instance.addPostFrameCallback((_) => _consumePendingAsk());
    } else if (_lastSentRect != rect) {
      _lastSentRect = rect;
      await AiPanelNative.setBounds(rect);
    }

    if (!mounted) return;
    if (want != _nativeVisible) {
      _nativeVisible = want;
      await AiPanelNative.setVisible(want);
    }
  }

  // ---------------------------------------------------------- 事件

  void _onLoadChanged(AiLoadEvent e) {
    if (!mounted) return;
    setState(() {
      if (e.isLoading) {
        _loadState = 'loading';
        _loadError = null;
      } else if (e.isReady) {
        _loadState = 'ready';
        _loadError = null;
        _everReady = true;
      } else if (e.isFailed) {
        _loadState = 'failed';
        _loadError = e.error ?? (e.state == 'crashed' ? '网页进程崩溃' : '网页加载失败');
      }
    });
    if (_isNative) {
      // 就绪后要把原生网页显示出来（首次加载时它一直是隐藏的）
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncNative());
    }
  }

  void _onPromptResult(bool ok, String? error) {
    if (!mounted) return;
    if (ok) {
      s.showToast('已带入 DeepSeek 提问框，可编辑后发送',
          duration: const Duration(seconds: 4));
      return;
    }
    // 自动填入失败（站点改版等）：退化成复制到剪贴板，用户手动粘贴。
    final text = s.selectionText;
    if (text == null || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    s.showToast('自动填入失败（${error ?? '未知原因'}），已复制到剪贴板',
        duration: const Duration(seconds: 4));
  }

  // ---------------------------------------------------------- 操作

  Future<void> _sendSelection() async {
    final text = s.selectionText;
    if (text == null || text.isEmpty) return;

    if (_backend == AiBackendKind.inAppWebView) {
      s.showToast('正在带入提问框…');
      final ok = await AiWebView.prompt(text);
      // ok == null 才是"面板没建好"；true/false 的成败提示由 onPromptResult 负责
      if (ok == null) {
        Clipboard.setData(ClipboardData(text: text));
        s.showToast('面板尚未就绪，已复制选中内容到剪贴板');
      }
      return;
    }

    final ok = await AiPanelNative.prompt(text);
    if (!ok) {
      Clipboard.setData(ClipboardData(text: text));
      s.showToast('面板尚未就绪，已复制选中内容到剪贴板');
      return;
    }
    s.showToast('正在带入提问框…');
  }

  Future<void> _reload() async {
    setState(() => _loadState = 'loading');
    if (_backend == AiBackendKind.inAppWebView) {
      await AiWebView.reload();
    } else {
      await AiPanelNative.reload();
    }
  }

  void _openExternal() {
    launchUrl(Uri.parse(kDeepSeekUrl), mode: LaunchMode.externalApplication);
  }

  Future<void> _zoomBy(double delta) async {
    final next = (_zoom + delta).clamp(0.6, 2.0);
    if (next == _zoom) return;
    setState(() => _zoom = next);
    if (_backend == AiBackendKind.inAppWebView) {
      await AiWebView.setTextZoom((next * 100).round());
    } else {
      await AiPanelNative.setZoom(next);
    }
    s.showToast('网页缩放 ${(next * 100).round()}%');
  }

  Future<void> _clearLogin() async {
    if (_backend == AiBackendKind.inAppWebView) {
      await AiWebView.clearData();
    } else {
      await AiPanelNative.clearData();
    }
    setState(() {
      _loadState = 'loading';
      _loadError = null;
      _everReady = false;
    });
    s.showToast('已清除网页登录状态，正在重新加载');
  }

  // ---------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        border: widget.compact
            ? null
            : Border(left: BorderSide(color: t.dividerColor)),
      ),
      child: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_unsupported) return _buildFallback();
    if (_backend == AiBackendKind.inAppWebView) return _buildInAppWebView();
    // Linux：加载失败时也用 Flutter 的失败页（原生网页这时是隐藏的）
    if (_loadState == 'failed') return _buildFallback();
    // 原生网页盖在占位区之上，这里只画「还没盖上时」看得到的东西
    final t = Theme.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            key: _hostKey,
            color: t.colorScheme.surfaceContainerLowest,
          ),
        ),
        Positioned.fill(child: _buildPlaceholder()),
      ],
    );
  }

  Widget _buildInAppWebView() {
    // 加载失败时用 Flutter 的失败页替换掉 WebView（否则用户看到的是安卓自带的报错页）
    if (_loadState == 'failed') return _buildFallback();
    final controller = AiWebView.controller;
    if (controller == null) return _buildPlaceholder();
    return WebViewWidget(controller: controller);
  }

  Widget _buildHeader() {
    // 选区变化只重建这条头部（不值当让整个界面跟着重建）
    return ValueListenableBuilder<String?>(
      valueListenable: s.selection,
      builder: (context, sel, _) => _buildHeaderRow(sel),
    );
  }

  Widget _buildHeaderRow(String? sel) {
    final t = Theme.of(context);
    final hasSelection = sel?.trim().isNotEmpty ?? false;
    return Container(
      height: kAiPaneHeaderHeight,
      padding: const EdgeInsets.only(left: 10, right: 2),
      decoration: BoxDecoration(
        color: t.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: Border(bottom: BorderSide(color: t.dividerColor)),
      ),
      child: Row(
        children: [
          Icon(Icons.smart_toy_outlined, size: 15, color: t.colorScheme.primary),
          const SizedBox(width: 6),
          const Text('AI 搜索',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: 5),
          Tooltip(
            message: switch (_loadState) {
              'ready' => '网页已就绪',
              'failed' => _loadError ?? '网页加载失败',
              _ => '正在加载网页',
            },
            child: Icon(
              switch (_loadState) {
                'ready' => Icons.check_circle,
                'failed' => Icons.error_outline,
                _ => Icons.hourglass_bottom,
              },
              size: 11,
              color: switch (_loadState) {
                'ready' => Colors.green,
                'failed' => t.colorScheme.error,
                _ => t.hintColor,
              },
            ),
          ),
          const Spacer(),
          _iconButton(
            icon: Icons.input,
            tooltip: hasSelection
                ? '把选中文字带入提问框：${_preview(sel!)}'
                : '先在正文里选中一段文字（可整段/跨块），再点这里带入提问框',
            onPressed: hasSelection ? _sendSelection : null,
          ),
          _iconButton(
            icon: Icons.refresh,
            tooltip: '重新加载网页',
            onPressed: _unsupported ? null : _reload,
          ),
          _buildMenu(),
          _iconButton(
            icon: widget.compact ? Icons.arrow_back : Icons.close,
            tooltip: widget.compact ? '返回阅读' : '关闭 AI 面板（登录态保留）',
            onPressed: s.toggleAi,
          ),
        ],
      ),
    );
  }

  Widget _buildMenu() {
    return PopupMenuButton<String>(
      tooltip: '更多',
      enabled: !_unsupported,
      padding: EdgeInsets.zero,
      splashRadius: 14,
      icon: const Icon(Icons.more_vert, size: 15),
      onSelected: (v) {
        switch (v) {
          case 'ask':
            final sel = s.selectionText;
            if (sel != null && sel.trim().isNotEmpty) {
              s.askAi(sel, submit: true);
            }
            break;
          case 'insert':
            final sel = s.selectionText;
            if (sel != null && sel.trim().isNotEmpty) {
              s.askAi(sel, submit: false);
            }
            break;
          case 'zoom-in':
            _zoomBy(0.1);
            break;
          case 'zoom-out':
            _zoomBy(-0.1);
            break;
          case 'external':
            _openExternal();
            break;
          case 'clear':
            _clearLogin();
            break;
        }
      },
      itemBuilder: (_) {
        final sel = s.selectionText;
        final has = sel != null && sel.trim().isNotEmpty;
        final preview = has
            ? (sel.replaceAll(RegExp(r'\s+'), ' ').trim().length <= 14
                ? sel
                : '${sel.replaceAll(RegExp(r'\s+'), ' ').trim().substring(0, 14)}…')
            : '';
        return [
          PopupMenuItem(
            value: 'ask',
            enabled: has,
            child: Text(has ? '新对话 + 直接提问（$preview）' : '新对话 + 直接提问（先选中文字）'),
          ),
          PopupMenuItem(
            value: 'insert',
            enabled: has,
            child:
                Text(has ? '新对话 + 只放进输入框（$preview）' : '新对话 + 只放进输入框（先选中文字）'),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'zoom-in', child: Text('放大网页')),
          const PopupMenuItem(value: 'zoom-out', child: Text('缩小网页')),
          const PopupMenuItem(value: 'external', child: Text('在系统浏览器打开')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'clear', child: Text('清除登录状态并刷新')),
        ];
      },
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 15),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      visualDensity: VisualDensity.compact,
      splashRadius: 14,
    );
  }

  /// 不可用 / 加载失败的兜底页
  Widget _buildFallback() {
    if (_unsupported) {
      return _placeholder(
        icon: Icons.public_off,
        title: '这里本应内嵌 DeepSeek 对话',
        body: Platform.isLinux
            ? '本次构建没有编译 WebKitGTK 支持（缺 libwebkit2gtk-4.1-dev）。\n'
                '点下面的按钮用系统浏览器打开，登录态由浏览器自己记着。'
            : '当前平台还不支持内嵌网页。\n'
                '点下面的按钮用系统浏览器打开。',
        action: FilledButton.icon(
          onPressed: _openExternal,
          icon: const Icon(Icons.open_in_new, size: 16),
          label: const Text('用系统浏览器打开 DeepSeek'),
        ),
      );
    }
    return _placeholder(
      icon: Icons.cloud_off,
      title: '网页加载失败',
      body: '${_loadError ?? ''}\n'
          '（DeepSeek 打不开时，本机代理 / 网络往往是原因）',
      action: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          OutlinedButton.icon(
            onPressed: _reload,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _openExternal,
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('浏览器打开'),
          ),
        ],
      ),
    );
  }

  /// 加载中 / 拖动分栏时露出（Linux 就绪后这块被原生网页盖住）
  Widget _buildPlaceholder() {
    final t = Theme.of(context);
    return _placeholder(
      icon: null,
      title: _loadState == 'ready' ? '正在调整宽度…' : '正在打开 DeepSeek…',
      body: _loadState == 'ready'
          ? null
          : '首次使用需要登录；登录态保存在本机，之后打开即用。',
      action: null,
      spinner: _loadState != 'ready' && _loadState != 'idle',
      textColor: t.hintColor,
    );
  }

  Widget _placeholder({
    required IconData? icon,
    required String title,
    String? body,
    required Widget? action,
    bool spinner = false,
    Color? textColor,
  }) {
    final t = Theme.of(context);
    final color = textColor ?? t.colorScheme.onSurface;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (spinner)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (icon != null)
              Icon(icon, size: 34, color: t.hintColor),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: color),
            ),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(
                body,
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 11.5, color: t.hintColor, height: 1.5),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: 14),
              action,
            ],
          ],
        ),
      ),
    );
  }

  String _preview(String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= 24 ? one : '${one.substring(0, 24)}…';
  }
}

/// 阅读区与 AI 面板之间的拖动条。
///
/// 拖动期间把原生网页藏起来（Linux）：它是独立的原生子窗口，指针压在它上面时
/// Flutter 收不到移动事件，分栏会「粘住」。应用内 WebView 不需要这一手。
class AiPaneResizer extends StatefulWidget {
  final AppState state;
  const AiPaneResizer({super.key, required this.state});

  @override
  State<AiPaneResizer> createState() => _AiPaneResizerState();
}

class _AiPaneResizerState extends State<AiPaneResizer> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final active = _hover || widget.state.aiDragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => widget.state.setAiDragging(true),
        onHorizontalDragUpdate: (d) =>
            widget.state.setAiWidth(widget.state.aiWidth - d.delta.dx),
        onHorizontalDragEnd: (_) => widget.state.setAiDragging(false),
        onHorizontalDragCancel: () => widget.state.setAiDragging(false),
        onDoubleTap: () =>
            widget.state.setAiWidth(AppState.aiPaneDefaultWidth),
        child: SizedBox(
          width: 6,
          child: Center(
            child: Container(
              width: active ? 3 : 1,
              color: active ? t.colorScheme.primary : t.dividerColor,
            ),
          ),
        ),
      ),
    );
  }
}
