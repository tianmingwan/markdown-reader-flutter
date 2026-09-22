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

/// 把已填好的提问**发出去**（"直接提问"用）。
///
/// DeepSeek 的聊天输入框是 textarea + React 受控：按 Enter 即发送
/// （Shift+Enter 才是换行），所以这里派发一组 Enter 键盘事件；
/// 找不到 textarea（站点改版）时退而尝试点发送按钮。
/// 返回是否"至少尝试发送了"——真伪由用户在面板里直接看到（消息进了对话就说明成功）。
String aiSubmitScript() {
  // 优先点真实的发送按钮：合成 Enter 事件 DeepSeek 的 React 不吃（真机实测），
  // 找不到按钮再退回合成 Enter。几何筛选用于避开输入框左边的「深度思考/智能搜索」。
  return r'''
(function(){
  try{
    var el=document.querySelector('textarea:not([readonly]):not([disabled])')||document.querySelector('div[contenteditable="true"]');
    if(!el)return false;el.focus();
    var sels=['button[type="submit"]','[data-testid*="send" i]','button[aria-label*="发送"]','button[aria-label*="Send" i]','[role="button"][aria-label*="发送"]','[role="button"][aria-label*="Send" i]'];
    var btn=null,i;
    for(i=0;i<sels.length&&!btn;i++){btn=document.querySelector(sels[i]);}
    if(!btn){
      var box=el.closest('form')||el.parentElement;
      for(var up=0;up<4&&box&&!btn;up++){
        var nodes=box.querySelectorAll('button,[role="button"]'),br=box.getBoundingClientRect();
        for(var k=nodes.length-1;k>=0;k--){
          var n=nodes[k];
          if(n.disabled)continue;
          var r=n.getBoundingClientRect();
          if(r.width>0&&r.left>br.left+br.width*0.6&&n.querySelector('svg')){btn=n;break;}
        }
        box=box.parentElement;
      }
    }
    if(btn){btn.click();return true;}
    ['keydown','keypress','keyup'].forEach(function(t){el.dispatchEvent(new KeyboardEvent(t,{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));});
    return true;
  }catch(e){return false;}
})();''';
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
