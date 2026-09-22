# markdown阅读器 · Flutter 重构版

Tauri（WebView）版的 Flutter 重构验证工程。**原 Tauri 项目保持原样、未被修改**，本工程是独立目录。

```
markdown-reader-flutter/
├── lib/                     Flutter（Dart）前端
│   ├── main.dart            入口
│   ├── app.dart             主界面：工具栏 / 文件树 / 多标签 / 阅读区 / 搜索 / AI 分栏 / 状态栏
│   ├── state.dart           应用状态：文件夹、标签、主题、字号、排序、会话
│   ├── perf.dart            性能自测钩子（MDREADER_PERF=1）
│   ├── ai/
│   │   └── ai_pane.dart     右侧 AI 搜索分栏：可拖动宽度 + 头部操作 + 原生贴合同步
│   ├── core/
│   │   ├── models.dart      块 / 内联 / 树 / 搜索 / 会话 数据模型
│   │   ├── ai_panel_native.dart  AI 面板的原生通道（矩形/显隐/注入/事件）
│   │   └── native.dart      Rust core 的 dart:ffi 绑定（Isolate 内调用）
│   └── render/
│       ├── inline_render.dart  内联样式 → InlineSpan（含公式呈现）
│       └── block_render.dart   块 → Widget（含折叠块 / 表格 / 高亮代码）
├── rust/core/               Rust 核心（直接复用 Tauri 版的 core，另加 FFI 层）
│   ├── src/md.rs            原样保留：HTML 渲染管线（Tauri 版仍在用）
│   ├── src/blocks.rs        【新增】结构化节点渲染（Flutter 用，不再走 HTML）
│   ├── src/ffi.rs           【新增】C ABI 导出层
│   ├── src/tree.rs          目录扫描 + 自然排序 + 子树大小（原样复用）
│   ├── src/search.rs        全文搜索，中文安全（原样复用）
│   └── src/session.rs       会话持久化（原样复用）
├── linux/runner/
│   ├── my_application.cc    窗口：客户区是 GtkOverlay（主件 Flutter 视图 + 叠加 AI 网页）
│   └── ai_panel.{h,cc}      【新增】右侧 AI 面板的 WebKitGTK 实现（Linux 专用）
├── android/  windows/       Flutter 平台工程（库由 CI 构建时注入）
├── .github/workflows/       三平台 CI + Release
├── native/                  构建产物（.so/.dll，打进 bundle；不入库）
├── scripts/                 build-rust.sh / run.sh / test.sh
└── test/                    Dart 测试
```

## 架构

```
Flutter (Dart)  ──  UI：窗口 / 标签 / 文件树 / 虚拟滚动 / 主题 / 输入 / AI 分栏
      │
      │  dart:ffi（C ABI，入参出参均为 JSON 字符串，全部在 Isolate 内调用）
      ▼
Rust mdreader-core ── markdown 解析 / syntect 高亮 / 目录扫描 / 全文搜索 / 会话

Flutter (Dart)  ──→ MethodChannel `mdreader/ai_panel`  （只传矩形/显隐/操作）
      ▼
GtkOverlay 叠加的原生 WebKitGTK 视图  ── DeepSeek 网页版（登录态由 WebKit 持久化）
```

动态库按平台自动选择：Linux `libmdreader_core.so`、Windows `mdreader_core.dll`、
macOS `libmdreader_core.dylib`；Android 交给系统从 APK 的 `lib/<abi>/` 解析。

选择这条路线的原因（均为实测）：

- **纯 Dart 重写解析层不可接受**：同一份 3.18MB 文档，Dart `package:markdown` AOT 解析耗时
  **1668~1824ms**，而 Rust `pulldown-cmark` 渲染（读取+解析+高亮+出结构）只要 **53~79ms**，差约 23 倍。
- **WebView 路线在 Linux 上不可行**：`webview_flutter` 官方仅支持 Android/iOS/macOS，
  Windows/Linux 无官方实现；桌面替代方案普遍存在「Flutter widget 无法覆盖在 WebView 之上」的合成层级限制，
  对图文混排的文档场景基本不可用。
- **Flutter 不认 HTML**：因此 Rust 侧改为输出**结构化节点树**（块/内联两级 + 高亮 token），
  Dart 直接建 widget，省掉一次 HTML 解析。

## 平台与构建

| 平台 | 产物 | 构建位置 |
|---|---|---|
| Linux x64 | `mdreader-flutter-linux-x64.tar.gz`（绿色包）/ deb | 本机或 CI |
| Windows x64 | `mdreader-flutter-windows-x64.zip`（绿色包） | **仅 CI**（Linux 无法交叉编译 Flutter Windows 端） |
| Android | `mdreader-flutter-android.apk`（含 arm64-v8a / armeabi-v7a / x86_64） | **仅 CI**（本机无 SDK/NDK） |

三平台由 `.github/workflows/build.yml` 构建：推送 `main` 触发构建，打 `v*` 标签自动创建 Release 并附上全部产物。

**已发布版本**：<https://github.com/tianmingwan/markdown-reader-flutter/releases/tag/v0.1.0>

| 附件 | 大小 |
|---|---|
| `mdreader-flutter_0.1.0_amd64.deb` | 9.6 MB（`sudo dpkg -i` 安装，带菜单项与图标） |
| `mdreader-flutter-linux-x64.tar.gz` | 11.8 MB（解压即用） |
| `mdreader-flutter-windows-x64.zip` | 13.2 MB（解压即用，含 `mdreader_core.dll`） |
| `mdreader-flutter-android.apk` | 61.7 MB（三 ABI；如需减小体积可拆成 per-ABI 包） |

```bash
# 本地（Linux）
./scripts/build-rust.sh          # 编译 Rust cdylib → native/libmdreader_core.so
flutter build linux --release
./build/linux/x64/release/bundle/mdreader_flutter

# 一键
./scripts/run.sh

# 重新生成 Linux deb
dpkg-deb --build --root-owner-group <debroot> dist/mdreader-flutter_0.1.0_amd64.deb
```

一键：

```bash
./scripts/run.sh            # 重建 Rust + 构建 + 运行
./scripts/test.sh           # Rust 单测 + Dart/Flutter 测试
```

### 命令行 / 环境变量

| 变量 | 作用 |
|---|---|
| `MDREADER_OPEN=<目录或 .md>` | 启动直接打开 |
| `MDREADER_CFG_DIR=<目录>` | 覆盖配置目录（默认 `~/.config/com.chensdong.mdreader`，与原 Tauri 版一致） |
| `MDREADER_CORE_SO=<路径>` | 指定 Rust 动态库位置 |
| `MDREADER_SEARCH=<关键词>` | 启动即打开搜索面板并执行一次搜索（自动化验证用） |
| `MDREADER_AI=1` | 启动即打开右侧 AI 搜索分栏（自动化验证用，等价于手动开启） |
| `MDREADER_HL=<关键词>` | 只设置正文高亮词、不开搜索面板（等价于「搜完收起面板」的状态） |
| `MDREADER_SELFTEST=1` | 打印渲染统计后退出 |
| `MDREADER_PERF=1` | 打印打开耗时与帧统计后退出 |

## 性能实测（本机 Linux Mint 22.3 / X11 / Intel HD630 + GTX 1050 Ti / Impeller OpenGLES）

真实鼠标输入（xdotool 注入滚轮），帧耗时取自 `SchedulerBinding.addTimingsCallback`。

| 场景 | Tauri 版（WebKitGTK + 虚拟滚动） | **Flutter 版** |
|---|---|---|
| 政治 1128 题（3.18MB / 8010 块）滚动 | 16.1 ms/帧（60fps，vsync 上限） | **9.0 ms/帧**（p50 5.0） |
| 法律 2082 题（5.9MB / 14725 块）滚动 | 16.1 ms/帧 | **9.5 ms/帧**（p50 5.5） |
| 政治 1128 题打开 | 262 ms（首屏画出） | **496 ms**（数据就绪） |
| 法律 2082 题打开 | 214 ms | **774 ms** |
| 内存（PSS） | 224 MB（3 进程） | **129~135 MB**（单进程） |
| 体积（Linux） | 二进制 9.9 MB / deb 5.3 MB | **22 MB**（引擎 16.4MB + libapp.so 5.8MB） |

**结论：滚动帧率在两者上都是被 vsync 封顶的 60fps（16.7ms），Flutter 只是帧内余量更大（9ms vs 16ms），
用户可感知的流畅度没有区别。** 唯一有实际差异的是打开大文档：Flutter 版慢 1.9~3.6 倍，
瓶颈在「Rust 渲染 + JSON 序列化 + 跨边界传输 + JSON 解码」，其中 Rust 渲染本身只占 55~80ms。

## 实现要点：滚动位置恢复（踩过的坑）

**不能一次 `jumpTo(比例 × maxScrollExtent)` 就完事。** Flutter 的 `ListView` 是不定高列表，
`maxScrollExtent` 只能**按已测量到的项估算**，实测（法律 2082 题）：

| | 首帧 | 稳定后 |
|---|---|---|
| `maxScrollExtent` | 1,137,267 px | 1,546,197 px（差 26%） |
| 恢复 50% 时的落点 | — | **36.8%**（偏差 13 个百分点，文档越深偏得越多） |

改为**多轮收敛**：每轮用**当前最新的** `maxScrollExtent` 重跳同一比例，总高变化 <0.5% 即停，
最后再等布局稳定做一次校正。四个采样点的实测误差：

| 期望比例 | 修复前 | 修复后 |
|---|---|---|
| 0.25 / 0.50 / 0.75 / 0.95 | 0.5 处落到 0.368 | **0.2500 / 0.5000 / 0.7500 / 0.9500（误差 0.00%）** |

两个配套细节：恢复期间用 `_restoring` 挡住 `_onScroll`，避免把收敛过程中的中间态当成用户位置写回；
并注册 `AppLifecycleListener.onExitRequested` 兜底落盘——从滚动停止到写盘有 1.2 秒防抖窗口，
期间关窗会丢掉最后一次位置。

## 右侧 AI 搜索分栏（内嵌 DeepSeek 网页版）

工具栏的 🤖 按钮（或 `Ctrl+Shift+A`）在右侧分出 AI 对话栏，里面是**真实的 DeepSeek
网页版**，登录一次之后长期有效；再点一次收起（**收起只是隐藏**，对话内容与登录态都留着）。
拖动分栏可调宽度，宽度与开关状态都记在会话里。

### 为什么是「原生子窗口叠加」而不是 widget / iframe

- `chat.deepseek.com` 返回 `content-security-policy: frame-ancestors 'none'`，
  **任何 iframe 内嵌都会被引擎拒绝**；
- Flutter 桌面端没有 platform view，widget 里装不下真实网页（README 上文已说明为什么
  不走 `webview_flutter`）。

所以分工是：**Dart 决定布局，原生只负责把网页盖在正确的位置上**。

网页怎么「装进」分栏，三端不一样（`lib/ai/ai_types.dart` 的 `AiBackendKind`）：

| 平台 | 承载方式 | 说明 |
|---|---|---|
| Linux | **原生覆盖层**（`linux/runner/ai_panel.cc`） | Flutter 桌面端没有 platform view，只能让 WebKitGTK 作为原生子窗口盖上去 |
| Android / iOS / macOS | **应用内 WebView**（`lib/ai/ai_webview.dart`，webview_flutter） | 平台视图，天然在 widget 树里，不需要矩形同步与遮挡处理 |
| Windows | 无内嵌能力 | 退化成「用系统浏览器打开 DeepSeek」 |

```
Linux 路径（Dart 决定布局，原生只负责贴上去）
  分栏宽度 / 拖动 / 显隐                       GtkOverlay 的叠加子件
  占位区矩形 → ×devicePixelRatio  → MethodChannel → gtk margin + size_request
  头部操作（带入选中 / 刷新 / 缩放 / 清登录态） →  reload / evaluate_javascript / clear data
  浮层遮挡、拖动时让位                          （网页永远盖在 Flutter 之上，必须先藏）
```

三条由此而来的**设计约束**（只对 Linux 那条原生覆盖层成立，都已在实现里处理）：

1. **网页一旦显示，就会盖住这块矩形里所有 Flutter 内容**——所以提示信息走工具栏 toast
   （在面板之外），面板内部只画「网页还没盖上时」才需要看的东西（加载中 / 出错 / 拖动中）。
2. **网页是独立的原生窗口，会吃掉指针事件**——拖动分栏期间、以及 Flutter 弹菜单/对话框
   期间（用 `NavigatorObserver` 感知浮层层数），都必须先把网页藏起来，否则分栏「粘住」、
   菜单被盖住。
3. **坐标要按设备像素给**（GTK 用设备像素，Flutter 用逻辑像素），Dart 侧乘
   `devicePixelRatio` 后下发；窗口缩放、侧栏折叠、拖动分栏都会重算并重新贴合。

### 登录态与隐私

- cookie / localStorage / IndexedDB 由 WebKit 自己的 `WebsiteDataManager` 落在
  `$MDREADER_CFG_DIR/webview`（默认 `~/.config/com.chensdong.mdreader/webview`，
  缓存在同目录的 `webview-cache`）。**原生侧不读不写任何 cookie。**
- 面板里的网页**不接任何 IPC**：Dart 只在「带入选中文字」时下发一段填输入框的脚本
  （DeepSeek 的输入框是 React 受控组件，需要走原型链 setter + `input` 事件），
  远端页面拿不到应用命令。
- 「更多 → 清除登录状态并刷新」= 清掉该数据目录里的登录态后重新加载。

### 平台差异与构建依赖

| 平台 | 行为 |
|---|---|
| Linux（本机 / CI） | 真正内嵌网页（WebKitGTK 原生覆盖层） |
| Linux 未装 `libwebkit2gtk-4.1-dev` 时构建 | 照常构建，面板退化成「用系统浏览器打开 DeepSeek」 |
| **Android（真机平板实测）** | 应用内 WebView 内嵌网页；窄屏（< 900 逻辑 px）自动改为面板占满内容区；返回键先关面板 |
| Windows | 退化（面板给按钮 + 提示） |

### 安卓实测记下的三个坑（都已修）

1. **release 包没有网络权限**：Flutter 模板只把 `INTERNET` 放在 debug/profile manifest 里，
   正式包因此连不上 deepseek —— 已在 `android/app/src/main/AndroidManifest.xml` 显式声明。
2. **配置目录在安卓上不可写**：`$HOME/.config/...` 在 Android/iOS 上写不进去，
   于是会话（上次目录、滚动位置、主题、字号、**AI 面板开关**）全部静默丢失。
   现在移动端先经 `path_provider` 把配置目录落到应用私有目录（`NativeCore.resolveConfigDir()`）。
3. **登录态**：Android WebView 把 cookie 与 localStorage 存在应用私有目录
   （`app_webview/`），webview_flutter 默认已开 DOM storage，所以「登录一次长期有效」
   在安卓上同样成立；面板关闭只是从 widget 树里摘下来，控制器仍在，重开即用。

4. **安卓上「打开文件夹」能选中目录、却扫出 0 篇**：Flutter 版把 SAF 选中的目录当
   **普通文件系统路径**交给 Rust 扫描，而 Android 11+ 默认不允许读
   `/storage/emulated/0/` 下的非媒体文件。现在声明了 `MANAGE_EXTERNAL_STORAGE`
   （"所有文件访问"），并在应用内引导授权（`MainActivity.kt` 暴露查询/跳转通道，
   点「打开文件夹」时若未授权会先弹说明，授权回到前台自动重扫）；权限很宽、
   Google Play 审查严格，本工程是个人自用/侧载所以采用。
   —— 更"正规"的做法是目录遍历与读取改走 SAF/DocumentsContract，本次未做。

### 安卓真机实测（Lenovo TB371FC / Android 14 / 横 1266 逻辑 px）

| 项 | 结果 |
|---|---|
| 扫描并打开文档（标题/列表/代码高亮/字数） | ✅（授权「所有文件访问」后） |
| AI 面板：工具栏打开、内嵌真实 DeepSeek 登录页 | ✅ |
| 横屏三栏 + 可拖动分栏 / 竖屏自动接管并带返回箭头 | ✅ |
| 返回键先关面板、不退出应用 | ✅ |
| 面板菜单（放大/缩小/在浏览器打开/清登录态）盖在网页之上 | ✅ |
| 网页缩放（安卓 `setTextZoom`） | ✅ |
| 关面板不销毁网页、重开即用；重启后按会话恢复 | ✅ |
| 选中文字 →「带入提问框」：脚本执行 + 失败兜底复制到剪贴板 | ✅ |

**一个安卓 ROM 的坑（已按行为适配）**：部分 ROM（如联想 ZUI）的长按"智能选词"会弹出
**系统自带**的选择菜单；点别处时，**这一下会同时收起系统菜单并折叠选区**。
如果"选区一折叠就清空"，带入按钮会在同一拍里变成禁用，用户永远点不上。
因此 `AppState.setSelection` **只刷新非空选区、不因折叠而清空**，只在切换文档时清空
（`clearSelection`）；另外安卓上更顺手的选词方式是**双击选词**再点带入按钮。

**代价**：WebView 是**用到才创建**（Dart 侧第一次 `open` 时才建），没用过这个功能的用户
零开销；一旦打开，会多出 WebKit 的 WebContent + Network 两个进程（实测 DeepSeek 登录页
约 380 MB RSS）。关闭面板只是隐藏，所以这部分内存会一直留着——换来的是「重开即用、
登录态与对话都在」。

所以 Linux 构建依赖多了一条 **`libwebkit2gtk-4.1-dev`**（deb 包已声明运行时依赖
`libwebkit2gtk-4.1-0`）。CMake 里它是**可选**依赖：没有也照常构建，不会把非核心功能
变成构建失败的理由。

安卓侧用官方的 `webview_flutter`（+ `webview_flutter_android` 只为拿 `setTextZoom`），
`path_provider` 用于把配置目录落到应用私有目录；三者都只影响各自平台，Linux/Windows
构建不受影响（`flutter build linux` 已复测通过）。

## 功能对照

| 原功能 | 状态 |
|---|---|
| 打开文件夹 / 递归文件树（跳过 .git、node_modules 等） | ✅ |
| 文件树 6 种排序（含自然排序 1,2,10；目录恒在文件前） | ✅ |
| 多标签切换 / 关闭 | ✅ |
| 打开即预览、代码高亮（syntect，主题色由 Rust 决定） | ✅ 保真 |
| `<details>` 折叠答案（错题文档 1128 处） | ✅ 保真，展开状态跨回收保持 |
| 大文档虚拟滚动 | ✅ ListView.builder 天然虚拟化 + 惰性块解析 |
| 全文搜索（文件名 + 内容，中文安全） | ✅ 复用 Rust |
| **搜索命中红色高亮**（搜索摘要 + 正文） | ✅ 新增（原版仅摘要、且为黄色 `<mark>`） |
| 快捷键 `Ctrl+F` 打开搜索 / `Esc` 两级 | ✅ 新增（原版无） |
| **右侧 AI 搜索分栏**（内嵌 DeepSeek 网页版、可拖动宽度、登录态本地保存） | ✅ 新增（Linux 原生覆盖层 / Android 应用内 WebView，见下节） |
| 选中正文文字 → 带入 DeepSeek 提问框 | ✅ 新增（跨块连选；自动填入失败会退化成复制到剪贴板） |

**关于搜索高亮的几个行为细节**（都已有测试覆盖）：

- 搜索词会同时高亮**搜索摘要**与**正文**；`Esc` 收起面板时**高亮保留**（可以继续在正文里顺着高亮读），
  再按一次 `Esc`（或点指示条上的 ✕）才清除。
- 工具栏右上角与状态栏会显示 `高亮「xxx」` 指示条，带一键清除。
- 点了搜索结果打开文档时，会自动滚动到该文档**首个命中块**（块高不等，按块序号比例近似定位）。
- `Ctrl+F` 走的是 Rust 后端全文搜索，覆盖整篇文档——浏览器原生 Ctrl+F 在大文档虚拟滚动下
  只能命中已渲染窗口（约 430 个节点）里的文字。
| 会话记忆（目录/文档/滚动比例/主题/字号/排序） | ✅ 复用 Rust，格式与 Tauri 版一致 |
| 主题（跟随系统/浅/深）、字号 A−/A+ | ✅ 切换主题会按新主题重新高亮 |
| 状态栏（路径/字数/进度）、最近打开 | ✅ |
| 本地图片、相对链接应用内打开、http 走系统浏览器 | ✅ |
| 表格 / 任务列表 / 删除线 / 引用 / 分隔线 | ✅ |
| 数学公式 | ⚠️ **占位样式**（斜体+主题色）。接入点见 `inline_render.dart` 的 `_pushTextWithMath` |
| Mermaid 图表 | ⚠️ **降级为源码视图**（带标题与代码框）。`block_render.dart` 的 `_MermaidFallback` 是接入点 |
| 手写笔批注 | ❌ 按需求移除（原 `ink.ts` 723 行） |
| 富文本编辑（contenteditable） | ❌ 未迁。Flutter 侧需自研编辑器或降级为源码编辑 |
| 目录自动监听刷新 | ❌ 未迁（原版用 notify；本轮改由工具栏「刷新」按钮 + 重扫替代） |
| 手机模式（列表→阅读视图） | ❌ 未迁（本工程只建了 linux 平台） |

## 测试

```bash
./scripts/test.sh
```

- **Rust core**：31 个单测（原有 28 + 新增 `session.rs` 2 个：老会话文件缺 `aiPanel*` 字段仍可读、
  AI 面板字段读写往返）
- **Dart/Flutter**：66 个测试
  - `test/ai_pane_test.dart`（17）：原生通道协议（设备像素矩形/数据目录/unsupported 降级/
    事件回调）、面板宽度夹紧与会话写回、浮层与拖动时让位、选区 notifier 不触发全局重建、
    降级 UI 与「带入提问框」按钮状态、三端承载方式判定、注入脚本转义
  - 搜索高亮 6 例：多处命中、大小写不敏感、空查询不高亮、切分不丢字、正文高亮样式、未开启时渲染不变
  - 快捷键与高亮生命周期 5 例（用真实按键事件驱动）：`Ctrl+F` 开面板、`Esc` 两级语义、
    `closeSearch`/`toggleSearch` 保留高亮、无高亮时按 Esc 无副作用
  - `test/native_test.dart`（12）：真实 `.so` 端到端 —— 渲染、高亮 token、折叠块、mermaid、公式标记、
    图片与链接改写、目录扫描（跳过噪音目录）、中文全文搜索、会话读写往返、缺失文件不崩
  - `test/models_test.dart`（17）：自然排序、6 种排序模式、块/内联 JSON 解析、未知类型降级、惰性解析、会话往返
  - `test/render_test.dart`（18）：标题/段落/代码/表格/列表/引用渲染、折叠交互与状态外持、链接回调、Mermaid 降级、字号生效、搜索高亮

## 已知缺口（按优先级）

1. **打开大文档偏慢**（496/774ms）。Rust 渲染只占 55~80ms，其余是 JSON 序列化 + 跨边界拷贝 + `jsonDecode`。
   优化方向：把 JSON 换成紧凑数组编码或二进制协议（预估可省 40~60%），或分批下发块。
2. **公式与 Mermaid 未接真实渲染器**。`flutter pub add flutter_math_fork` 在本机因网络（fake-IP 代理）失败，
   未强行引入 —— 生态风险本身也较高（该包 2025-05 后未发版）。接入点已留好。
3. 编辑模式、目录自动监听、手机模式未迁。
