#ifndef RUNNER_AI_PANEL_H_
#define RUNNER_AI_PANEL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <string>

// 右侧 AI 对话面板：把 DeepSeek 网页版嵌进阅读器右侧分栏。
//
// 为什么必须是「原生 WebView 叠加」而不是 Flutter widget / iframe：
// - DeepSeek 网页版带 `content-security-policy: frame-ancestors 'none'`，
//   iframe 内嵌会被浏览器引擎直接拒绝；
// - Flutter 桌面端没有 platform view，widget 里装不下真实网页。
// 所以分工是：**Dart 决定布局**（分栏、拖动宽度、显隐、把上下文送进去），
// **原生只负责把一块 WebKitGTK 视图按 Dart 给的矩形精确盖在窗口上**。
//
// 登录态：cookie / localStorage 由 WebKit 自己的 WebsiteDataManager 落在应用
// 配置目录（见 Dart 传入的 data_dir），原生不碰任何 cookie；关闭面板走隐藏，
// 因此对话内容与登录态都保留，重开即用。
class AiPanel {
 public:
  static AiPanel* GetInstance();

  // 挂到 Flutter 视图上并注册 `mdreader/ai_panel` 通道。
  // view: Flutter 视图；overlay: 包住 view 的 GtkOverlay（WebView 作为叠加子件）。
  void Attach(FlView* view, GtkWidget* overlay);

  // 本次构建是否带 WebKitGTK 支持。Linux 上缺 libwebkit2gtk-4.1-dev 时为 false，
  // 此时所有方法都返回 unsupported，由 Dart 侧退化成「用系统浏览器打开」。
  static bool Supported();

 private:
  AiPanel() = default;
  ~AiPanel() = default;
  AiPanel(const AiPanel&) = delete;
  AiPanel& operator=(const AiPanel&) = delete;

  static void OnMethodCall(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data);
  void HandleMethodCall(FlMethodCall* method_call);

  // 懒加载：第一次 open 时才建 WebView（省掉不用该功能时的内存/启动开销）。
  void EnsureWebView(const std::string& data_dir, const std::string& cache_dir,
                     const std::string& url);
  void ApplyBounds();
  void SetPaneVisible(bool visible);
  void Emit(const char* method, FlValue* args);
  // 向 Dart 汇报页面加载状态：started / finished / failed / crashed
  void EmitLoadState(const char* state, const char* uri, const char* error);

  // 把文本填进 DeepSeek 输入框。页面没就绪时挂起，加载完成后补填。
  void SetPendingPrompt(const std::string& text);
  void InjectPending();
  void InjectNow();

  FlView* view_ = nullptr;
  GtkWidget* overlay_ = nullptr;
  GtkWidget* webview_ = nullptr;
  FlMethodChannel* channel_ = nullptr;

  // Dart 给的矩形（GTK 设备像素）
  int x_ = 0;
  int y_ = 0;
  int width_ = 0;
  int height_ = 0;
  bool pane_visible_ = false;
  bool page_ready_ = false;

  std::string pending_prompt_;
  int inject_attempts_ = 0;
};

#endif  // RUNNER_AI_PANEL_H_
