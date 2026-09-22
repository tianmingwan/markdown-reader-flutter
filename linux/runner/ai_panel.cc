#include "ai_panel.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstdio>
#include <string>

#ifdef MDREADER_HAVE_WEBKIT
#include <jsc/jsc.h>
#include <webkit2/webkit2.h>
#endif

namespace {

constexpr char kChannelName[] = "mdreader/ai_panel";
constexpr char kDefaultUrl[] = "https://chat.deepseek.com/";

// 面板最小尺寸（GTK 设备像素）：比这更小就直接隐藏原生视图，避免留一条网页残片。
constexpr int kMinPaneWidth = 120;
constexpr int kMinPaneHeight = 60;

// 注入重试节奏：页面刚 Finished 时 SPA 可能还没水合出输入框，
// 因此失败后按下面的间隔再试，最后一次仍失败就告诉 Dart「填不进去」，由它兜底。
constexpr int kRetryDelaysMs[] = {1500, 3000, 5000};

// JSON 字符串字面量：把文本安全嵌进 JS。
std::string JsonQuote(const std::string& text) {
  std::string out = "\"";
  for (unsigned char c : text) {
    switch (c) {
      case '"':
        out += "\\\"";
        break;
      case '\\':
        out += "\\\\";
        break;
      case '\n':
        out += "\\n";
        break;
      case '\r':
        out += "\\r";
        break;
      case '\t':
        out += "\\t";
        break;
      default:
        if (c < 0x20) {
          char buf[8];
          snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  out += "\"";
  return out;
}

// 把文本填进 DeepSeek 输入框（submit=true 时顺便发出去）。
//
// 比单纯填空多两件保命的事（都是真机踩出来的）：
// 1) 粘性填充：新对话页面加载完成后 SPA 会重置输入框，填早了会被冲掉，所以填完要盯着；
// 2) 发送重试：刚填完时发送按钮常是 disabled，直接点会静默失败；发出去（输入框清空）就停手。
std::string BuildAskScript(const std::string& text, bool submit) {
  const char* flag = submit ? "true" : "false";
  std::string js = R"JS(
(function(){
  try{
    var TEXT=__TEXT__, SUBMIT=__SUBMIT__;
    var MAXT=SUBMIT?14:9, ticks=0, sends=0;
    function input(){ return document.querySelector('textarea:not([readonly]):not([disabled])')||document.querySelector('div[contenteditable="true"]'); }
    function val(el){ return el?String((el.value!==undefined?el.value:el.textContent)||''):''; }
    function setVal(el,t){
      el.focus();
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
    var el0=input();
    var first='noinput';
    if(el0){
      if(val(el0).trim()!==TEXT.trim()) setVal(el0,TEXT);
      first = val(el0).trim()===TEXT.trim() ? 'ok' : 'nofill';
    }
    tick();
    return first;
  }catch(e){return 'error';}
})();)JS";
  const std::string text_json = JsonQuote(text);
  for (std::string::size_type pos = js.find("__TEXT__"); pos != std::string::npos;
       pos = js.find("__TEXT__", pos + text_json.size())) {
    js.replace(pos, 8, text_json);
  }
  for (std::string::size_type pos = js.find("__SUBMIT__"); pos != std::string::npos;
       pos = js.find("__SUBMIT__", pos + 8)) {
    js.replace(pos, 10, flag);
  }
  return js;
}


// 复查提问是否真的发出去了（输入框被清空即视为已发送），用于如实提示
std::string BuildSubmitVerifyScript() {
  return R"JS(
(function(){
  try{
    var el=document.querySelector('textarea:not([readonly]):not([disabled])')
        || document.querySelector('div[contenteditable="true"]');
    if(!el) return true;
    var v=String((el.value!==undefined?el.value:el.textContent)||'').trim();
    return v.length===0;
  }catch(e){return false;}
})();)JS";
}

FlValue* Arg(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, key);
}

double ArgNum(FlValue* args, const char* key, double fallback) {
  FlValue* v = Arg(args, key);
  if (v == nullptr) return fallback;
  if (fl_value_get_type(v) == FL_VALUE_TYPE_FLOAT) return fl_value_get_float(v);
  if (fl_value_get_type(v) == FL_VALUE_TYPE_INT) {
    return static_cast<double>(fl_value_get_int(v));
  }
  return fallback;
}

std::string ArgStr(FlValue* args, const char* key, const char* fallback) {
  FlValue* v = Arg(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_STRING) {
    return fallback;
  }
  return fl_value_get_string(v);
}

bool ArgBool(FlValue* args, const char* key, bool fallback) {
  FlValue* v = Arg(args, key);
  if (v == nullptr || fl_value_get_type(v) != FL_VALUE_TYPE_BOOL) {
    return fallback;
  }
  return fl_value_get_bool(v);
}

FlMethodResponse* Error(const char* code, const char* message) {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
}

FlMethodResponse* OkBool(bool value) {
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_bool(value)));
}

}  // namespace

AiPanel* AiPanel::GetInstance() {
  static AiPanel instance;
  return &instance;
}

bool AiPanel::Supported() {
#ifdef MDREADER_HAVE_WEBKIT
  return true;
#else
  return false;
#endif
}

void AiPanel::Attach(FlView* view, GtkWidget* overlay) {
  view_ = view;
  overlay_ = overlay;
  if (view_ == nullptr) return;

  FlEngine* engine = fl_view_get_engine(view_);
  if (engine == nullptr) return;
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  if (messenger == nullptr) return;

  if (channel_ != nullptr) g_object_unref(channel_);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel_, OnMethodCall, this,
                                            nullptr);
}

void AiPanel::Emit(const char* method, FlValue* args) {
  if (channel_ == nullptr) return;
  fl_method_channel_invoke_method(channel_, method, args, nullptr, nullptr,
                                  nullptr);
}

void AiPanel::EmitLoadState(const char* state, const char* uri,
                            const char* error) {
  FlValue* m = fl_value_new_map();
  fl_value_set_string_take(m, "state", fl_value_new_string(state));
  fl_value_set_string_take(m, "uri", fl_value_new_string(uri == nullptr ? "" : uri));
  if (error != nullptr) {
    fl_value_set_string_take(m, "error", fl_value_new_string(error));
  }
  Emit("loadChanged", m);
}

// ---------------------------------------------------------------- 通道入口

void AiPanel::OnMethodCall(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  (void)channel;
  static_cast<AiPanel*>(user_data)->HandleMethodCall(method_call);
}

void AiPanel::HandleMethodCall(FlMethodCall* method_call) {
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  if (g_strcmp0(method, "supported") == 0) {
    fl_method_call_respond(method_call, OkBool(Supported()), nullptr);
    return;
  }

#ifdef MDREADER_HAVE_WEBKIT
  if (g_strcmp0(method, "open") == 0) {
    EnsureWebView(ArgStr(args, "dataDir", ""), ArgStr(args, "cacheDir", ""),
                  ArgStr(args, "url", kDefaultUrl));
    x_ = static_cast<int>(ArgNum(args, "x", x_));
    y_ = static_cast<int>(ArgNum(args, "y", y_));
    width_ = static_cast<int>(ArgNum(args, "w", width_));
    height_ = static_cast<int>(ArgNum(args, "h", height_));
    SetPaneVisible(true);
    const std::string prompt = ArgStr(args, "prompt", "");
    if (!prompt.empty()) SetPendingPrompt(prompt, false);
    fl_method_call_respond(method_call, OkBool(true), nullptr);
    return;
  }

  if (g_strcmp0(method, "setBounds") == 0) {
    x_ = static_cast<int>(ArgNum(args, "x", x_));
    y_ = static_cast<int>(ArgNum(args, "y", y_));
    width_ = static_cast<int>(ArgNum(args, "w", width_));
    height_ = static_cast<int>(ArgNum(args, "h", height_));
    ApplyBounds();
    fl_method_call_respond(method_call, OkBool(true), nullptr);
    return;
  }

  if (g_strcmp0(method, "setVisible") == 0) {
    SetPaneVisible(ArgBool(args, "visible", false));
    fl_method_call_respond(method_call, OkBool(true), nullptr);
    return;
  }

  if (g_strcmp0(method, "reload") == 0) {
    if (webview_ != nullptr) {
      page_ready_ = false;
      webkit_web_view_reload(WEBKIT_WEB_VIEW(webview_));
    }
    fl_method_call_respond(method_call, OkBool(webview_ != nullptr), nullptr);
    return;
  }

  if (g_strcmp0(method, "prompt") == 0) {
    const std::string text = ArgStr(args, "text", "");
    if (text.empty() || webview_ == nullptr) {
      fl_method_call_respond(method_call, OkBool(false), nullptr);
      return;
    }
    const bool submit = ArgBool(args, "submit", false);
    if (ArgBool(args, "newChat", false)) {
      // 开新对话：**先别往当前页面里填**（否则内容会发进上一个对话），
      // 只挂上待办、标记页面未就绪，导航到聊天根路径，等加载完成后再补填。
      pending_prompt_ = text;
      pending_submit_ = submit;
      inject_attempts_ = 0;
      page_ready_ = false;
      webkit_web_view_load_uri(WEBKIT_WEB_VIEW(webview_), kDefaultUrl);
    } else {
      SetPendingPrompt(text, submit);
    }
    fl_method_call_respond(method_call, OkBool(true), nullptr);
    return;
  }

  if (g_strcmp0(method, "setZoom") == 0) {
    if (webview_ != nullptr) {
      double level = ArgNum(args, "level", 1.0);
      if (level < 0.5) level = 0.5;
      if (level > 2.5) level = 2.5;
      webkit_web_view_set_zoom_level(WEBKIT_WEB_VIEW(webview_), level);
    }
    fl_method_call_respond(method_call, OkBool(true), nullptr);
    return;
  }

  if (g_strcmp0(method, "clearData") == 0) {
    // 「退出登录」：清掉 cookie / localStorage，然后重新加载。
    if (webview_ != nullptr) {
      WebKitWebsiteDataManager* manager =
          webkit_web_view_get_website_data_manager(WEBKIT_WEB_VIEW(webview_));
      if (manager != nullptr) {
        webkit_website_data_manager_clear(manager, WEBKIT_WEBSITE_DATA_ALL, 0,
                                          nullptr, nullptr, nullptr);
      }
      page_ready_ = false;
      webkit_web_view_reload(WEBKIT_WEB_VIEW(webview_));
    }
    fl_method_call_respond(method_call, OkBool(true), nullptr);
    return;
  }

  fl_method_call_respond(method_call,
                         Error("not-implemented", "未知的 AI 面板方法"),
                         nullptr);
#else
  // 没编译 WebKit：明确回 unsupported，Dart 侧据此退化成「用系统浏览器打开」。
  (void)method;
  (void)args;
  fl_method_call_respond(
      method_call,
      Error("unsupported", "本次构建未包含 WebKitGTK（缺 libwebkit2gtk-4.1-dev）"),
      nullptr);
#endif
}

#ifdef MDREADER_HAVE_WEBKIT

// ---------------------------------------------------------------- WebView

void AiPanel::EnsureWebView(const std::string& data_dir,
                            const std::string& cache_dir,
                            const std::string& url) {
  if (webview_ != nullptr) {
    if (!page_ready_) {
      webkit_web_view_load_uri(WEBKIT_WEB_VIEW(webview_),
                              url.empty() ? kDefaultUrl : url.c_str());
    }
    return;
  }
  if (overlay_ == nullptr) return;

  if (!data_dir.empty()) g_mkdir_with_parents(data_dir.c_str(), 0700);
  if (!cache_dir.empty()) g_mkdir_with_parents(cache_dir.c_str(), 0700);

  // 登录态就落在这里：cookie / localStorage / IndexedDB 全由 WebKit 持久化，
  // 用户登录一次之后长期有效（关闭面板只是隐藏，不销毁 WebView）。
  WebKitWebsiteDataManager* manager = webkit_website_data_manager_new(
      "base-data-directory", data_dir.empty() ? nullptr : data_dir.c_str(),
      "base-cache-directory", cache_dir.empty() ? nullptr : cache_dir.c_str(),
      nullptr);
  WebKitWebContext* context =
      webkit_web_context_new_with_website_data_manager(manager);
  g_object_unref(manager);

  webview_ = webkit_web_view_new_with_context(context);
  g_object_unref(context);

  gtk_widget_set_halign(webview_, GTK_ALIGN_START);
  gtk_widget_set_valign(webview_, GTK_ALIGN_START);
  gtk_widget_set_size_request(webview_, kMinPaneWidth, kMinPaneHeight);
  gtk_overlay_add_overlay(GTK_OVERLAY(overlay_), webview_);
  // 必须显式 show：runner 只 show 了自己那棵子树，叠加子件不 show 就不会被映射。
  gtk_widget_show(webview_);
  gtk_widget_set_visible(webview_, FALSE);

  g_signal_connect(webview_, "load-changed",
                   G_CALLBACK(+[](WebKitWebView* wv, WebKitLoadEvent event,
                                  gpointer user_data) {
                     auto* self = static_cast<AiPanel*>(user_data);
                     const char* uri = webkit_web_view_get_uri(wv);
                     if (event == WEBKIT_LOAD_STARTED) {
                       self->page_ready_ = false;
                       self->EmitLoadState("started", uri, nullptr);
                     } else if (event == WEBKIT_LOAD_FINISHED) {
                       self->page_ready_ = true;
                       self->EmitLoadState("finished", uri, nullptr);
                       self->InjectPending();
                     }
                   }),
                   this);

  g_signal_connect(
      webview_, "load-failed",
      G_CALLBACK(+[](WebKitWebView* wv, WebKitLoadEvent event,
                     const gchar* failing_uri, GError* error,
                     gpointer user_data) -> gboolean {
        (void)wv;
        (void)event;
        auto* self = static_cast<AiPanel*>(user_data);
        self->page_ready_ = false;
        self->EmitLoadState("failed", failing_uri,
                            error == nullptr ? "加载失败" : error->message);
        return FALSE;
      }),
      this);

  g_signal_connect(webview_, "web-process-terminated",
                   G_CALLBACK(+[](WebKitWebView* wv,
                                  WebKitWebProcessTerminationReason reason,
                                  gpointer user_data) {
                     (void)wv;
                     auto* self = static_cast<AiPanel*>(user_data);
                     self->page_ready_ = false;
                     FlValue* m = fl_value_new_map();
                     fl_value_set_string_take(m, "state",
                                              fl_value_new_string("crashed"));
                     fl_value_set_string_take(
                         m, "reason",
                         fl_value_new_int(static_cast<int64_t>(reason)));
                     self->Emit("loadChanged", m);
                   }),
                   this);

  // 新窗口请求（window.open / target=_blank，登录跳转常见）不再开一个看不见的
  // 窗口，而是在当前面板里继续导航——这也是弹窗被拦时浏览器的默认行为。
  g_signal_connect(
      webview_, "create",
      G_CALLBACK(+[](WebKitWebView* wv, WebKitNavigationAction* action,
                     gpointer user_data) -> GtkWidget* {
        (void)user_data;
        WebKitURIRequest* request = webkit_navigation_action_get_request(action);
        const gchar* uri =
            request == nullptr ? nullptr : webkit_uri_request_get_uri(request);
        if (uri != nullptr) webkit_web_view_load_uri(wv, uri);
        return nullptr;
      }),
      this);

  webkit_web_view_load_uri(WEBKIT_WEB_VIEW(webview_),
                           url.empty() ? kDefaultUrl : url.c_str());
}

void AiPanel::ApplyBounds() {
  if (webview_ == nullptr) return;
  const bool degenerate = width_ < kMinPaneWidth || height_ < kMinPaneHeight;
  if (degenerate) {
    gtk_widget_set_visible(webview_, FALSE);
    return;
  }
  gtk_widget_set_margin_start(webview_, x_ < 0 ? 0 : x_);
  gtk_widget_set_margin_top(webview_, y_ < 0 ? 0 : y_);
  gtk_widget_set_size_request(webview_, width_, height_);
  gtk_widget_set_visible(webview_, pane_visible_ ? TRUE : FALSE);
}

void AiPanel::SetPaneVisible(bool visible) {
  pane_visible_ = visible;
  if (webview_ == nullptr) return;
  ApplyBounds();
  if (!visible && view_ != nullptr) {
    // 面板收起后把键盘焦点还给 Flutter，否则打字仍然落在隐藏的网页里。
    gtk_widget_grab_focus(GTK_WIDGET(view_));
  }
}

// ---------------------------------------------------------------- 注入

void AiPanel::SetPendingPrompt(const std::string& text, bool submit) {
  pending_prompt_ = text;
  pending_submit_ = submit;
  inject_attempts_ = 0;
  InjectPending();
}

void AiPanel::InjectPending() {
  if (pending_prompt_.empty() || webview_ == nullptr) return;
  if (!page_ready_) return;
  InjectNow();
}

void AiPanel::InjectNow() {
  if (pending_prompt_.empty() || webview_ == nullptr) return;
  const bool submit = pending_submit_;
  const std::string script = BuildAskScript(pending_prompt_, submit);
  if (g_getenv("MDREADER_DEBUG") != nullptr) {
    g_printerr("[ai-ask] submit=%d text_len=%zu\n", submit ? 1 : 0,
               pending_prompt_.size());
  }
  webkit_web_view_evaluate_javascript(
      WEBKIT_WEB_VIEW(webview_), script.c_str(), -1, nullptr, nullptr, nullptr,
      +[](GObject* source, GAsyncResult* result, gpointer user_data) {
        auto* self = static_cast<AiPanel*>(user_data);
        g_autoptr(GError) error = nullptr;
        g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(
            WEBKIT_WEB_VIEW(source), result, &error);
        bool filled = false;
        std::string why = "未找到输入框";
        if (value != nullptr && jsc_value_is_string(value)) {
          g_autofree gchar* st = jsc_value_to_string(value);
          const std::string status = st == nullptr ? "" : st;
          filled = status == "ok";
          if (status == "nofill") why = "输入框没接受内容";
          if (status == "error") why = "脚本异常";
        }
        if (filled) {
          // 无捕获 lambda 里不能引用局部变量，从成员上先取出本次是否要发送
          const bool sent_requested = self->pending_submit_;
          self->pending_prompt_.clear();
          self->pending_submit_ = false;
          self->inject_attempts_ = 0;
          if (sent_requested) {
            // 脚本内部已经轮询重试着发送；这里 4.5 秒后复查输入框是否已清空，
            // 把"到底发出去没有"如实回报给 Dart（不到位就提示用户手动发送）。
            g_timeout_add(
                4500,
                +[](gpointer data) -> gboolean {
                  auto* panel = static_cast<AiPanel*>(data);
                  if (panel->webview_ == nullptr) return G_SOURCE_REMOVE;
                  webkit_web_view_evaluate_javascript(
                      WEBKIT_WEB_VIEW(panel->webview_),
                      BuildSubmitVerifyScript().c_str(), -1, nullptr, nullptr,
                      nullptr,
                      +[](GObject* source, GAsyncResult* result,
                          gpointer user) {
                        auto* p2 = static_cast<AiPanel*>(user);
                        g_autoptr(GError) error = nullptr;
                        g_autoptr(JSCValue) value =
                            webkit_web_view_evaluate_javascript_finish(
                                WEBKIT_WEB_VIEW(source), result, &error);
                        bool sent = false;
                        if (value != nullptr && jsc_value_is_boolean(value)) {
                          sent = jsc_value_to_boolean(value);
                        }
                        FlValue* m = fl_value_new_map();
                        fl_value_set_string_take(m, "sent",
                                                 fl_value_new_bool(sent));
                        p2->Emit("submitResult", m);
                      },
                      panel);
                  return G_SOURCE_REMOVE;
                },
                self);
          }
          FlValue* m = fl_value_new_map();
          fl_value_set_string_take(m, "ok", fl_value_new_bool(true));
          fl_value_set_string_take(m, "submitted",
                                   fl_value_new_bool(sent_requested));
          self->Emit("promptResult", m);
          return;
        }
        // 输入框还没水合出来：按节奏重试；最后一次仍失败就把失败告诉 Dart，
        // 由 Dart 退化成「复制到剪贴板，用户手动粘贴」。
        const int total = static_cast<int>(G_N_ELEMENTS(kRetryDelaysMs));
        if (self->inject_attempts_ >= total) {
          self->pending_prompt_.clear();
          self->inject_attempts_ = 0;
          FlValue* m = fl_value_new_map();
          fl_value_set_string_take(m, "ok", fl_value_new_bool(false));
          fl_value_set_string_take(m, "error", fl_value_new_string(why.c_str()));
          self->Emit("promptResult", m);
          return;
        }
        const int delay = kRetryDelaysMs[self->inject_attempts_++];
        g_timeout_add(
            delay,
            +[](gpointer data) -> gboolean {
              static_cast<AiPanel*>(data)->InjectNow();
              return G_SOURCE_REMOVE;
            },
            self);
      },
      this);
}

#else  // !MDREADER_HAVE_WEBKIT

void AiPanel::EnsureWebView(const std::string& data_dir,
                            const std::string& cache_dir,
                            const std::string& url) {
  (void)data_dir;
  (void)cache_dir;
  (void)url;
}

void AiPanel::ApplyBounds() {}
void AiPanel::SetPaneVisible(bool visible) { pane_visible_ = visible; }
void AiPanel::EmitLoadState(const char* state, const char* uri,
                            const char* error) {
  (void)state;
  (void)uri;
  (void)error;
}
void AiPanel::SetPendingPrompt(const std::string& text, bool submit) {
  (void)text;
  (void)submit;
}
void AiPanel::InjectPending() {}
void AiPanel::InjectNow() {}

#endif  // MDREADER_HAVE_WEBKIT
