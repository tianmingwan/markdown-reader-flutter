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

// 把文本填进提问框。DeepSeek 的输入框是 React 受控组件：直接改 value 不会触发
// 框架更新，必须用原型链上的原生 setter 赋值后再派发 input 事件；找不到
// textarea 时退到 contenteditable（站点改版兜底）。返回是否真的填进去了。
std::string BuildFillScript(const std::string& text) {
  return "(function(){try{var t=" +
         JsonQuote(text) +
         ";var el=document.querySelector('textarea:not([readonly]):not([disabled])')"
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

// 把已填好的提问发出去（"新对话 + 直接提问"用）：DeepSeek 的输入框按 Enter 即发送
// （Shift+Enter 才是换行），所以派发一组 Enter 键盘事件；找不到 textarea 时退而点发送按钮。
std::string BuildSubmitScript() {
  // 优先点真实的发送按钮：合成 Enter 事件 DeepSeek 的 React 不吃（真机实测）；
  // 找不到按钮再退回合成 Enter。几何筛选用于避开输入框左边的「深度思考/智能搜索」。
  return R"JS(
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
    SetPendingPrompt(text, ArgBool(args, "submit", false));
    if (ArgBool(args, "newChat", false)) {
      // 回到聊天根路径 = 开一个新对话；pending 会在加载完成后自动补填
      page_ready_ = false;
      webkit_web_view_load_uri(WEBKIT_WEB_VIEW(webview_), kDefaultUrl);
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
  const std::string script = BuildFillScript(pending_prompt_);
  webkit_web_view_evaluate_javascript(
      WEBKIT_WEB_VIEW(webview_), script.c_str(), -1, nullptr, nullptr, nullptr,
      +[](GObject* source, GAsyncResult* result, gpointer user_data) {
        auto* self = static_cast<AiPanel*>(user_data);
        g_autoptr(GError) error = nullptr;
        g_autoptr(JSCValue) value = webkit_web_view_evaluate_javascript_finish(
            WEBKIT_WEB_VIEW(source), result, &error);
        bool filled = false;
        if (value != nullptr && jsc_value_is_boolean(value)) {
          filled = jsc_value_to_boolean(value);
        }
        if (filled) {
          const bool submit = self->pending_submit_;
          self->pending_prompt_.clear();
          self->pending_submit_ = false;
          self->inject_attempts_ = 0;
          if (submit) {
            // "新对话 + 直接提问"：填完就把消息发出去
            webkit_web_view_evaluate_javascript(
                WEBKIT_WEB_VIEW(self->webview_),
                BuildSubmitScript().c_str(), -1, nullptr, nullptr, nullptr,
                nullptr, nullptr);
          }
          FlValue* m = fl_value_new_map();
          fl_value_set_string_take(m, "ok", fl_value_new_bool(true));
          fl_value_set_string_take(m, "submitted", fl_value_new_bool(submit));
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
          fl_value_set_string_take(m, "error",
                                   fl_value_new_string("未找到输入框"));
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
