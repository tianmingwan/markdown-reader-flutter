// 应用内 WebView 后端（Android / iOS / macOS）。
//
// 与 Linux 的「原生子窗口叠加」不同：这里是 webview_flutter 的平台视图，
// 网页就在 Flutter 的 widget 树里，所以**不需要**矩形同步，也**不需要**在弹
// 菜单/拖动时把它藏起来（它本来就在 Flutter 下面，菜单天然盖得住）。
//
// 登录态：Android 的 WebView 由系统把 cookie 持久化在应用私有目录
// （/data/data/<pkg>/app_webview），webview_flutter 默认已开启 DOM storage
// （DeepSeek 的登录态在 localStorage 里），所以「登录一次长期有效」在安卓上同样成立。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:webview_flutter/webview_flutter.dart';
// 安卓实现包：只为了用到 setTextZoom（跨平台接口没有缩放）
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'ai_types.dart';

class AiWebView {
  AiWebView._();

  static WebViewController? _controller;
  static String? _loadedUrl;

  /// 页面加载状态回调（与 Linux 侧同名同语义）
  static void Function(AiLoadEvent event)? onLoadChanged;

  /// 「带入提问框」结果回调：ok=false 时由 Dart 退化成复制到剪贴板
  static void Function(bool ok, String? error)? onPromptResult;

  static bool get hasController => _controller != null;

  /// 文本缩放百分比（安卓用 setTextZoom，100 = 原始大小）
  static int _textZoom = 100;
  static int get textZoom => _textZoom;

  static WebViewController? get controller => _controller;

  /// 创建（或复用）控制器并加载页面。
  ///
  /// 控制器是静态的：面板关掉再打开时不重新加载，页面状态（对话内容、滚动位置）
  /// 与登录态都留着，和 Linux 侧的「只隐藏不销毁」行为对齐。
  static WebViewController ensure(String url) {
    final existing = _controller;
    if (existing != null) {
      if (_loadedUrl != url) {
        _loadedUrl = url;
        existing.loadRequest(Uri.parse(url));
      }
      return existing;
    }
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (u) =>
              onLoadChanged?.call(AiLoadEvent(state: 'started', uri: u)),
          onPageFinished: (u) =>
              onLoadChanged?.call(AiLoadEvent(state: 'finished', uri: u)),
          onWebResourceError: (e) {
            // 只报主文档失败：子资源（图片/埋点）失败不该把整页判成「打不开」
            if (!e.isForMainFrame!) return;
            onLoadChanged?.call(AiLoadEvent(
              state: 'failed',
              uri: e.url,
              error: '${e.description}（${e.errorCode}）',
            ));
          },
        ),
      );
    _loadedUrl = url;
    c.loadRequest(Uri.parse(url));
    _controller = c;
    return c;
  }

  static Future<void> reload() async {
    await _controller?.reload();
  }

  /// 把文本填进 DeepSeek 提问框。
  ///
  /// 返回 null 表示**面板还没建好**（控制器都没有），由调用方提示"面板尚未就绪"；
  /// 返回 true/false 表示脚本真的跑过了，成败已通过 [onPromptResult] 汇报，
  /// 调用方不要再补一条提示去覆盖它（否则"未找到输入框"会被"面板尚未就绪"顶掉）。
  static Future<bool?> prompt(String text) async {
    final c = _controller;
    if (c == null || text.trim().isEmpty) return null;
    try {
      final r = await c.runJavaScriptReturningResult(aiFillScript(text));
      final filled = _truthy(r);
      onPromptResult?.call(filled, filled ? null : '未找到输入框');
      return filled;
    } catch (e) {
      onPromptResult?.call(false, '$e');
      return false;
    }
  }

  /// 安卓用系统 WebView 的文本缩放（100 为原始大小）
  static Future<void> setTextZoom(int percent) async {
    _textZoom = percent.clamp(60, 200);
    // 跨平台接口没有缩放，安卓走平台的 setTextZoom
    final platform = _controller?.platform;
    if (platform is AndroidWebViewController) {
      await platform.setTextZoom(_textZoom);
    }
  }

  /// 清除全部登录态（cookie + localStorage + 缓存）后重新加载。
  static Future<void> clearData() async {
    final c = _controller;
    if (c == null) return;
    try {
      await WebViewCookieManager().clearCookies();
      await c.clearLocalStorage();
      await c.clearCache();
    } catch (e) {
      debugPrint('清除 WebView 数据失败：$e');
    }
    await c.reload();
  }

  /// 仅测试用：重置静态状态
  @visibleForTesting
  static void resetForTest() {
    _controller = null;
    _loadedUrl = null;
    _textZoom = 100;
    onLoadChanged = null;
    onPromptResult = null;
  }
}

bool _truthy(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) return v == 'true' || v == '1';
  return false;
}
