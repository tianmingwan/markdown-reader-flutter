// AI 面板的公共类型与「网页承载方式」判定。
//
// 三个平台的网页承载能力完全不同，所以先把差异收敛在这里：
//   - Linux  ：原生 WebKitGTK 子窗口叠在窗口上（Dart 要管矩形/遮挡，见 ai_panel_native.dart）
//   - Android / iOS / macOS：webview_flutter 的平台视图，天然在 Flutter 里（见 ai_webview.dart）
//   - Windows：没有内嵌能力 → 退化成「用系统浏览器打开」
import 'dart:io';

/// 原生内嵌网页的可用性。
enum AiPaneAvailability {
  /// 尚未尝试过
  unknown,

  /// 平台内嵌能力已就绪
  ready,

  /// 当前平台/构建没有内嵌能力 → UI 退化成「用系统浏览器打开」
  unsupported,
}

/// 网页承载方式。
enum AiBackendKind {
  /// Linux：原生覆盖层（需要 Dart 侧同步矩形、并在拖动/浮层时藏起来）
  nativeOverlay,

  /// Android / iOS / macOS：应用内 WebView 平台视图
  inAppWebView,

  /// 其它平台：只能丢给系统浏览器
  external,
}

/// 判定当前平台用哪种承载方式。
///
/// 可选参数只为测试注入用：**只要传了任意一个**，就按「模拟该平台」处理
/// （其余平台一律视为 false），否则读取真实平台。生产代码直接调用即可。
AiBackendKind detectAiBackend({
  bool? isLinux,
  bool? isAndroid,
  bool? isIOS,
  bool? isMacOS,
}) {
  final simulated =
      isLinux != null || isAndroid != null || isIOS != null || isMacOS != null;
  final linux = isLinux ?? (simulated ? false : Platform.isLinux);
  final android = isAndroid ?? (simulated ? false : Platform.isAndroid);
  final ios = isIOS ?? (simulated ? false : Platform.isIOS);
  final macos = isMacOS ?? (simulated ? false : Platform.isMacOS);
  if (linux) return AiBackendKind.nativeOverlay;
  if (android || ios || macos) return AiBackendKind.inAppWebView;
  return AiBackendKind.external;
}

/// 页面加载状态事件（Linux 的原生事件与应用内 WebView 的回调共用）。
class AiLoadEvent {
  /// started | finished | failed | crashed
  final String state;
  final String? uri;
  final String? error;

  const AiLoadEvent({required this.state, this.uri, this.error});

  bool get isLoading => state == 'started';
  bool get isReady => state == 'finished';
  bool get isFailed => state == 'failed' || state == 'crashed';
}

/// 把文本填进 DeepSeek 提问框的脚本（与原生侧 `linux/runner/ai_panel.cc`
/// 里的 BuildFillScript 是同一份逻辑，两边各留一份实现：那边用 C++ 拼，
/// 这边要在 Android 上跑）。
///
/// DeepSeek 的输入框是 React 受控组件：直接改 value 不会触发框架更新，
/// 必须用原型链上的原生 setter 赋值后再派发 input 事件；找不到 textarea 时
/// 退到 contenteditable（站点改版兜底）。返回是否真的填进去了。
String aiFillScript(String text) {
  final json = _jsonQuote(text);
  return "(function(){try{var t=$json;"
      "var el=document.querySelector('textarea:not([readonly]):not([disabled])')"
      "||document.querySelector('div[contenteditable=\"true\"]')"
      "||document.querySelector('[contenteditable=\"true\"]');"
      "if(!el)return false;el.focus();"
      "var tag=(el.tagName||'').toUpperCase();"
      "if(tag==='TEXTAREA'||tag==='INPUT'){"
      "var proto=tag==='TEXTAREA'?window.HTMLTextAreaElement.prototype:"
      "window.HTMLInputElement.prototype;"
      "var setter=Object.getOwnPropertyDescriptor(proto,'value').set;"
      "setter.call(el,t);"
      "el.dispatchEvent(new Event('input',{bubbles:true}));"
      "}else{el.textContent=t;"
      "el.dispatchEvent(new InputEvent('input',{bubbles:true,"
      "inputType:'insertText',data:t}));}"
      "el.dispatchEvent(new Event('change',{bubbles:true}));"
      "return true;}catch(e){return false;}})();";
}

/// JSON 字符串字面量（把任意文本安全嵌进 JS）
String _jsonQuote(String s) {
  final b = StringBuffer('"');
  for (final rune in s.runes) {
    switch (rune) {
      case 0x22:
        b.write('\\"');
        break;
      case 0x5C:
        b.write('\\\\');
        break;
      case 0x0A:
        b.write('\\n');
        break;
      case 0x0D:
        b.write('\\r');
        break;
      case 0x09:
        b.write('\\t');
        break;
      default:
        if (rune < 0x20) {
          b.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
        } else {
          b.writeCharCode(rune);
        }
    }
  }
  b.write('"');
  return b.toString();
}
