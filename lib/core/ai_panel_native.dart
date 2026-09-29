// 右侧 AI 面板的原生桥。
//
// 面板里的 DeepSeek 网页**不是 Flutter widget**：deepseek 的网页带
// `frame-ancestors 'none'`，iframe 嵌不了，而 Flutter 桌面端又没有 platform view。
// 所以真正的网页是原生层（Linux 上是 runner 里的 WebKitGTK，见
// linux/runner/ai_panel.cc）按 Flutter 给的矩形盖在窗口上的一块原生子窗口。
//
// 这里只做两件事：把 Dart 决定的位置/显隐/操作送下去，把原生的事件收上来。
import 'dart:io';

import 'package:flutter/services.dart';

import '../ai/ai_types.dart';

/// open 的应答：面板是否可用 + 网页是否早已就绪（重开面板时关键）
class AiOpenResult {
  final bool ok;
  final bool pageReady;
  const AiOpenResult({required this.ok, required this.pageReady});
}

class AiPanelNative {
  AiPanelNative._();

  static const MethodChannel channel = MethodChannel('mdreader/ai_panel');

  /// 当前已知的可用性（第一次 open 失败后确定）
  static AiPaneAvailability availability = AiPaneAvailability.unknown;

  /// 页面加载状态回调（由面板 widget 注册）
  static void Function(AiLoadEvent event)? onLoadChanged;

  /// 「带入提问框」结果回调：ok=false 时由 Dart 退化成复制到剪贴板
  static void Function(bool ok, String? error)? onPromptResult;

  /// 「直接提问」的复查结果：sent=false 表示内容进了输入框但没发出去
  static void Function(bool sent)? onSubmitResult;

  static bool _handlerInstalled = false;

  /// 非 Linux 平台不必尝试调用原生通道（通道只存在于 Linux runner）。
  static bool get platformSupported => Platform.isLinux;

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    channel.setMethodCallHandler((call) async {
      final args = call.arguments is Map
          ? (call.arguments as Map).cast<Object?, Object?>()
          : const <Object?, Object?>{};
      switch (call.method) {
        case 'loadChanged':
          onLoadChanged?.call(AiLoadEvent(
            state: args['state'] as String? ?? '',
            uri: args['uri'] as String?,
            error: args['error'] as String?,
          ));
          break;
        case 'promptResult':
          onPromptResult?.call(
            args['ok'] == true,
            args['error'] as String?,
          );
          break;
        case 'submitResult':
          onSubmitResult?.call(args['sent'] == true);
          break;
      }
      return null;
    });
  }

  /// 打开（或重新摆放）面板。
  ///
  /// [rect] 是**逻辑像素**（与 GTK 的应用像素同单位：Flutter 视图坐标与
  /// GtkOverlay 子件的 margin/size-request 都未乘缩放因子，HiDPI 的缩放由
  /// GDK 在窗口层统一处理，这里再乘 devicePixelRatio 会把网页推出窗口）。
  ///
  /// 返回 [AiOpenResult]：ok=false 表示原生没有内嵌能力；pageReady 表示网页
  /// 早已加载完（重开面板时不会再有加载事件，Dart 据此直接置就绪态）。
  static Future<AiOpenResult> open({
    required Rect rect,
    required String dataDir,
    required String cacheDir,
    String? url,
    String? prompt,
  }) async {
    _installHandler();
    if (!platformSupported) {
      availability = AiPaneAvailability.unsupported;
      return const AiOpenResult(ok: false, pageReady: false);
    }
    try {
      final r = await channel.invokeMethod<Object?>('open', <String, Object?>{
        ..._rectArgs(rect),
        'dataDir': dataDir,
        'cacheDir': cacheDir,
        if (url != null && url.isNotEmpty) 'url': url,
        if (prompt != null && prompt.trim().isNotEmpty) 'prompt': prompt,
      });
      // 新版原生回 {ok, pageReady}；旧版只回 bool（视为 ok，pageReady 未知）
      final ok = r == true || (r is Map && r['ok'] == true);
      final pageReady = r is Map && r['pageReady'] == true;
      availability =
          ok ? AiPaneAvailability.ready : AiPaneAvailability.unsupported;
      return AiOpenResult(ok: ok, pageReady: pageReady);
    } on MissingPluginException {
      // 例如旧构建 / 非 Linux 平台
      availability = AiPaneAvailability.unsupported;
      return const AiOpenResult(ok: false, pageReady: false);
    } on PlatformException catch (e) {
      availability = e.code == 'unsupported'
          ? AiPaneAvailability.unsupported
          : availability;
      return const AiOpenResult(ok: false, pageReady: false);
    }
  }

  /// 整页切换到另一个站点（用户在设置里换了 AI 站点）
  static Future<void> loadUrl(String url) async {
    if (!platformSupported) return;
    try {
      await channel
          .invokeMethod<void>('loadUrl', <String, Object?>{'url': url});
    } catch (_) {}
  }

  /// 只更新位置尺寸（拖动分栏、窗口缩放时高频调用，失败可以忽略）。
  static Future<void> setBounds(Rect rect) async {
    if (!platformSupported) return;
    try {
      await channel.invokeMethod<void>('setBounds', _rectArgs(rect));
    } catch (_) {
      // 面板还没建好时忽略：随后的 open 会带上正确矩形
    }
  }

  static Future<void> setVisible(bool visible) async {
    if (!platformSupported) return;
    try {
      await channel.invokeMethod<void>(
          'setVisible', <String, Object?>{'visible': visible});
    } catch (_) {}
  }

  static Future<void> reload() async {
    if (!platformSupported) return;
    try {
      await channel.invokeMethod<void>('reload');
    } catch (_) {}
  }

  /// 把文本填进 DeepSeek 提问框。
  ///
  /// [submit] 为 true 时填完直接发送（"新对话 + 直接提问"）；
  /// [newChat] 为 true 时先回到聊天根路径开一个新对话，再补填。
  /// 返回 false 表示面板还没建好或原生不支持。
  static Future<bool> prompt(
    String text, {
    bool submit = false,
    bool newChat = false,
  }) async {
    if (!platformSupported || text.trim().isEmpty) return false;
    try {
      final ok = await channel.invokeMethod<bool>('prompt', <String, Object?>{
        'text': text,
        if (submit) 'submit': true,
        if (newChat) 'newChat': true,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> setZoom(double level) async {
    if (!platformSupported) return;
    try {
      await channel
          .invokeMethod<void>('setZoom', <String, Object?>{'level': level});
    } catch (_) {}
  }

  /// 清除 cookie / localStorage（退出登录用）
  static Future<void> clearData() async {
    if (!platformSupported) return;
    try {
      await channel.invokeMethod<void>('clearData');
    } catch (_) {}
  }

  static Map<String, Object?> _rectArgs(Rect r) => <String, Object?>{
        'x': r.left.round(),
        'y': r.top.round(),
        'w': r.width.round(),
        'h': r.height.round(),
      };
}
