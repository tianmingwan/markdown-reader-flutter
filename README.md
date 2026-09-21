# markdown阅读器 · Flutter 重构版

Tauri（WebView）版的 Flutter 重构验证工程。**原 Tauri 项目保持原样、未被修改**，本工程是独立目录。

```
markdown-reader-flutter/
├── lib/                     Flutter（Dart）前端
│   ├── main.dart            入口
│   ├── app.dart             主界面：工具栏 / 文件树 / 多标签 / 阅读区 / 搜索 / 状态栏
│   ├── state.dart           应用状态：文件夹、标签、主题、字号、排序、会话
│   ├── perf.dart            性能自测钩子（MDREADER_PERF=1）
│   ├── core/
│   │   ├── models.dart      块 / 内联 / 树 / 搜索 / 会话 数据模型
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
├── native/                  构建产物 libmdreader_core.so（打进 bundle/lib）
├── scripts/                 build-rust.sh / run.sh / test.sh
└── test/                    Dart 测试
```

## 架构

```
Flutter (Dart)  ──  UI：窗口 / 标签 / 文件树 / 虚拟滚动 / 主题 / 输入
      │
      │  dart:ffi（C ABI，入参出参均为 JSON 字符串，全部在 Isolate 内调用）
      ▼
Rust mdreader-core ── markdown 解析 / syntect 高亮 / 目录扫描 / 全文搜索 / 会话
```

选择这条路线的原因（均为实测）：

- **纯 Dart 重写解析层不可接受**：同一份 3.18MB 文档，Dart `package:markdown` AOT 解析耗时
  **1668~1824ms**，而 Rust `pulldown-cmark` 渲染（读取+解析+高亮+出结构）只要 **53~79ms**，差约 23 倍。
- **WebView 路线在 Linux 上不可行**：`webview_flutter` 官方仅支持 Android/iOS/macOS，
  Windows/Linux 无官方实现；桌面替代方案普遍存在「Flutter widget 无法覆盖在 WebView 之上」的合成层级限制，
  对图文混排的文档场景基本不可用。
- **Flutter 不认 HTML**：因此 Rust 侧改为输出**结构化节点树**（块/内联两级 + 高亮 token），
  Dart 直接建 widget，省掉一次 HTML 解析。

## 构建与运行

```bash
# 依赖：rustup + cargo、Flutter 3.47+（Linux 桌面工具链）
./scripts/build-rust.sh     # 编译 Rust cdylib → native/
flutter build linux --release
./build/linux/x64/release/bundle/mdreader_flutter
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

- **Rust core**：29 个单测（原有 20 + 新增 `blocks.rs` 9 个：标题/段落、表格、mermaid、代码高亮 token、
  `<details>` 折叠、嵌套列表、引用、图片与链接解析、分隔线与任务列表）
- **Dart/Flutter**：52 个测试
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
