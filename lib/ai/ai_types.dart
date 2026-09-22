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

/// 把选中内容送进 DeepSeek 输入框（[submit] 为 true 时顺便发出去）。
///
/// 这是「问 AI」用的统一脚本，比单纯填空多两件保命的事：
/// 1. **粘性填充**：DeepSeek 是 SPA，新对话页面加载完成后会把输入框重置一次，
///    填早了会被冲掉 —— 脚本会在页面里盯一段时间，发现内容没了就再填一遍；
/// 2. **发送重试**：刚填完时发送按钮往往还是 disabled（React 未更新），直接点会
///    静默失败 —— 按钮可用才点，不可用等下一轮；一旦发出去（输入框清空）立刻停手，
///    绝不重复发送。
String aiAskScript(String text, {required bool submit}) {
  final json = _jsonQuote(text);
  final flag = submit ? 'true' : 'false';
  return r'''
(function(){
  try{
    var TEXT=__TEXT__, SUBMIT=__SUBMIT__;
    var MAXT=SUBMIT?14:9, ticks=0, sends=0;
    function input(){ return document.querySelector('textarea:not([readonly]):not([disabled])')||document.querySelector('div[contenteditable="true"]'); }
    function val(el){ return el?String((el.value!==undefined?el.value:el.textContent)||''):''; }
    function setVal(el,t){
      el.focus();
      // 先试浏览器级编辑命令：WebKitGTK 下"原型链 setter + input 事件"这条 React
      // 老套路不生效（值会被 React 回滚），execCommand 走真实编辑管线，两个引擎都认。
      try{
        document.execCommand('selectAll', false, null);
        document.execCommand('delete', false, null);
        if(document.execCommand('insertText', false, t) && val(el)===t) return;
      }catch(e){}
      var tag=(el.tagName||'').toUpperCase();
      if(tag==='TEXTAREA'||tag==='INPUT'){
        var proto=tag==='TEXTAREA'?window.HTMLTextAreaElement.prototype:window.HTMLInputElement.prototype;
        var setter=Object.getOwnPropertyDescriptor(proto,'value').set;
        setter.call(el,t);
        el.dispatchEvent(new Event('input',{bubbles:true}));
      }else{
        el.textContent=t;
        el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:t}));
      }
      el.dispatchEvent(new Event('change',{bubbles:true}));
    }
    function usable(b){ return !!b && !b.disabled && b.getAttribute('aria-disabled')!=='true' && b.getBoundingClientRect().width>0; }
    function findButton(el){
      var sels=['button[type="submit"]','[data-testid*="send" i]','button[aria-label*="发送"]','button[aria-label*="Send" i]','[role="button"][aria-label*="发送"]','[role="button"][aria-label*="Send" i]'];
      for(var i=0;i<sels.length;i++){var b=document.querySelector(sels[i]); if(usable(b)) return b;}
      var box=el.closest('form')||el.parentElement;
      for(var up=0;up<4&&box;up++){
        var nodes=box.querySelectorAll('button,[role="button"]'),br=box.getBoundingClientRect();
        for(var k=nodes.length-1;k>=0;k--){
          var n=nodes[k]; if(!usable(n)) continue;
          var r=n.getBoundingClientRect();
          if(r.left>br.left+br.width*0.6 && n.querySelector('svg')) return n;
        }
        box=box.parentElement;
      }
      return null;
    }
    function tick(){
      ticks++;
      var el=input();
      if(!el){ if(ticks<MAXT) setTimeout(tick,500); return; }
      var v=val(el).trim();
      if(SUBMIT && sends>0 && v==='') return;
      if(v!==TEXT.trim()){
        if(SUBMIT && sends>0) return;
        setVal(el,TEXT);
        if(ticks<MAXT) setTimeout(tick,600);
        return;
      }
      if(!SUBMIT){ if(ticks<MAXT) setTimeout(tick,700); return; }
      var btn=findButton(el);
      if(btn){ btn.click(); }
      else{
        el.focus();
        ['keydown','keypress','keyup'].forEach(function(t){el.dispatchEvent(new KeyboardEvent(t,{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));});
      }
      sends++;
      if(ticks<MAXT) setTimeout(tick,800);
    }
    // 先同步试填一次，把"到底填上没有"如实回给调用方：
    // 填不上时输入框本来就是空的，发送复查会误报"已发出"，所以必须区分。
    var el0=input();
    var first='noinput';
    if(el0){
      if(val(el0).trim()!==TEXT.trim()) setVal(el0,TEXT);
      first = val(el0).trim()===TEXT.trim() ? 'ok' : 'nofill';
    }
    tick();
    return first;
  }catch(e){return 'error';}
})();'''
      .replaceAll('__TEXT__', json)
      .replaceAll('__SUBMIT__', flag);
}

/// 把已填好的提问**发出去**（"直接提问"用）。
///
/// DeepSeek 的聊天输入框是 textarea + React 受控：按 Enter 即发送
/// （Shift+Enter 才是换行），所以这里派发一组 Enter 键盘事件；
/// 找不到 textarea（站点改版）时退而尝试点发送按钮。
/// 返回是否"至少尝试发送了"——真伪由用户在面板里直接看到（消息进了对话就说明成功）。
String aiSubmitScript() {
  // 点真实的发送按钮（合成 Enter 事件 DeepSeek 的 React 不吃，真机实测）；
  // 关键：填完的那一刻发送按钮往往还是 disabled（React 还没更新），所以脚本
  // **自己在页面里轮询重试**：每 500ms 复查一次，输入框空了就说明发出去了。
  return r'''
(function(){
  try{
    var TRIES=6;
    function input(){
      return document.querySelector('textarea:not([readonly]):not([disabled])')
          || document.querySelector('div[contenteditable="true"]');
    }
    function val(el){ return el ? String((el.value!==undefined?el.value:el.textContent)||'') : ''; }
    function usable(b){
      return !!b && !b.disabled && b.getAttribute('aria-disabled')!=='true'
             && b.getBoundingClientRect().width>0;
    }
    function findButton(el){
      var sels=['button[type="submit"]','[data-testid*="send" i]','button[aria-label*="发送"]','button[aria-label*="Send" i]','[role="button"][aria-label*="发送"]','[role="button"][aria-label*="Send" i]'];
      for(var i=0;i<sels.length;i++){var b=document.querySelector(sels[i]); if(usable(b)) return b;}
      var box=el.closest('form')||el.parentElement;
      for(var up=0;up<4&&box;up++){
        var nodes=box.querySelectorAll('button,[role="button"]'),br=box.getBoundingClientRect();
        for(var k=nodes.length-1;k>=0;k--){
          var n=nodes[k];
          if(!usable(n)) continue;
          var r=n.getBoundingClientRect();
          if(r.left>br.left+br.width*0.6 && n.querySelector('svg')) return n;
        }
        box=box.parentElement;
      }
      return null;
    }
    var tries=0;
    function attempt(){
      var el=input();
      var text=val(el).trim();
      if(!text) return true;              // 输入框空了 = 已经发出去
      if(tries>=TRIES) return false;
      tries++;
      var btn=findButton(el);
      if(btn){ btn.click(); }
      else{
        el.focus();
        ['keydown','keypress','keyup'].forEach(function(t){
          el.dispatchEvent(new KeyboardEvent(t,{key:'Enter',code:'Enter',keyCode:13,which:13,bubbles:true,cancelable:true}));
        });
      }
      setTimeout(attempt, 500);           // 半秒后复查：内容还在就再试
      return true;
    }
    return attempt();
  }catch(e){return false;}
})();''';
}

/// 复查提问是否真的发出去了（输入框被清空即视为已发送），用于如实提示用户。
String aiSubmitVerifyScript() {
  return r'''
(function(){
  try{
    var el=document.querySelector('textarea:not([readonly]):not([disabled])')
        || document.querySelector('div[contenteditable="true"]');
    if(!el) return true;                  // 找不到输入框，按"已离开输入态"处理
    var v=String((el.value!==undefined?el.value:el.textContent)||'').trim();
    return v.length===0;
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
